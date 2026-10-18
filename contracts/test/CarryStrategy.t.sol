// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockMorphoVault} from "../src/mocks/MockMorphoVault.sol";
import {CarryStrategy} from "../src/CarryStrategy.sol";

contract CarryStrategyTest is Test {
    MockERC20 usdg;
    MockMorphoVault morpho;
    CarryStrategy strat;
    address carryVault = address(0xCA11);
    address stranger = address(0xBAD);

    function setUp() public {
        usdg = new MockERC20("USDG", "USDG", 18);
        morpho = new MockMorphoVault(IERC20(address(usdg)), 0.04e18);
        strat = new CarryStrategy(carryVault, IERC4626(address(morpho)));
        usdg.mint(carryVault, 1000e18);
        vm.prank(carryVault);
        usdg.approve(address(strat), type(uint256).max);
    }

    function test_depositMovesUsdgIntoMorpho() public {
        vm.prank(carryVault);
        strat.deposit(400e18);
        assertEq(usdg.balanceOf(carryVault), 600e18);
        assertEq(usdg.balanceOf(address(strat)), 0);
        assertEq(strat.idleAssets(), 400e18);
    }

    function test_idleUsdgEarnsTheFloatingRate() public {
        vm.prank(carryVault);
        strat.deposit(1000e18);
        skip(365 days);
        assertApproxEqAbs(strat.idleAssets(), 1040e18, 1e12);
        morpho.setRate(0.01e18);
        skip(365 days);
        assertApproxEqAbs(strat.idleAssets(), 1040e18 * 101 / 100, 1e13);
    }

    function test_withdrawReturnsExactAssetsToTarget() public {
        vm.startPrank(carryVault);
        strat.deposit(1000e18);
        skip(30 days);
        strat.withdraw(250e18, carryVault);
        vm.stopPrank();
        assertEq(usdg.balanceOf(carryVault), 250e18);
        assertGt(strat.idleAssets(), 750e18);
    }

    function test_withdrawAllPaysPrincipalAndYield() public {
        vm.startPrank(carryVault);
        strat.deposit(1000e18);
        skip(182 days);
        uint256 out = strat.withdrawAll(carryVault);
        vm.stopPrank();
        assertGt(out, 1019e18);
        assertEq(usdg.balanceOf(carryVault), out);
        assertEq(strat.idleAssets(), 0);
        assertEq(morpho.balanceOf(address(strat)), 0);
    }

    function test_onlyVaultCanMoveFunds() public {
        vm.startPrank(stranger);
        vm.expectRevert(CarryStrategy.NotVault.selector);
        strat.deposit(1e18);
        vm.expectRevert(CarryStrategy.NotVault.selector);
        strat.withdraw(1e18, stranger);
        vm.expectRevert(CarryStrategy.NotVault.selector);
        strat.withdrawAll(stranger);
        vm.stopPrank();
    }

    function test_zeroAmountsRevert() public {
        vm.startPrank(carryVault);
        vm.expectRevert(CarryStrategy.ZeroAmount.selector);
        strat.deposit(0);
        vm.expectRevert(CarryStrategy.ZeroAmount.selector);
        strat.withdraw(0, carryVault);
        vm.expectRevert(CarryStrategy.ZeroAmount.selector);
        strat.withdrawAll(carryVault);
        vm.stopPrank();
    }

    function test_strategyKeepsNoLooseBalance() public {
        vm.startPrank(carryVault);
        strat.deposit(333e18);
        strat.withdraw(111e18, carryVault);
        vm.stopPrank();
        assertEq(usdg.balanceOf(address(strat)), 0);
    }
}
