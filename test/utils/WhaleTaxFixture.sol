// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {WhaleToken} from "../../src/WhaleToken.sol";
import {WhaleTaxHook} from "../../src/WhaleTaxHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {BatchSwapRouter} from "./BatchSwapRouter.sol";

/// @notice Shared scaffolding: a real PoolManager, the WHAL token, the hook at a mined address,
/// v4-core's test routers, and helpers to read prices, engineer exact price moves and decode events.
abstract contract WhaleTaxFixture is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ---- Rehearsal parameters ------------------------------------------------------------------
    // The manifest fixes the live values. These stand in for them and are documented in the README.

    /// @dev ~5,000,000 WHAL per ETH. 1.0001^154200 = 4.99e6. Multiple of the 60 tick spacing.
    int24 internal constant REHEARSAL_TICK = 154_200;
    /// @dev Half the supply goes into the one-sided seed.
    uint256 internal constant REHEARSAL_SEED_WHAL = 500_000_000 ether;
    uint24 internal constant POOL_FEE = 3_000;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant MIN_USABLE_TICK = -887_220; // TickMath.minUsableTick(60)
    int24 internal constant MAX_USABLE_TICK = 887_220;

    uint160 internal constant MIN_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    Currency internal constant ETH = CurrencyLibrary.ADDRESS_ZERO;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ---- Deployed pieces ----------------------------------------------------------------------

    PoolManager internal manager;
    WhaleToken internal whal;
    Currency internal WHAL;
    WhaleTaxHook internal hook;
    bytes32 internal hookSalt;

    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    BatchSwapRouter internal batchRouter;

    PoolKey internal key;
    PoolId internal poolId;

    /// @dev Decoded `WhaleTax` event.
    struct TaxEvent {
        PoolId poolId;
        uint256 moveBps;
        uint256 feeBps;
        Currency currency;
        uint256 fee;
    }

    receive() external payable {}

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        whal = new WhaleToken();
        WHAL = Currency.wrap(address(whal));

        (hook, hookSalt) = deployHookAtMinedAddress(manager, address(this));

        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        batchRouter = new BatchSwapRouter(manager);
        whal.approve(address(swapRouter), type(uint256).max);
        whal.approve(address(lpRouter), type(uint256).max);
        whal.approve(address(batchRouter), type(uint256).max);
        vm.deal(address(this), 10_000_000 ether);

        key = PoolKey({
            currency0: ETH, currency1: WHAL, fee: POOL_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))
        });
        poolId = key.toId();
    }

    // ---- Deployment ---------------------------------------------------------------------------

    /// @dev Mines a salt for the 0x00C4 bits and deploys with CREATE2 from `deployer` (this contract
    /// unless a test pranks), exactly like the factory will.
    function deployHookAtMinedAddress(IPoolManager poolManager, address deployer)
        internal
        returns (WhaleTaxHook deployed, bytes32 salt)
    {
        bytes memory creationCode = abi.encodePacked(type(WhaleTaxHook).creationCode, abi.encode(poolManager));
        address predicted;
        (predicted, salt) = HookMiner.find(deployer, HookFlags.WHALE_TAX, creationCode, 500_000);
        deployed = new WhaleTaxHook{salt: salt}(poolManager);
        assertEq(address(deployed), predicted, "hook landed somewhere else than mined");
        assertTrue(HookFlags.matches(address(deployed), HookFlags.WHALE_TAX), "hook address bits");
    }

    // ---- Pool helpers -------------------------------------------------------------------------

    function initializePool(int24 tick) internal returns (uint160 sqrtPriceX96) {
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        manager.initialize(key, sqrtPriceX96);
    }

    /// @dev The factory's seed: all WHAL, in the range ending at the current tick, so the pool holds
    /// no ETH until the first buy.
    function seedOneSidedWhal(int24 tick, uint256 amountWhal) internal returns (uint128 liquidity) {
        uint160 lower = TickMath.getSqrtPriceAtTick(MIN_USABLE_TICK);
        uint160 upper = TickMath.getSqrtPriceAtTick(tick);
        liquidity = LiquidityAmounts.getLiquidityForAmount1(lower, upper, amountWhal);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: MIN_USABLE_TICK,
                tickUpper: tick,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev Symmetric liquidity around the current tick, for tests that need trades in both directions.
    function seedTwoSided(int24 tick, int24 halfWidth, uint128 liquidity) internal {
        int24 lowerTick = tick - halfWidth;
        int24 upperTick = tick + halfWidth;
        uint256 ethNeeded = _amount0ForLiquidity(tick, upperTick, liquidity) * 2;
        lpRouter.modifyLiquidity{value: ethNeeded}(
            key,
            ModifyLiquidityParams({
                tickLower: lowerTick, tickUpper: upperTick, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
    }

    function _amount0ForLiquidity(int24 fromTick, int24 toTick, uint128 liquidity) internal pure returns (uint256) {
        uint160 a = TickMath.getSqrtPriceAtTick(fromTick);
        uint160 b = TickMath.getSqrtPriceAtTick(toTick);
        // amount0 = L * (b - a) / (a * b) in Q96 terms; generous upper bound is fine here.
        return (uint256(liquidity) * (b - a) / a) * (1 << 96) / b + 1;
    }

    function pm() internal view returns (IPoolManager) {
        return IPoolManager(address(manager));
    }

    function currentSqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = pm().getSlot0(poolId);
    }

    function currentTick() internal view returns (int24 tick) {
        (, tick,,) = pm().getSlot0(poolId);
    }

    // ---- Swap helpers -------------------------------------------------------------------------

    /// @dev Swap through PoolSwapTest. ETH is attached whenever ETH could be the input; the router
    /// refunds what it does not use.
    function swap(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal
        returns (BalanceDelta delta)
    {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        uint256 value = 0;
        if (zeroForOne) {
            value = amountSpecified < 0 ? uint256(-amountSpecified) : address(this).balance / 2;
        }
        delta = swapRouter.swap{value: value}(key, params, settings, "");
    }

    function swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta delta) {
        return swap(zeroForOne, amountSpecified, zeroForOne ? MIN_LIMIT : MAX_LIMIT);
    }

    function magnitude(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-int256(x)) : uint256(int256(x));
    }

    // ---- Price engineering --------------------------------------------------------------------

    /// @dev The sqrt price at which P_after / P_before = numerator / denominator, rounded away from
    /// the starting price, so a swap stopping exactly there moves the price by at least that ratio.
    function sqrtPriceForPriceRatio(uint160 sqrtBefore, uint256 numerator, uint256 denominator)
        internal
        pure
        returns (uint160)
    {
        uint256 b = uint256(sqrtBefore);
        require(b < (1 << 115), "fixture: sqrt price too large to square");
        uint256 target = FixedPointMathLib.sqrt((b * b * numerator) / denominator);
        if (numerator >= denominator) target += 1;
        require(target > TickMath.MIN_SQRT_PRICE && target < TickMath.MAX_SQRT_PRICE, "fixture: target out of range");
        return uint160(target);
    }

    // ---- Event decoding -----------------------------------------------------------------------

    /// @dev All `WhaleTax` events emitted by the hook in the recorded logs, in order.
    function taxEvents(Vm.Log[] memory logs) internal view returns (TaxEvent[] memory events) {
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == WhaleTaxHook.WhaleTax.selector) n++;
        }
        events = new TaxEvent[](n);
        uint256 j;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != WhaleTaxHook.WhaleTax.selector) continue;
            (uint256 moveBps, uint256 feeBps, uint256 fee) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            events[j++] = TaxEvent({
                poolId: PoolId.wrap(logs[i].topics[1]),
                moveBps: moveBps,
                feeBps: feeBps,
                currency: Currency.wrap(address(uint160(uint256(logs[i].topics[2])))),
                fee: fee
            });
        }
    }

    /// @dev The post-swap sqrt prices reported by the PoolManager's `Swap` events, in order.
    function swapEventPrices(Vm.Log[] memory logs) internal view returns (uint160[] memory prices) {
        bytes32 sig = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == sig) n++;
        }
        prices = new uint160[](n);
        uint256 j;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != sig) continue;
            (,, uint160 sqrtPriceX96,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            prices[j++] = sqrtPriceX96;
        }
    }

    /// @dev Runs one swap under `vm.recordLogs` and returns the delta plus the single tax event.
    function swapAndCapture(bool zeroForOne, int256 amountSpecified, uint160 limit)
        internal
        returns (BalanceDelta delta, TaxEvent memory ev)
    {
        vm.recordLogs();
        delta = swap(zeroForOne, amountSpecified, limit);
        TaxEvent[] memory evs = taxEvents(vm.getRecordedLogs());
        assertEq(evs.length, 1, "expected exactly one WhaleTax event");
        ev = evs[0];
    }

    // ---- Accounting checks --------------------------------------------------------------------

    /// @dev The core accounting invariant: claims held by the hook equal fees not yet burned, and
    /// lifetime collected equals burned plus unburned.
    function assertClaimsMatchAccrued() internal view {
        assertEq(hook.claimsOf(ETH), hook.accruedFees(ETH), "ETH claims != accrued");
        assertEq(hook.claimsOf(WHAL), hook.accruedFees(WHAL), "WHAL claims != accrued");
        assertEq(hook.totalFeesCollected(ETH), hook.accruedFees(ETH) + hook.totalFeesBurned(ETH), "ETH totals");
        assertEq(hook.totalFeesCollected(WHAL), hook.accruedFees(WHAL) + hook.totalFeesBurned(WHAL), "WHAL totals");
        assertEq(manager.balanceOf(DEAD, ETH.toId()), hook.totalFeesBurned(ETH), "DEAD ETH claims");
        assertEq(manager.balanceOf(DEAD, WHAL.toId()), hook.totalFeesBurned(WHAL), "DEAD WHAL claims");
    }

    /// @dev What the hook must have reported for a swap that moved the price from `before` to `after`
    /// and left the swapper a net unspecified amount of `netUnspecified`.
    function assertTaxEventConsistent(TaxEvent memory ev, uint160 before, uint160 after_, uint256 netUnspecified)
        internal
        view
    {
        assertEq(PoolId.unwrap(ev.poolId), PoolId.unwrap(poolId), "event poolId");
        assertEq(ev.moveBps, hook.priceMoveBps(before, after_), "event moveBps");
        assertEq(ev.feeBps, hook.feeBpsForMove(ev.moveBps), "event feeBps");
        assertGe(ev.feeBps, 30, "fee floor");
        assertLe(ev.feeBps, 500, "fee cap");
        // Exact-in: net = gross - fee. Exact-out: net = gross + fee. Either way fee = floor(gross * feeBps / 1e4).
        uint256 grossOut = netUnspecified + ev.fee;
        uint256 grossIn = netUnspecified - ev.fee;
        bool exactInShape = ev.fee == hook.feeAmount(grossOut, ev.feeBps);
        bool exactOutShape = netUnspecified >= ev.fee && ev.fee == hook.feeAmount(grossIn, ev.feeBps);
        assertTrue(exactInShape || exactOutShape, "fee is not feeBps of the gross unspecified leg");
        assertLe(ev.fee * 10_000, (netUnspecified + ev.fee) * 500, "fee exceeds 5% of the leg");
    }
}
