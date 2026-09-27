// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {WhaleTaxFixture} from "./utils/WhaleTaxFixture.sol";
import {WhaleTaxHook} from "../src/WhaleTaxHook.sol";
import {WhaleToken} from "../src/WhaleToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {DeployWhaleTax} from "../script/DeployWhaleTax.s.sol";

/// @notice Mirrors what the launch factory does on Sepolia, in order: deploy the token (supply to
/// the factory), deploy the hook at a mined address, initialize the native-ETH pool at the manifest
/// price, seed one-sided WHAL liquidity, then let the first buy land in a pool that holds no ETH.
contract LaunchRehearsalTest is WhaleTaxFixture {
    address buyer = makeAddr("buyer");
    uint160 initialSqrtPrice;
    uint128 seededLiquidity;

    function setUp() public override {
        super.setUp();
        // The fixture (standing in for the factory) holds the whole supply and deployed the hook.
        assertEq(whal.balanceOf(address(this)), whal.TOTAL_SUPPLY(), "factory must hold the supply");
        vm.deal(buyer, 100_000 ether);
    }

    /// @dev Steps 1-3 of the launch: initialize and seed, exactly as the factory does.
    function _openPool() internal {
        initialSqrtPrice = initializePool(REHEARSAL_TICK);
        seededLiquidity = seedOneSidedWhal(REHEARSAL_TICK, REHEARSAL_SEED_WHAL);
    }

    function _buyerSwap(bool zeroForOne, int256 amountSpecified, uint256 value) internal returns (BalanceDelta delta) {
        vm.startPrank(buyer);
        delta = swapRouter.swap{value: value}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_LIMIT : MAX_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    // ---- The factory's own steps never revert ---------------------------------------------------

    function test_initializeAtManifestPriceDoesNotRevert() public {
        uint160 sqrtPrice = initializePool(REHEARSAL_TICK);
        assertEq(currentSqrtPrice(), sqrtPrice);
        assertEq(currentTick(), REHEARSAL_TICK);
    }

    function test_oneSidedSeedDoesNotRevertAndHoldsNoEth() public {
        _openPool();
        assertGt(seededLiquidity, 0);
        assertEq(address(manager).balance, 0, "pool must hold no ETH before the first buy");
        assertApproxEqRel(whal.balanceOf(address(manager)), REHEARSAL_SEED_WHAL, 1e12, "seed size");
        assertEq(currentSqrtPrice(), initialSqrtPrice, "seeding must not move the price");
    }

    function test_hookHasNoInitializeOrLiquidityPermissions() public view {
        assertEq(HookFlags.flagsOf(address(hook)), 0x00C4);
        assertFalse(hook.getHookPermissions().beforeInitialize);
        assertFalse(hook.getHookPermissions().afterInitialize);
        assertFalse(hook.getHookPermissions().beforeAddLiquidity);
        assertFalse(hook.getHookPermissions().afterAddLiquidity);
        assertFalse(hook.getHookPermissions().beforeRemoveLiquidity);
        assertFalse(hook.getHookPermissions().afterRemoveLiquidity);
    }

    // ---- The first buy ------------------------------------------------------------------------

    function test_firstBuyIntoEthLessPool() public {
        _openPool();
        assertEq(address(manager).balance, 0);

        uint256 spend = 1 ether;
        vm.recordLogs();
        BalanceDelta delta = _buyerSwap(true, -int256(spend), spend);
        TaxEvent[] memory evs = taxEvents(vm.getRecordedLogs());
        assertEq(evs.length, 1);

        uint256 received = magnitude(delta.amount1());
        assertEq(magnitude(delta.amount0()), spend, "paid the exact ETH");
        assertGt(received, 0, "got WHAL");
        assertEq(whal.balanceOf(buyer), received, "buyer holds the net WHAL");
        assertEq(address(manager).balance, spend, "pool now holds the ETH");

        assertTaxEventConsistent(evs[0], initialSqrtPrice, currentSqrtPrice(), received);
        assertEq(Currency.unwrap(evs[0].currency), address(whal), "fee taken from the WHAL output");
        assertGt(evs[0].fee, 0);
        assertEq(hook.claimsOf(WHAL), evs[0].fee, "fee held as ERC-6909 claims");
        assertEq(hook.claimsOf(ETH), 0);
        assertEq(hook.pendingPreSwapSqrtPriceX96(poolId), 0, "transient slot cleared");
        assertClaimsMatchAccrued();
    }

    function testFuzz_firstBuyOfAnySize(uint256 spend) public {
        spend = bound(spend, 1, 50_000 ether);
        _openPool();
        vm.recordLogs();
        BalanceDelta delta = _buyerSwap(true, -int256(spend), spend);
        TaxEvent[] memory evs = taxEvents(vm.getRecordedLogs());
        assertEq(evs.length, 1);
        assertTaxEventConsistent(evs[0], initialSqrtPrice, currentSqrtPrice(), magnitude(delta.amount1()));
        assertClaimsMatchAccrued();
    }

    /// @dev A sell before any buy: no ETH liquidity above the price, so the swap jumps to the limit,
    /// moves nothing, charges nothing, and does not revert.
    function test_sellIntoEthLessPoolIsHarmless() public {
        _openPool();
        whal.transfer(buyer, 1_000 ether);
        vm.prank(buyer);
        whal.approve(address(swapRouter), type(uint256).max);

        vm.recordLogs();
        BalanceDelta delta = _buyerSwap(false, -int256(1_000 ether), 0);
        TaxEvent[] memory evs = taxEvents(vm.getRecordedLogs());

        assertEq(delta.amount0(), 0, "no ETH out");
        assertEq(delta.amount1(), 0, "no WHAL in");
        assertEq(evs.length, 1);
        assertEq(evs[0].fee, 0);
        assertEq(evs[0].feeBps, 500, "price jumped to the limit: capped rate on a zero leg");
        assertEq(currentSqrtPrice(), MAX_LIMIT, "price at the limit");
        assertEq(hook.claimsOf(ETH), 0);
        assertClaimsMatchAccrued();
    }

    // ---- Life after launch ----------------------------------------------------------------------

    function test_buyThenSellThenBurn() public {
        _openPool();

        // Buy.
        _buyerSwap(true, -int256(5 ether), 5 ether);
        uint256 whalFee = hook.accruedFees(WHAL);
        assertGt(whalFee, 0);

        // Sell half of what the buyer holds: fee now comes out of the ETH output.
        uint256 sellAmount = whal.balanceOf(buyer) / 2;
        vm.prank(buyer);
        whal.approve(address(swapRouter), type(uint256).max);
        uint160 before = currentSqrtPrice();
        vm.recordLogs();
        BalanceDelta delta = _buyerSwap(false, -int256(sellAmount), 0);
        TaxEvent[] memory evs = taxEvents(vm.getRecordedLogs());
        assertEq(evs.length, 1);
        assertEq(Currency.unwrap(evs[0].currency), address(0), "fee in ETH");
        assertTaxEventConsistent(evs[0], before, currentSqrtPrice(), magnitude(delta.amount0()));
        assertGt(evs[0].fee, 0);
        assertEq(hook.accruedFees(ETH), evs[0].fee);

        // Exact-out buy: fee goes on top of the ETH input.
        before = currentSqrtPrice();
        vm.recordLogs();
        delta = _buyerSwap(true, int256(1_000_000 ether), 10_000 ether);
        evs = taxEvents(vm.getRecordedLogs());
        assertEq(magnitude(delta.amount1()), 1_000_000 ether, "exact WHAL out");
        assertEq(Currency.unwrap(evs[0].currency), address(0), "fee in ETH on top of the input");
        assertTaxEventConsistent(evs[0], before, currentSqrtPrice(), magnitude(delta.amount0()));
        assertClaimsMatchAccrued();

        // Anyone burns; claims land at DEAD and nowhere else.
        uint256 ethAccrued = hook.accruedFees(ETH);
        whalFee = hook.accruedFees(WHAL);
        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        assertEq(hook.burnFees(WHAL), whalFee);
        vm.prank(anyone);
        assertEq(hook.burnFees(ETH), ethAccrued);
        assertEq(manager.balanceOf(DEAD, WHAL.toId()), whalFee);
        assertEq(manager.balanceOf(DEAD, ETH.toId()), ethAccrued);
        assertEq(hook.claimsOf(WHAL), 0);
        assertEq(hook.claimsOf(ETH), 0);
        assertEq(manager.balanceOf(anyone, WHAL.toId()), 0, "caller gets nothing");
        assertEq(manager.balanceOf(anyone, ETH.toId()), 0, "caller gets nothing");
        assertEq(whal.balanceOf(address(hook)), 0, "hook never holds tokens");
        assertEq(address(hook).balance, 0, "hook never holds ETH");
        assertClaimsMatchAccrued();
    }

    // ---- The deploy script produces the same shape --------------------------------------------

    function test_deployScriptMatchesTheFactoryShape() public {
        DeployWhaleTax script = new DeployWhaleTax();
        DeployWhaleTax.Config memory cfg =
            DeployWhaleTax.Config({poolManager: IPoolManager(address(manager)), create2Deployer: address(script)});
        DeployWhaleTax.Deployment memory d = script.deploy(cfg);

        assertEq(d.token.totalSupply(), 1_000_000_000 ether);
        assertEq(d.token.balanceOf(address(script)), d.token.totalSupply(), "supply minted to the deployer");
        assertEq(address(d.hook.poolManager()), address(manager));
        assertTrue(HookFlags.matches(address(d.hook), HookFlags.WHALE_TAX));
        (address predicted, bytes32 salt) = script.mineSalt(cfg);
        assertEq(predicted, address(d.hook));
        assertEq(salt, d.hookSalt);
        assertEq(script.SEPOLIA_POOL_MANAGER(), 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
        assertEq(
            keccak256(script.hookCreationCode(IPoolManager(address(manager)))),
            keccak256(abi.encodePacked(type(WhaleTaxHook).creationCode, abi.encode(address(manager))))
        );
    }

    /// @dev The salt mined for one CREATE2 sender is not valid for another, which is why the factory
    /// must mine against its own address.
    function test_saltIsBoundToTheDeployer() public {
        DeployWhaleTax script = new DeployWhaleTax();
        (address forProxy,) = script.mineSalt(
            DeployWhaleTax.Config({
                poolManager: IPoolManager(address(manager)), create2Deployer: script.CREATE2_DEPLOYER_PROXY()
            })
        );
        (address forScript,) = script.mineSalt(
            DeployWhaleTax.Config({poolManager: IPoolManager(address(manager)), create2Deployer: address(script)})
        );
        assertTrue(HookFlags.matches(forProxy, HookFlags.WHALE_TAX));
        assertTrue(HookFlags.matches(forScript, HookFlags.WHALE_TAX));
        assertTrue(forProxy != forScript);
    }
}
