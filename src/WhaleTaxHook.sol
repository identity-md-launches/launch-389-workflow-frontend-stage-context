// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title WhaleTaxHook
/// @notice A Uniswap v4 hook for WHAL's native-ETH pool whose swap fee grows with the swap's own
/// price impact. Tiny swaps pay 0.3%; the fee rises linearly to 5% at a 5% price move and is capped
/// there. The fee is charged on the swap's unspecified leg through an `afterSwap` return delta,
/// settled as ERC-6909 claims minted to the hook, and can only ever leave the hook towards
/// `0x000000000000000000000000000000000000dEaD` via the permissionless `burnFees`.
///
/// Design notes (see README for the full write-up):
///  - The tax is per swap. Splitting a trade across several swaps or blocks lowers it. That is the
///    intended behaviour, not a bug: each swap is taxed on the impact it alone causes.
///  - All state is keyed by `PoolId`. Any pool on this hook whose `currency0` is not native ETH is
///    left completely alone: zero deltas, no transient writes, no events, no claims.
///  - Nothing here can revert a pool initialisation or a liquidity add: the hook declares no
///    initialize or liquidity callbacks, so the PoolManager never calls it for those.
///  - There is no owner, admin, setter, pause, upgrade or sweep. Every rate is a constant. The only
///    constructor argument is the PoolManager.
contract WhaleTaxHook is IHooks, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    // ------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice Fee charged on a swap that barely moves the price (0.30%).
    uint256 public constant BASE_FEE_BPS = 30;

    /// @notice Fee charged once the price move reaches `MOVE_CAP_BPS` (5.00%). Also the cap.
    uint256 public constant MAX_FEE_BPS = 500;

    /// @notice Price move (in bps) at and beyond which the fee stops rising.
    uint256 public constant MOVE_CAP_BPS = 500;

    /// @notice Reported price move when the sqrt-price ratio between the two sides of a swap is
    /// 2^64 or more. Past that the exact figure would not fit the arithmetic; the fee is capped at
    /// `MAX_FEE_BPS` long before, so nothing depends on the precise value.
    uint256 public constant MOVE_BPS_SATURATED = type(uint256).max;

    /// @notice The only destination fee claims can ever be sent to.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice The PoolManager this hook serves. Set once, at construction.
    IPoolManager public immutable poolManager;

    // ------------------------------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------------------------------

    /// @notice Fees collected and not yet burned, per currency. Always equals the hook's ERC-6909
    /// claim balance for that currency on the PoolManager.
    mapping(Currency currency => uint256) public accruedFees;

    /// @notice Lifetime fees collected per currency (burned or not).
    mapping(Currency currency => uint256) public totalFeesCollected;

    /// @notice Lifetime fees sent to `DEAD` per currency.
    mapping(Currency currency => uint256) public totalFeesBurned;

    /// @dev Namespace mixed into the transient slot that holds a pool's pre-swap sqrt price.
    bytes32 private constant PRE_SWAP_PRICE_NAMESPACE = keccak256("WhaleTaxHook.preSwapSqrtPriceX96");

    // ------------------------------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------------------------------

    /// @notice Emitted on every swap in a native-ETH pool served by this hook, fee or no fee.
    /// @param poolId The pool the swap happened in.
    /// @param moveBps |P_after / P_before - 1| x 10,000 with P = sqrtPriceX96 squared.
    /// @param feeBps The fee rate applied: 30 + floor(470 x min(moveBps, 500) / 500).
    /// @param currency The currency of the swap's unspecified leg, which the fee was taken in.
    /// @param fee The fee amount, in `currency`, minted to the hook as ERC-6909 claims.
    event WhaleTax(PoolId indexed poolId, uint256 moveBps, uint256 feeBps, Currency indexed currency, uint256 fee);

    /// @notice Emitted when accrued claims of `currency` are sent to `DEAD`.
    event FeesBurned(Currency indexed currency, uint256 amount);

    error NotPoolManager();
    error HookNotImplemented();
    error NothingToBurn();
    error ClaimTransferFailed();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ------------------------------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------------------------------

    /// @param manager The Uniswap v4 PoolManager. On Sepolia: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543.
    /// @dev Reverts with `Hooks.HookAddressNotValid` unless this contract's address carries exactly
    /// the bits `getHookPermissions` declares (0x00C4), so it can only be deployed at a mined address.
    constructor(IPoolManager manager) {
        poolManager = manager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice Exactly beforeSwap, afterSwap and afterSwapReturnDelta; everything else false.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------------------------------
    // Pure fee maths (also the views the site uses for previews)
    // ------------------------------------------------------------------------------------------

    /// @notice The fee rate for a given price move: 30 + floor(470 x min(moveBps, 500) / 500).
    function feeBpsForMove(uint256 moveBps) public pure returns (uint256) {
        uint256 clamped = moveBps > MOVE_CAP_BPS ? MOVE_CAP_BPS : moveBps;
        return BASE_FEE_BPS + ((MAX_FEE_BPS - BASE_FEE_BPS) * clamped) / MOVE_CAP_BPS;
    }

    /// @notice |P_after / P_before - 1| x 10,000 with P = sqrtPriceX96 squared, rounded down.
    /// @dev Every step goes through FullMath (512-bit intermediates) so no product of two sqrt
    /// prices can overflow. The move is asymmetric by definition: a price doubling is 10,000 bps
    /// while a halving is 5,000 bps. A rise whose sqrt-price ratio is 2^64 or more (a price ratio of
    /// 2^128 or more) returns `MOVE_BPS_SATURATED`; a fall can never exceed 10,000 bps.
    /// A `sqrtPriceBefore` of zero (no recorded pre-swap price) reads as "no move".
    function priceMoveBps(uint160 sqrtPriceBefore, uint160 sqrtPriceAfter) public pure returns (uint256) {
        if (sqrtPriceBefore == 0 || sqrtPriceBefore == sqrtPriceAfter) return 0;
        uint256 before_ = sqrtPriceBefore;
        uint256 after_ = sqrtPriceAfter;

        // The ratio after^2 / before^2 is formed in two mulDivs. The intermediate carries 32 extra
        // fractional bits so the second rounding only matters within 2^-32 of an integer bps.
        if (after_ > before_) {
            // (after^2 / before^2 - 1) x BPS, floored.
            if (after_ >= (before_ << 64)) return MOVE_BPS_SATURATED;
            uint256 q = FullMath.mulDiv(after_ << 32, after_, before_); // < after x 2^96 < 2^256
            return FullMath.mulDiv(q, BPS, before_ << 32) - BPS; // q / (before x 2^32) < 2^128
        }

        // (1 - after^2 / before^2) x BPS, floored: BPS minus the ratio rounded up.
        uint256 r = FullMath.mulDivRoundingUp(after_ << 32, after_, before_); // <= before x 2^32
        return BPS - FullMath.mulDivRoundingUp(r, BPS, before_ << 32);
    }

    /// @notice The fee `feeBps` takes out of an unspecified leg of `unspecifiedAmount`, rounded down.
    function feeAmount(uint256 unspecifiedAmount, uint256 feeBps) public pure returns (uint256) {
        return (unspecifiedAmount * feeBps) / BPS;
    }

    /// @notice The hook's ERC-6909 claim balance for `currency` on the PoolManager.
    function claimsOf(Currency currency) external view returns (uint256) {
        return poolManager.balanceOf(address(this), currency.toId());
    }

    /// @notice The pre-swap sqrt price recorded for `poolId` in the current transaction, if any.
    /// Zero outside a swap on a native-ETH pool served by this hook.
    function pendingPreSwapSqrtPriceX96(PoolId poolId) external view returns (uint160) {
        return _tloadPreSwapPrice(poolId);
    }

    // ------------------------------------------------------------------------------------------
    // Swap callbacks
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Records the pre-swap sqrt price in a transient slot keyed by `PoolId`. Non-ETH pools
    /// are left untouched. Never returns a delta or a fee override.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (key.currency0.isAddressZero()) {
            PoolId poolId = key.toId();
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
            _tstorePreSwapPrice(poolId, sqrtPriceX96);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @inheritdoc IHooks
    /// @dev Computes the price move against the recorded pre-swap price, clears the transient slot,
    /// and charges the fee on the unspecified leg by returning a positive unspecified delta. The
    /// PoolManager credits the hook with that amount; the hook consumes the credit at once by
    /// minting itself ERC-6909 claims, so the hook's net delta inside the swap is zero.
    /// Exact-in: the fee comes out of the output. Exact-out: the fee is added to the input.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (!key.currency0.isAddressZero()) return (IHooks.afterSwap.selector, 0);

        PoolId poolId = key.toId();
        uint160 sqrtPriceBefore = _tloadPreSwapPrice(poolId);
        _tstorePreSwapPrice(poolId, 0);
        (uint160 sqrtPriceAfter,,,) = poolManager.getSlot0(poolId);

        uint256 moveBps = priceMoveBps(sqrtPriceBefore, sqrtPriceAfter);
        uint256 feeBps = feeBpsForMove(moveBps);

        // Specified currency is currency0 when (exact-in and zeroForOne) or (exact-out and oneForZero).
        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        (Currency unspecified, int128 unspecifiedDelta) =
            specifiedIsCurrency0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        // Widening int128 -> int256 cannot truncate; the sign is handled before the uint cast.
        int256 wide = int256(unspecifiedDelta);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 leg = wide < 0 ? uint256(-wide) : uint256(wide);

        uint256 fee = feeAmount(leg, feeBps);
        // The only external call before this point is the PoolManager's `extsload` view.
        // forge-lint: disable-next-line(reentrancy-events)
        emit WhaleTax(poolId, moveBps, feeBps, unspecified, fee);
        if (fee != 0) {
            accruedFees[unspecified] += fee;
            totalFeesCollected[unspecified] += fee;
            poolManager.mint(address(this), unspecified.toId(), fee);
        }
        // fee <= 5% of an int128 magnitude, so narrowing back to int128 cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        int128 hookDelta = int128(int256(fee));
        return (IHooks.afterSwap.selector, hookDelta);
    }

    // ------------------------------------------------------------------------------------------
    // Burning
    // ------------------------------------------------------------------------------------------

    /// @notice Sends every accrued claim of `currency` to `DEAD`. Anyone may call it.
    /// @dev Effects first, then the PoolManager unlock whose callback moves the claims. `unlock`
    /// reverts if the PoolManager is already unlocked, so this cannot run inside a swap.
    function burnFees(Currency currency) external returns (uint256 amount) {
        amount = accruedFees[currency];
        if (amount == 0) revert NothingToBurn();
        accruedFees[currency] = 0;
        totalFeesBurned[currency] += amount;
        emit FeesBurned(currency, amount);
        // The callback returns nothing; the transfer inside it reverts on failure.
        // forge-lint: disable-next-line(unused-return)
        poolManager.unlock(abi.encode(currency, amount));
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only reachable through `burnFees`: the PoolManager calls back whoever called `unlock`,
    /// and the hook only calls `unlock` from `burnFees`. Transfers claims; never `take`s tokens.
    function unlockCallback(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        bool ok = poolManager.transfer(DEAD, currency.toId(), amount);
        if (!ok) revert ClaimTransferFailed();
        return "";
    }

    // ------------------------------------------------------------------------------------------
    // Callbacks this hook does not declare. The address carries no bit for them, so the PoolManager
    // never calls them; they revert so a direct caller gets a clear answer.
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // ------------------------------------------------------------------------------------------
    // Transient storage
    // ------------------------------------------------------------------------------------------

    function _preSwapPriceSlot(PoolId poolId) private pure returns (bytes32) {
        return keccak256(abi.encode(PRE_SWAP_PRICE_NAMESPACE, poolId));
    }

    function _tstorePreSwapPrice(PoolId poolId, uint160 sqrtPriceX96) private {
        bytes32 slot = _preSwapPriceSlot(poolId);
        assembly ("memory-safe") {
            tstore(slot, sqrtPriceX96)
        }
    }

    function _tloadPreSwapPrice(PoolId poolId) private view returns (uint160 sqrtPriceX96) {
        bytes32 slot = _preSwapPriceSlot(poolId);
        assembly ("memory-safe") {
            sqrtPriceX96 := tload(slot)
        }
    }
}
