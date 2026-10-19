// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LeveredLpVault} from "../src/LeveredLpVault.sol";
import {LeveredLpVaultV2} from "../src/LeveredLpVaultV2.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

/// @notice Real USDG has 6 decimals (the testnet mocks have 18). The vault must size USDG amounts from the
///         token's decimals, starting with the $25 minimum deposit.
contract SixDecimalUsdgTest is Test {
    MockERC20 mstr;
    MockERC20 usdg;
    MockOracle oracle;
    LeveredLpVault vault;

    address lender = makeAddr("lender");
    address junior = makeAddr("junior");

    function setUp() public {
        vm.warp(1_000_000);
        mstr = new MockERC20("Mock MSTR", "MSTR", 18);
        usdg = new MockERC20("Mock USDG", "USDG", 6);
        oracle = new MockOracle(100 ether); // $100, WAD regardless of token decimals
        LeveredLpVaultV2 impl = new LeveredLpVaultV2();
        bytes memory init = abi.encodeCall(
            LeveredLpVault.initialize, (address(mstr), address(usdg), address(oracle), uint64(7 days), 0, address(this))
        );
        vault = LeveredLpVault(address(new ERC1967Proxy(address(impl), init)));
        vault.unpause();
    }

    function _lend(uint256 amount) internal {
        usdg.mint(lender, amount);
        vm.startPrank(lender);
        usdg.approve(address(vault), amount);
        vault.depositSenior(amount);
        vm.stopPrank();
    }

    function _junior(uint256 amount) internal returns (uint256 id) {
        mstr.mint(junior, amount);
        vm.startPrank(junior);
        mstr.approve(address(vault), amount);
        id = vault.depositJunior(amount);
        vm.stopPrank();
    }

    function test_minDepositIs25UsdgInTokenUnits() public {
        assertEq(vault.minDepositUsdg(), 25e6, "$25 in 6-decimal units");
        usdg.mint(lender, 24e6);
        vm.startPrank(lender);
        usdg.approve(address(vault), 24e6);
        vm.expectRevert(LeveredLpVault.BelowMinDeposit.selector);
        vault.depositSenior(24e6);
        vm.stopPrank();
        _lend(25e6);
        assertEq(vault.totalSeniorAssets(), 25e6);
    }

    function test_clearingMinDepositFallsBackTo25Usdg() public {
        vault.setMinDepositUsdg(0);
        _lend(25e6); // still $25, not 25e18 units
    }

    /// 10 MSTR at $100 is matched against $1,000 = 1,000e6 USDG units.
    function test_matchUsesTokenDecimals() public {
        _lend(1_000e6);
        uint256 id = _junior(10e18);
        assertTrue(vault.isFullyMatched(id));
        assertEq(vault.reservedSenior(), 1_000e6);
        assertEq(vault.previewSeniorAssets(10e18), 1_000e6);
    }

    /// Fees in 6-decimal USDG split 20 / 40 / 40 and everyone is whole.
    function test_feeSplitAndSettle() public {
        _lend(1_000e6);
        uint256 id = _junior(10e18);
        usdg.mint(address(this), 10e6);
        usdg.approve(address(vault), 10e6);
        vault.accrueLpFee(id, 10e6);
        uint256 backstopBefore = vault.backstop();

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(junior);
        vault.settle(id);

        assertEq(vault.backstop() - backstopBefore, 2e6, "treasury 20%");
        assertEq(vault.totalSeniorAssets(), 1_004e6, "senior 40%");
        assertEq(usdg.balanceOf(junior), 4e6, "junior 40%");
        assertEq(mstr.balanceOf(junior), 10e18, "junior stock back");
    }

    function test_lenderWithdrawRoundTrip() public {
        _lend(1_000e6);
        vm.prank(lender);
        vault.withdrawSenior(400e6);
        assertEq(usdg.balanceOf(lender), 400e6);
        assertEq(vault.totalSeniorAssets(), 600e6);
    }
}
