// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockMorphoVault} from "../src/mocks/MockMorphoVault.sol";

contract MockMorphoVaultTest is Test {
    MockERC20 usdg;
    MockMorphoVault vault;
    address lender = address(0xA11CE);

    function setUp() public {
        usdg = new MockERC20("USDG", "USDG", 18);
        vault = new MockMorphoVault(IERC20(address(usdg)), 0.04e18);
        usdg.mint(lender, 1000e18);
        vm.prank(lender);
        usdg.approve(address(vault), type(uint256).max);
    }

    function test_yieldAccruesToShareValue() public {
        vm.prank(lender);
        uint256 shares = vault.deposit(1000e18, lender);
        skip(365 days);
        assertApproxEqAbs(vault.convertToAssets(shares), 1040e18, 1e12);
    }

    function test_redeemPaysAccruedYieldInRealTokens() public {
        vm.startPrank(lender);
        uint256 shares = vault.deposit(1000e18, lender);
        skip(182 days);
        uint256 out = vault.redeem(shares, lender, lender);
        vm.stopPrank();
        assertGt(out, 1019e18);
        assertEq(usdg.balanceOf(lender), out);
    }

    function test_rateChangeAppliesFromNowOn() public {
        vm.prank(lender);
        vault.deposit(1000e18, lender);
        skip(365 days);
        vault.setRate(0);
        uint256 a = vault.totalAssets();
        skip(365 days);
        assertEq(vault.totalAssets(), a);
    }
}
