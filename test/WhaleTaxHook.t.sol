// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {WhaleTaxFixture} from "./utils/WhaleTaxFixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {WhaleTaxHook} from "../src/WhaleTaxHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";

/// @dev Calls `unlock` on the manager so that the manager calls *this* contract back, then tries to
/// reach the hook's callback from inside the lock. Shows a third party cannot drive it.
contract UnlockIntruder is IUnlockCallback {
    IPoolManager immutable manager;
    WhaleTaxHook immutable hook;
    bytes public lastError;

    constructor(IPoolManager m, WhaleTaxHook h) {
        manager = m;
        hook = h;
    }

    function attack(Currency currency, uint256 amount) external {
        manager.unlock(abi.encode(currency, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory err) = address(hook).call(abi.encodeCall(IUnlockCallback.unlockCallback, (data)));
        require(!ok, "hook accepted a stranger");
        lastError = err;
        return "";
    }
}

/// @dev Raw CREATE / CREATE2 that reports the revert data instead of bubbling it.
contract RawDeployer {
    function tryCreate(bytes memory creationCode) external returns (address at, bytes memory reason) {
        assembly ("memory-safe") {
            at := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        if (at == address(0)) reason = _returnData();
    }

    function tryCreate2(bytes memory creationCode, bytes32 salt) external returns (address at, bytes memory reason) {
        assembly ("memory-safe") {
            at := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        if (at == address(0)) reason = _returnData();
    }

    function _returnData() private pure returns (bytes memory data) {
        assembly ("memory-safe") {
            data := mload(0x40)
            mstore(data, returndatasize())
            returndatacopy(add(data, 0x20), 0, returndatasize())
            mstore(0x40, add(add(data, 0x20), returndatasize()))
        }
    }
}

contract WhaleTaxHookTest is WhaleTaxFixture {
    using PoolIdLibrary for PoolKey;

    uint128 constant TWO_SIDED_LIQUIDITY = 2e23; // ~116M WHAL and ~23 ETH around the rehearsal price
    int24 constant HALF_WIDTH = 6_000; // +-6000 ticks: price factor 1.82 each way

    uint160 startPrice;

    function setUp() public override {
        super.setUp();
        startPrice = initializePool(REHEARSAL_TICK);
    }

    function _twoSided() internal {
        seedTwoSided(REHEARSAL_TICK, HALF_WIDTH, TWO_SIDED_LIQUIDITY);
        assertGt(address(manager).balance, 0, "two-sided pool holds ETH");
    }

    // =========================================================================================
    // Permissions and construction
    // =========================================================================================

    function test_permissionsAreExactlyBeforeSwapAfterSwapAfterSwapReturnDelta() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.WHALE_TAX, 0x00C4);
        assertEq(HookFlags.flagsOf(address(hook)), 0x00C4, "address bits");
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_constructorRejectsAnAddressWithoutTheBits() public {
        bytes memory creationCode = abi.encodePacked(type(WhaleTaxHook).creationCode, abi.encode(address(manager)));
        RawDeployer deployer = new RawDeployer();

        // A plain CREATE lands wherever the nonce says. Find a nonce whose address does not carry
        // the bits (almost every one) and show the constructor refuses it with the v4-core error.
        address predicted = vm.computeCreateAddress(address(deployer), vm.getNonce(address(deployer)));
        vm.assume(!HookFlags.matches(predicted, HookFlags.WHALE_TAX));
        (address at, bytes memory reason) = deployer.tryCreate(creationCode);
        assertEq(at, address(0), "deployment should have failed");
        assertEq(bytes4(reason), Hooks.HookAddressNotValid.selector);
        assertEq(abi.decode(_slice(reason, 4), (address)), predicted, "reports the rejected address");

        // The very same creation code succeeds through CREATE2 at a mined address.
        (address mined, bytes32 salt) = HookMiner.find(address(deployer), HookFlags.WHALE_TAX, creationCode, 500_000);
        (address at2,) = deployer.tryCreate2(creationCode, salt);
        assertEq(at2, mined);
    }

    function _slice(bytes memory data, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(data.length - from);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[from + i];
        }
    }

    function test_runtimeCodeHasNoEscapeHatch() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2, "forbidden opcode");
        }
    }

    function test_constantsMatchTheSpec() public view {
        assertEq(hook.BASE_FEE_BPS(), 30);
        assertEq(hook.MAX_FEE_BPS(), 500);
        assertEq(hook.MOVE_CAP_BPS(), 500);
        assertEq(hook.BPS(), 10_000);
        assertEq(hook.DEAD(), 0x000000000000000000000000000000000000dEaD);
    }

    // =========================================================================================
    // Pure maths
    // =========================================================================================

    function test_feeCurve() public view {
        assertEq(hook.feeBpsForMove(0), 30);
        assertEq(hook.feeBpsForMove(1), 30); // floor(470/500) = 0
        assertEq(hook.feeBpsForMove(2), 31);
        assertEq(hook.feeBpsForMove(10), 39);
        assertEq(hook.feeBpsForMove(100), 124);
        assertEq(hook.feeBpsForMove(250), 265);
        assertEq(hook.feeBpsForMove(499), 499);
        assertEq(hook.feeBpsForMove(500), 500);
        assertEq(hook.feeBpsForMove(501), 500);
        assertEq(hook.feeBpsForMove(10_000), 500);
        assertEq(hook.feeBpsForMove(type(uint256).max), 500);
    }

    function testFuzz_feeCurveIsBoundedMonotoneAndExact(uint256 a, uint256 b) public view {
        uint256 fa = hook.feeBpsForMove(a);
        uint256 fb = hook.feeBpsForMove(b);
        assertGe(fa, 30);
        assertLe(fa, 500);
        if (a <= b) assertLe(fa, fb);
        uint256 m = a > 500 ? 500 : a;
        assertEq(fa, 30 + (470 * m) / 500);
    }

    function test_priceMoveBpsDirections() public view {
        uint160 p = startPrice;
        assertEq(hook.priceMoveBps(p, p), 0);
        assertEq(hook.priceMoveBps(0, p), 0, "no recorded pre price reads as no move");
        // sqrt doubles: price x4: +300%.
        assertEq(hook.priceMoveBps(p, p * 2), 30_000);
        // sqrt halves: price /4: -75%.
        assertEq(hook.priceMoveBps(p, p / 2), 7_500);
        // A fall can never reach 100%: the price after is still positive, so the floor is 9,999.
        assertEq(hook.priceMoveBps(p, 1), 9_999);
        assertEq(hook.priceMoveBps(TickMath.MAX_SQRT_PRICE, TickMath.MIN_SQRT_PRICE), 9_999);
        assertEq(hook.priceMoveBps(p, p - 1), 0, "one wei of sqrt price is no move");
        // Extreme rise saturates instead of overflowing.
        assertEq(hook.priceMoveBps(TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE), hook.MOVE_BPS_SATURATED());
        assertEq(hook.priceMoveBps(1, TickMath.MAX_SQRT_PRICE), hook.MOVE_BPS_SATURATED());
        // Just under the saturation threshold still computes.
        uint160 lo = 1_000;
        uint160 hi = uint160(uint256(lo) << 64) - 1;
        assertLt(hook.priceMoveBps(lo, hi), hook.MOVE_BPS_SATURATED());
    }

    function test_priceMoveBpsAtTwoAndAHalfPercentBothWays() public view {
        uint160 up = sqrtPriceForPriceRatio(startPrice, 10_250_005, 10_000_000);
        uint160 down = sqrtPriceForPriceRatio(startPrice, 9_749_995, 10_000_000);
        assertEq(hook.priceMoveBps(startPrice, up), 250);
        assertEq(hook.priceMoveBps(startPrice, down), 250);
        assertEq(hook.feeBpsForMove(250), 265);
        // Rounding is a floor: a hair under 2.5% is 249.
        uint160 upShort = sqrtPriceForPriceRatio(startPrice, 10_249_995, 10_000_000);
        assertEq(hook.priceMoveBps(startPrice, upShort), 249);
    }

    function testFuzz_priceMoveBpsNeverRevertsAndIsSymmetricInSign(uint160 a, uint160 b) public view {
        a = uint160(bound(a, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        b = uint160(bound(b, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        uint256 m = hook.priceMoveBps(a, b);
        if (b <= a) assertLt(m, 10_000, "a fall stays under 100%");
        if (b >= (uint256(a) << 64)) {
            assertEq(m, hook.MOVE_BPS_SATURATED(), "saturates past a 2^64 sqrt ratio");
            return;
        }
        assertLt(m, hook.MOVE_BPS_SATURATED());
        // Reference in plain 256-bit arithmetic for the range where the squares fit.
        if (a < (1 << 120) && b < (1 << 120)) {
            uint256 pa = uint256(a) * a;
            uint256 pb = uint256(b) * b;
            uint256 expected = pb >= pa ? ((pb - pa) * 10_000) / pa : ((pa - pb) * 10_000) / pa;
            assertApproxEqAbs(m, expected, 1);
        }
    }

    function testFuzz_feeNeverExceedsFivePercentOfTheLeg(uint256 leg, uint256 moveBps) public view {
        leg = bound(leg, 0, uint256(type(uint128).max));
        uint256 fee = hook.feeAmount(leg, hook.feeBpsForMove(moveBps));
        assertLe(fee, (leg * 500) / 10_000);
        assertLe(fee, leg);
    }

    // =========================================================================================
    // Access control
    // =========================================================================================

    function test_swapCallbacksRefuseNonPoolManager() public {
        SwapParams memory params = SwapParams(true, -1 ether, MIN_LIMIT);
        vm.expectRevert(WhaleTaxHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(WhaleTaxHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, toBalanceDelta(-1 ether, 1 ether), "");
        vm.expectRevert(WhaleTaxHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(WHAL, uint256(1)));
    }

    function test_swapCallbacksRefuseEvenAPrankedStranger() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(WhaleTaxHook.NotPoolManager.selector);
        hook.beforeSwap(stranger, key, SwapParams(true, -1 ether, MIN_LIMIT), "");
    }

    function test_undeclaredCallbacksRevert() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        BalanceDelta zero = toBalanceDelta(0, 0);
        vm.expectRevert(WhaleTaxHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(this), key, startPrice);
        vm.expectRevert(WhaleTaxHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, startPrice, 0);
        vm.expectRevert(WhaleTaxHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(WhaleTaxHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(WhaleTaxHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(WhaleTaxHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(WhaleTaxHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(WhaleTaxHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
    }

    function test_strangerCannotDriveTheUnlockCallback() public {
        _twoSided();
        swap(true, -1 ether);
        uint256 accrued = hook.accruedFees(WHAL);
        assertGt(accrued, 0);

        UnlockIntruder intruder = new UnlockIntruder(IPoolManager(address(manager)), hook);
        intruder.attack(WHAL, accrued);
        assertEq(bytes4(intruder.lastError()), WhaleTaxHook.NotPoolManager.selector);
        assertEq(hook.claimsOf(WHAL), accrued, "claims untouched");
        assertClaimsMatchAccrued();
    }

    // =========================================================================================
    // Swaps: every direction and shape
    // =========================================================================================

    function test_exactInZeroForOne_feeFromWhalOutput() public {
        _twoSided();
        uint160 before = currentSqrtPrice();
        (BalanceDelta delta, TaxEvent memory ev) = swapAndCapture(true, -1 ether, MIN_LIMIT);
        assertEq(magnitude(delta.amount0()), 1 ether, "exact ETH in");
        uint256 net = magnitude(delta.amount1());
        assertTaxEventConsistent(ev, before, currentSqrtPrice(), net);
        assertEq(Currency.unwrap(ev.currency), address(whal));
        assertGt(ev.fee, 0);
        assertEq(ev.fee, hook.feeAmount(net + ev.fee, ev.feeBps), "fee = feeBps of the gross output");
        assertEq(hook.claimsOf(WHAL), ev.fee);
        assertEq(hook.claimsOf(ETH), 0);
        assertClaimsMatchAccrued();
    }

    function test_exactOutZeroForOne_feeOnTopOfEthInput() public {
        _twoSided();
        uint160 before = currentSqrtPrice();
        uint256 ethBefore = address(this).balance;
        (BalanceDelta delta, TaxEvent memory ev) = swapAndCapture(true, int256(1_000_000 ether), MIN_LIMIT);
        assertEq(magnitude(delta.amount1()), 1_000_000 ether, "exact WHAL out");
        uint256 paid = magnitude(delta.amount0());
        assertEq(ethBefore - address(this).balance, paid, "router charged exactly the delta");
        assertTaxEventConsistent(ev, before, currentSqrtPrice(), paid);
        assertEq(Currency.unwrap(ev.currency), address(0), "fee in ETH");
        assertGt(ev.fee, 0);
        assertEq(ev.fee, hook.feeAmount(paid - ev.fee, ev.feeBps), "fee = feeBps of the gross input");
        assertEq(hook.claimsOf(ETH), ev.fee);
        assertEq(hook.claimsOf(WHAL), 0);
        assertClaimsMatchAccrued();
    }

    function test_exactInOneForZero_feeFromEthOutput() public {
        _twoSided();
        uint160 before = currentSqrtPrice();
        uint256 ethBefore = address(this).balance;
        (BalanceDelta delta, TaxEvent memory ev) = swapAndCapture(false, -int256(1_000_000 ether), MAX_LIMIT);
        assertEq(magnitude(delta.amount1()), 1_000_000 ether, "exact WHAL in");
        uint256 net = magnitude(delta.amount0());
        assertEq(address(this).balance - ethBefore, net, "received the net ETH");
        assertTaxEventConsistent(ev, before, currentSqrtPrice(), net);
        assertEq(Currency.unwrap(ev.currency), address(0));
        assertGt(ev.fee, 0);
        assertEq(ev.fee, hook.feeAmount(net + ev.fee, ev.feeBps));
        assertEq(hook.claimsOf(ETH), ev.fee);
        assertClaimsMatchAccrued();
    }

    function test_exactOutOneForZero_feeOnTopOfWhalInput() public {
        _twoSided();
        uint160 before = currentSqrtPrice();
        uint256 whalBefore = whal.balanceOf(address(this));
        (BalanceDelta delta, TaxEvent memory ev) = swapAndCapture(false, int256(1 ether), MAX_LIMIT);
        assertEq(magnitude(delta.amount0()), 1 ether, "exact ETH out");
        uint256 paid = magnitude(delta.amount1());
        assertEq(whalBefore - whal.balanceOf(address(this)), paid);
        assertTaxEventConsistent(ev, before, currentSqrtPrice(), paid);
        assertEq(Currency.unwrap(ev.currency), address(whal));
        assertGt(ev.fee, 0);
        assertEq(ev.fee, hook.feeAmount(paid - ev.fee, ev.feeBps));
        assertEq(hook.claimsOf(WHAL), ev.fee);
        assertClaimsMatchAccrued();
    }

    function test_tinySwapPaysThirtyBps() public {
        _twoSided();
        (, TaxEvent memory ev) = swapAndCapture(true, -1e12, MIN_LIMIT); // 0.000001 ETH against ~23 ETH
        assertEq(ev.moveBps, 0);
        assertEq(ev.feeBps, 30);
        (, ev) = swapAndCapture(false, -1e18, MAX_LIMIT); // 1 WHAL
        assertEq(ev.feeBps, 30);
    }

    function test_dustSwapsDoNotRevert() public {
        _twoSided();
        (BalanceDelta d1, TaxEvent memory e1) = swapAndCapture(true, -1, MIN_LIMIT);
        assertEq(magnitude(d1.amount0()), 1);
        assertEq(e1.feeBps, 30);
        assertEq(e1.fee, hook.feeAmount(magnitude(d1.amount1()) + e1.fee, 30));

        (BalanceDelta d2, TaxEvent memory e2) = swapAndCapture(false, -1, MAX_LIMIT);
        assertEq(magnitude(d2.amount1()), 1);
        assertEq(d2.amount0(), 0, "1 wei of WHAL buys no ETH");
        assertEq(e2.fee, 0);

        (BalanceDelta d3, TaxEvent memory e3) = swapAndCapture(true, 1, MIN_LIMIT);
        assertEq(d3.amount1(), 1, "exact 1 wei WHAL out");
        assertEq(e3.fee, 0, "fee on a 1-wei-ish leg floors to zero");

        (BalanceDelta d4, TaxEvent memory e4) = swapAndCapture(false, 1, MAX_LIMIT);
        assertEq(d4.amount0(), 1, "exact 1 wei ETH out");
        assertGt(magnitude(d4.amount1()), 0);
        assertEq(e4.fee, hook.feeAmount(magnitude(d4.amount1()) - e4.fee, e4.feeBps));
        assertClaimsMatchAccrued();
    }

    function test_twoAndAHalfPercentMoveUpPays265() public {
        _twoSided();
        uint160 limit = sqrtPriceForPriceRatio(currentSqrtPrice(), 10_250_005, 10_000_000);
        (, TaxEvent memory ev) = swapAndCapture(false, -int256(1e27), limit);
        assertEq(currentSqrtPrice(), limit, "swap stopped at the limit");
        assertEq(ev.moveBps, 250);
        assertEq(ev.feeBps, 265);
    }

    function test_twoAndAHalfPercentMoveDownPays265() public {
        _twoSided();
        uint160 limit = sqrtPriceForPriceRatio(currentSqrtPrice(), 9_749_995, 10_000_000);
        (, TaxEvent memory ev) = swapAndCapture(true, -int256(1_000 ether), limit);
        assertEq(currentSqrtPrice(), limit);
        assertEq(ev.moveBps, 250);
        assertEq(ev.feeBps, 265);
    }

    function test_fivePercentMoveOrMorePays500() public {
        _twoSided();
        uint160 p0 = currentSqrtPrice();
        (, TaxEvent memory ev) =
            swapAndCapture(false, -int256(1e27), sqrtPriceForPriceRatio(p0, 10_500_005, 10_000_000));
        assertEq(ev.moveBps, 500);
        assertEq(ev.feeBps, 500);

        uint160 p1 = currentSqrtPrice();
        (, ev) = swapAndCapture(true, -int256(1_000 ether), sqrtPriceForPriceRatio(p1, 9_499_995, 10_000_000));
        assertEq(ev.moveBps, 500);
        assertEq(ev.feeBps, 500);

        uint160 p2 = currentSqrtPrice();
        (, ev) = swapAndCapture(false, -int256(1e27), sqrtPriceForPriceRatio(p2, 13, 10));
        assertGt(ev.moveBps, 2_900);
        assertEq(ev.feeBps, 500);
    }

    function testFuzz_anyMoveOfFivePercentOrMorePays500(uint256 ratioPpm, bool up) public {
        _twoSided();
        // Stay inside the seeded range (price factor 1.82 either way).
        ratioPpm = up ? bound(ratioPpm, 1_050_000, 1_700_000) : bound(ratioPpm, 600_000, 950_000);
        uint160 limit = sqrtPriceForPriceRatio(currentSqrtPrice(), ratioPpm, 1_000_000);
        (, TaxEvent memory ev) =
            up ? swapAndCapture(false, -int256(1e27), limit) : swapAndCapture(true, -int256(5_000 ether), limit);
        assertGe(ev.moveBps, 500);
        assertEq(ev.feeBps, 500);
    }

    function testFuzz_swapSizesAndShapes(uint256 amount, bool zeroForOne, bool exactIn) public {
        _twoSided();
        if (zeroForOne == exactIn) {
            amount = bound(amount, 1, 20 ether); // ETH leg specified
        } else {
            amount = bound(amount, 1, 50_000_000 ether); // WHAL leg specified
        }
        int256 specified = exactIn ? -int256(amount) : int256(amount);
        uint160 before = currentSqrtPrice();
        (BalanceDelta delta, TaxEvent memory ev) =
            swapAndCapture(zeroForOne, specified, zeroForOne ? MIN_LIMIT : MAX_LIMIT);
        bool specifiedIsCurrency0 = exactIn == zeroForOne;
        uint256 net = specifiedIsCurrency0 ? magnitude(delta.amount1()) : magnitude(delta.amount0());
        assertTaxEventConsistent(ev, before, currentSqrtPrice(), net);
        assertEq(Currency.unwrap(ev.currency), specifiedIsCurrency0 ? address(whal) : address(0));
        assertEq(hook.pendingPreSwapSqrtPriceX96(poolId), 0);
        assertClaimsMatchAccrued();
    }

    // =========================================================================================
    // Transient slot across several swaps in one transaction
    // =========================================================================================

    function test_twoSwapsInOneTransactionEachUseTheirOwnPreSwapPrice() public {
        _twoSided();
        uint160 p0 = currentSqrtPrice();

        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] = SwapParams({zeroForOne: true, amountSpecified: -int256(2 ether), sqrtPriceLimitX96: MIN_LIMIT});
        swaps[1] =
            SwapParams({zeroForOne: false, amountSpecified: -int256(3_000_000 ether), sqrtPriceLimitX96: MAX_LIMIT});

        vm.recordLogs();
        BalanceDelta[] memory deltas = batchRouter.swapMany{value: 2 ether}(key, swaps);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        TaxEvent[] memory evs = taxEvents(logs);
        uint160[] memory prices = swapEventPrices(logs);
        assertEq(evs.length, 2);
        assertEq(prices.length, 2);
        assertEq(prices[1], currentSqrtPrice());
        assertTrue(prices[0] != p0 && prices[1] != prices[0], "both swaps moved the price");

        // First swap measured from the pool's price before the transaction...
        assertEq(evs[0].moveBps, hook.priceMoveBps(p0, prices[0]), "first swap uses the opening price");
        assertTaxEventConsistent(evs[0], p0, prices[0], magnitude(deltas[0].amount1()));
        // ...and the second from the price the first one left, not from the opening price.
        assertEq(evs[1].moveBps, hook.priceMoveBps(prices[0], prices[1]), "second swap uses its own pre price");
        assertTrue(evs[1].moveBps != hook.priceMoveBps(p0, prices[1]), "not measured from the opening price");
        assertTaxEventConsistent(evs[1], prices[0], prices[1], magnitude(deltas[1].amount0()));

        assertEq(hook.pendingPreSwapSqrtPriceX96(poolId), 0, "slot cleared after the last swap");
        assertEq(hook.claimsOf(WHAL), evs[0].fee);
        assertEq(hook.claimsOf(ETH), evs[1].fee);
        assertClaimsMatchAccrued();
    }

    function test_threeSwapsSameDirectionInOneTransaction() public {
        _twoSided();
        uint160 p0 = currentSqrtPrice();
        SwapParams[] memory swaps = new SwapParams[](3);
        for (uint256 i = 0; i < 3; i++) {
            swaps[i] = SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: MIN_LIMIT});
        }
        vm.recordLogs();
        batchRouter.swapMany{value: 3 ether}(key, swaps);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        TaxEvent[] memory evs = taxEvents(logs);
        uint160[] memory prices = swapEventPrices(logs);
        assertEq(evs.length, 3);
        uint160 prev = p0;
        uint256 summed;
        for (uint256 i = 0; i < 3; i++) {
            assertEq(evs[i].moveBps, hook.priceMoveBps(prev, prices[i]));
            prev = prices[i];
            summed += evs[i].fee;
        }
        // The tax is per swap: three 1 ETH swaps each see a smaller move than one 3 ETH swap would.
        assertLt(evs[0].moveBps, hook.priceMoveBps(p0, prices[2]));
        assertEq(hook.claimsOf(WHAL), summed);
        assertEq(hook.pendingPreSwapSqrtPriceX96(poolId), 0);
    }

    // =========================================================================================
    // Pools this hook leaves alone
    // =========================================================================================

    function test_poolWhoseCurrency0IsNotEthGetsZeroDeltasAndNoEffect() public {
        MockERC20 a = new MockERC20("A", "A", 1e30);
        MockERC20 b = new MockERC20("B", "B", 1e30);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        t0.approve(address(lpRouter), type(uint256).max);
        t1.approve(address(lpRouter), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);

        PoolKey memory erc20Key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        PoolId erc20Id = erc20Key.toId();
        manager.initialize(erc20Key, TickMath.getSqrtPriceAtTick(0));
        lpRouter.modifyLiquidity(erc20Key, ModifyLiquidityParams(-6_000, 6_000, 1e24, bytes32(0)), "");

        vm.recordLogs();
        BalanceDelta delta = swapRouter.swap(
            erc20Key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1e21), sqrtPriceLimitX96: MIN_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(taxEvents(logs).length, 0, "no WhaleTax event");
        assertGt(delta.amount1(), 0, "swap went through");
        // The PoolManager's Swap event carries the pool's own delta; with no hook delta it must equal
        // what the swapper got.
        bytes32 sig = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != sig) continue;
            (int128 a0, int128 a1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            assertEq(a0, delta.amount0(), "hook took nothing on currency0");
            assertEq(a1, delta.amount1(), "hook took nothing on currency1");
            seen = true;
        }
        assertTrue(seen);
        assertEq(hook.claimsOf(Currency.wrap(address(t0))), 0);
        assertEq(hook.claimsOf(Currency.wrap(address(t1))), 0);
        assertEq(hook.accruedFees(Currency.wrap(address(t0))), 0);
        assertEq(hook.accruedFees(Currency.wrap(address(t1))), 0);
        assertEq(hook.pendingPreSwapSqrtPriceX96(erc20Id), 0, "no transient write for a non-ETH pool");
    }

    // =========================================================================================
    // Zero liquidity: the price jumps to the limit
    // =========================================================================================

    function test_zeroLiquidityJumpUpToTheLimit() public {
        // No liquidity at all: the swap moves the price to the limit and exchanges nothing.
        (BalanceDelta delta, TaxEvent memory ev) = swapAndCapture(false, -int256(1 ether), MAX_LIMIT);
        assertEq(delta.amount0(), 0);
        assertEq(delta.amount1(), 0);
        assertEq(currentSqrtPrice(), MAX_LIMIT);
        assertEq(ev.moveBps, hook.priceMoveBps(startPrice, MAX_LIMIT));
        assertEq(ev.feeBps, 500);
        assertEq(ev.fee, 0);
        assertEq(hook.claimsOf(ETH), 0);
        assertClaimsMatchAccrued();
    }

    function test_zeroLiquidityJumpDownToTheLimit() public {
        (BalanceDelta delta, TaxEvent memory ev) = swapAndCapture(true, -int256(1 ether), MIN_LIMIT);
        assertEq(delta.amount0(), 0);
        assertEq(delta.amount1(), 0);
        assertEq(currentSqrtPrice(), MIN_LIMIT);
        assertLe(ev.moveBps, 10_000);
        assertEq(ev.feeBps, 500);
        assertEq(ev.fee, 0);
        assertClaimsMatchAccrued();
    }

    function test_swapThatRunsPastTheLiquidityStillSettles() public {
        _twoSided();
        // Far more WHAL than the range can absorb: price runs to the top of the range, the swap
        // fills partially, the fee applies to what was actually received.
        uint160 before = currentSqrtPrice();
        (BalanceDelta delta, TaxEvent memory ev) = swapAndCapture(false, -int256(1e28), MAX_LIMIT);
        assertGt(magnitude(delta.amount0()), 0);
        assertLt(magnitude(delta.amount1()), 1e28, "partial fill");
        assertEq(ev.feeBps, 500);
        assertTaxEventConsistent(ev, before, currentSqrtPrice(), magnitude(delta.amount0()));
        assertClaimsMatchAccrued();
    }

    // =========================================================================================
    // burnFees
    // =========================================================================================

    function test_burnFeesSendsClaimsToDeadOnly() public {
        _twoSided();
        swap(true, -3 ether);
        swap(false, int256(1 ether));
        uint256 whalFees = hook.accruedFees(WHAL);
        assertGt(whalFees, 0);
        assertEq(hook.accruedFees(ETH), 0, "both swaps taxed WHAL");

        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        vm.expectEmit(true, false, false, true, address(hook));
        emit WhaleTaxHook.FeesBurned(WHAL, whalFees);
        uint256 burned = hook.burnFees(WHAL);

        assertEq(burned, whalFees);
        assertEq(hook.accruedFees(WHAL), 0);
        assertEq(hook.totalFeesBurned(WHAL), whalFees);
        assertEq(hook.totalFeesCollected(WHAL), whalFees);
        assertEq(hook.claimsOf(WHAL), 0);
        assertEq(manager.balanceOf(DEAD, WHAL.toId()), whalFees);
        assertEq(manager.balanceOf(anyone, WHAL.toId()), 0);
        assertEq(whal.balanceOf(anyone), 0);
        assertEq(whal.balanceOf(address(hook)), 0);
        assertEq(
            whal.balanceOf(address(manager)) >= whalFees, true, "tokens stay in the manager, backing DEAD's claims"
        );
        assertClaimsMatchAccrued();
    }

    function test_burnFeesWithNothingAccruedReverts() public {
        vm.expectRevert(WhaleTaxHook.NothingToBurn.selector);
        hook.burnFees(WHAL);
        vm.expectRevert(WhaleTaxHook.NothingToBurn.selector);
        hook.burnFees(ETH);
    }

    function test_burnFeesTwiceRevertsTheSecondTime() public {
        _twoSided();
        swap(true, -1 ether);
        hook.burnFees(WHAL);
        vm.expectRevert(WhaleTaxHook.NothingToBurn.selector);
        hook.burnFees(WHAL);
    }

    function test_burnFeesForEthClaims() public {
        _twoSided();
        swap(false, -int256(2_000_000 ether));
        uint256 ethFees = hook.accruedFees(ETH);
        assertGt(ethFees, 0);
        hook.burnFees(ETH);
        assertEq(manager.balanceOf(DEAD, ETH.toId()), ethFees);
        assertEq(hook.claimsOf(ETH), 0);
        assertEq(address(hook).balance, 0);
        assertClaimsMatchAccrued();
    }

    function test_feesKeepAccruingAfterABurn() public {
        _twoSided();
        swap(true, -1 ether);
        uint256 first = hook.burnFees(WHAL);
        swap(true, -1 ether);
        uint256 second = hook.accruedFees(WHAL);
        assertGt(second, 0);
        assertEq(hook.claimsOf(WHAL), second);
        assertEq(hook.totalFeesCollected(WHAL), first + second);
        assertEq(manager.balanceOf(DEAD, WHAL.toId()), first);
        assertClaimsMatchAccrued();
    }

    // =========================================================================================
    // The claims invariant, fuzzed over random sequences of swaps and burns
    // =========================================================================================

    function testFuzz_claimsAlwaysEqualUnburnedFees(uint256 seed, uint8 steps) public {
        _twoSided();
        steps = uint8(bound(steps, 1, 12));
        for (uint256 i = 0; i < steps; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = r % 10;
            if (action == 0) {
                if (hook.accruedFees(WHAL) > 0) hook.burnFees(WHAL);
            } else if (action == 1) {
                if (hook.accruedFees(ETH) > 0) hook.burnFees(ETH);
            } else {
                bool zeroForOne = (r >> 8) % 2 == 0;
                bool exactIn = (r >> 16) % 2 == 0;
                bool ethSpecified = zeroForOne == exactIn;
                uint256 amount = ethSpecified ? 1 + ((r >> 24) % 3 ether) : 1 + ((r >> 24) % 10_000_000 ether);
                swap(zeroForOne, exactIn ? -int256(amount) : int256(amount));
            }
            assertClaimsMatchAccrued();
            assertEq(hook.pendingPreSwapSqrtPriceX96(poolId), 0);
        }
    }
}
