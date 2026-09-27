// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {WhaleToken} from "../src/WhaleToken.sol";

contract WhaleTokenTest is Test {
    WhaleToken token;
    address deployer;
    uint256 constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        deployer = address(this);
        token = new WhaleToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Whale Tax");
        assertEq(token.symbol(), "WHAL");
        assertEq(token.decimals(), 18);
    }

    function test_mintsWholeSupplyToDeployerOnce() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_supplyGoesToWhoeverDeploys() public {
        address factory = makeAddr("factory");
        vm.prank(factory);
        WhaleToken other = new WhaleToken();
        assertEq(other.balanceOf(factory), SUPPLY);
        assertEq(other.balanceOf(address(this)), 0);
    }

    function test_transferMovesExactlyWhatItWasAsked() public {
        address to = makeAddr("recipient");
        assertTrue(token.transfer(to, 1_234 ether));
        assertEq(token.balanceOf(to), 1_234 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 1_234 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferMoreThanBalanceReverts() public {
        address poor = makeAddr("poor");
        vm.prank(poor);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 0, 1));
        token.transfer(deployer, 1);
    }

    function test_approveAndTransferFrom() public {
        address spender = makeAddr("spender");
        address to = makeAddr("to");
        token.approve(spender, 10 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, to, 10 ether));
        assertEq(token.balanceOf(to), 10 ether);
        assertEq(token.allowance(deployer, spender), 0);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(deployer, to, 1);
    }

    /// @dev No mint, owner or admin surface: the common selectors all fail and the supply never moves.
    function test_noAdminSurface() public {
        string[8] memory sigs = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], deployer, uint256(1)));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
