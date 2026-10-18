// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {LeveredLpVault} from "../src/LeveredLpVault.sol";
import {LeveredLpVaultV2} from "../src/LeveredLpVaultV2.sol";
import {ICarryStrategy} from "../src/interfaces/ICarryStrategy.sol";
import {CarryStrategy} from "../src/CarryStrategy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockMorphoVault} from "../src/mocks/MockMorphoVault.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

/// @notice Idle senior USDG parked in Morpho through CarryStrategy: accounting, yield and recall.
contract VaultStrategyTest is Test {
    MockERC20 mstr;
    MockERC20 usdg;
    MockMorphoVault morpho;
    LeveredLpVault vault;
    CarryStrategy strat;
    address lender = makeAddr("lender");
    address lender2 = makeAddr("lender2");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_000_000);
        mstr = new MockERC20("Mock MSTR", "MSTR", 18);
        usdg = new MockERC20("Mock USDG", "USDG", 18);
        MockOracle oracle = new MockOracle(100 ether);
        LeveredLpVaultV2 impl = new LeveredLpVaultV2();
        bytes memory init = abi.encodeCall(
            LeveredLpVault.initialize, (address(mstr), address(usdg), address(oracle), uint64(1 hours), 0.039e18, address(this))
        );
        vault = LeveredLpVault(address(new ERC1967Proxy(address(impl), init)));
        vault.unpause();
        vault.setDepositCaps(0, 25_000 ether, 0);

        morpho = new MockMorphoVault(IERC20(address(usdg)), 0.05e18);
        strat = new CarryStrategy(address(vault), IERC4626(address(morpho)));
        vault.setStrategy(ICarryStrategy(address(strat)));
    }

    function _deposit(address who, uint256 amount) internal {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(vault), amount);
        vault.depositSenior(amount);
        vm.stopPrank();
    }

    function test_onlyOwnerCanSetOrDeploy() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        vault.setStrategy(ICarryStrategy(address(strat)));
        vm.expectRevert();
        vault.deployIdle(1 ether);
        vm.stopPrank();
    }

    function test_deployIdleParksUsdgWithoutChangingNav() public {
        _deposit(lender, 1_000 ether);
        uint256 navBefore = vault.totalSeniorAssets();
        vault.deployIdle(600 ether);
        assertEq(usdg.balanceOf(address(vault)), 400 ether);
        assertEq(strat.idleAssets(), 600 ether);
        assertEq(vault.strategyDeployed(), 600 ether);
        assertEq(vault.totalSeniorAssets(), navBefore);
    }

    function test_cannotDeployMoreThanIdle() public {
        _deposit(lender, 100 ether);
        vm.expectRevert(LeveredLpVault.InsufficientFree.selector);
        vault.deployIdle(101 ether);
        vm.expectRevert(LeveredLpVault.ZeroAmount.selector);
        vault.deployIdle(0);
    }

    function test_harvestBooksMorphoYieldIntoSharePrice() public {
        _deposit(lender, 1_000 ether);
        vault.deployIdle(1_000 ether);
        uint256 priceBefore = vault.convertToAssets(1e18);
        skip(365 days);
        vm.prank(stranger);
        vault.harvest();
        assertApproxEqAbs(vault.totalSeniorAssets(), 1_050 ether, 1e12);
        assertEq(vault.strategyDeployed(), strat.idleAssets());
        assertGt(vault.convertToAssets(1e18), priceBefore);
    }

    function test_instantWithdrawRecallsFromMorpho() public {
        _deposit(lender, 1_000 ether);
        vault.deployIdle(1_000 ether);
        skip(365 days);
        vm.prank(lender);
        vault.withdrawSenior(900 ether);
        assertEq(usdg.balanceOf(lender), 900 ether);
        assertEq(usdg.balanceOf(address(vault)), 0);
        // the withdraw booked the year's yield first, so the rest of the lender's value is 1,050 - 900
        assertApproxEqAbs(vault.convertToAssets(vault.shares(lender)), 150 ether, 1e13);
        assertGt(strat.idleAssets(), 0);
    }

    function test_lenderExitsWithPrincipalAndYield() public {
        _deposit(lender, 1_000 ether);
        vault.deployIdle(1_000 ether);
        skip(365 days);
        uint256 all = vault.convertToAssets(vault.shares(lender));
        vm.prank(stranger);
        vault.harvest();
        all = vault.convertToAssets(vault.shares(lender));
        vm.prank(lender);
        vault.withdrawSenior(all - 1e6);
        assertApproxEqAbs(usdg.balanceOf(lender), 1_050 ether, 1e13);
    }

    function test_newDepositorCannotCaptureYieldBooked() public {
        _deposit(lender, 1_000 ether);
        vault.deployIdle(1_000 ether);
        skip(365 days);
        _deposit(lender2, 1_000 ether); // harvest runs inside the deposit, before shares are priced
        uint256 v1 = vault.convertToAssets(vault.shares(lender));
        uint256 v2 = vault.convertToAssets(vault.shares(lender2));
        assertApproxEqAbs(v1, 1_050 ether, 1e13);
        assertApproxEqAbs(v2, 1_000 ether, 1e13);
    }

    function test_cannotSwapStrategyWhileFundsDeployed() public {
        _deposit(lender, 100 ether);
        vault.deployIdle(50 ether);
        vm.expectRevert(LeveredLpVault.InsufficientFree.selector);
        vault.setStrategy(ICarryStrategy(address(0)));
    }

    function test_vaultWithoutStrategyBehavesAsBefore() public {
        vault.setStrategy(ICarryStrategy(address(0)));
        _deposit(lender, 100 ether);
        vm.prank(lender);
        vault.withdrawSenior(100 ether);
        assertEq(usdg.balanceOf(lender), 100 ether);
    }
}
