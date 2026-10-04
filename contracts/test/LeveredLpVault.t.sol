// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployLeveredLpVault} from "../script/DeployLeveredLpVault.s.sol";
import {DeployCarryTestnet} from "../script/DeployCarryTestnet.s.sol";
import {LeveredLpVault} from "../src/LeveredLpVault.sol";
import {FixedPriceOracle} from "../src/oracle/FixedPriceOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFeePool} from "../src/mocks/MockFeePool.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

contract LeveredLpVaultTest is Test {
    uint256 internal constant PRICE = 100 ether;
    uint256 internal constant MSTR_IN = 10 ether;

    MockERC20 internal mstr;
    MockERC20 internal usdg;
    MockOracle internal oracle;
    MockFeePool internal pool;
    LeveredLpVault internal vault;

    address internal senior = makeAddr("senior");
    address internal senior2 = makeAddr("senior2");
    address internal junior = makeAddr("junior");
    address internal donor = makeAddr("donor");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        vm.warp(1_000_000);
        mstr = new MockERC20("Mock MSTR", "MSTR", 18);
        usdg = new MockERC20("Mock USDG", "USDG", 18);
        oracle = new MockOracle(PRICE);
        vault = new LeveredLpVault(
            address(mstr),
            address(usdg),
            address(oracle),
            1 hours,
            0.05e18,
            0.2e18,
            address(this)
        );
        pool = new MockFeePool(address(usdg));
        vault.unpause();
    }

    function test_startsPaused() public {
        LeveredLpVault fresh = new LeveredLpVault(
            address(mstr), address(usdg), address(oracle), 7 days, 0.05e18, 0.2e18, address(this)
        );
        assertTrue(fresh.paused());
        usdg.mint(senior, 1 ether);
        vm.startPrank(senior);
        usdg.approve(address(fresh), 1 ether);
        vm.expectRevert(LeveredLpVault.Paused.selector);
        fresh.depositSenior(1 ether);
        vm.stopPrank();
    }

    function test_depositBothSides() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        _depositSenior(senior, seniorNeed);
        uint256 id = _depositJunior(junior, MSTR_IN);

        assertEq(mstr.balanceOf(address(vault)), MSTR_IN);
        assertEq(usdg.balanceOf(address(vault)), seniorNeed);
        assertEq(vault.reservedSenior(), seniorNeed);
        assertEq(vault.freeSenior(), 0);
        assertTrue(vault.isMatched(id));

        (address owner, uint256 mstrAmount, uint256 seniorPrincipal,,,, bool settled) = vault.positions(id);
        assertEq(owner, junior);
        assertEq(mstrAmount, MSTR_IN);
        assertEq(seniorPrincipal, seniorNeed);
        assertFalse(settled);
    }

    function test_openThenMatchOnSeniorDeposit() public {
        uint256 id = _depositJunior(junior, MSTR_IN);
        assertFalse(vault.isMatched(id));
        (,,, , , uint64 openedAt, bool settled) = vault.positions(id);
        assertEq(openedAt, 0);
        assertFalse(settled);
        assertEq(vault.openHead(), id);

        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        _depositSenior(senior, seniorNeed);

        assertTrue(vault.isMatched(id));
        (,, uint256 seniorPrincipal,,, uint64 matchedAt,) = vault.positions(id);
        assertEq(seniorPrincipal, seniorNeed);
        assertEq(matchedAt, block.timestamp);
        assertEq(vault.openHead(), 0);
        assertEq(vault.reservedSenior(), seniorNeed);
    }

    function test_withdrawUnmatchedReturnsShares() public {
        uint256 id = _depositJunior(junior, MSTR_IN);
        vm.prank(junior);
        vault.withdrawUnmatched(id);
        assertEq(mstr.balanceOf(junior), MSTR_IN);
        (,,,,,, bool settled) = vault.positions(id);
        assertTrue(settled);
        assertEq(vault.openHead(), 0);
    }

    function test_accrueFees() public {
        uint256 id = _openMatched();
        uint256 gross = 1_000 ether;
        _payFee(id, gross);

        assertEq(vault.backstop(), 200 ether);
        (,,,, uint256 feeUsdg,,) = vault.positions(id);
        assertEq(feeUsdg, 800 ether);
        assertEq(usdg.balanceOf(address(vault)), vault.previewSeniorAssets(MSTR_IN) + gross);
    }

    function test_accrueFeesRequiresMatched() public {
        uint256 id = _depositJunior(junior, MSTR_IN);
        usdg.mint(donor, 1 ether);
        vm.startPrank(donor);
        usdg.approve(address(vault), 1 ether);
        vm.expectRevert(LeveredLpVault.NotMatched.selector);
        vault.accrueLpFee(id, 1 ether);
        vm.stopPrank();
    }

    function test_aboveWaterWithdraw() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 id = _openMatched();
        uint256 borrowFee = vault.previewBorrowFee(seniorNeed);

        vm.expectRevert(LeveredLpVault.TermNotElapsed.selector);
        vault.settle(id);

        uint256 gross = 1_000 ether;
        _payFee(id, gross);
        vm.warp(block.timestamp + 1 hours);

        vm.prank(junior);
        LeveredLpVault.Settlement memory settlement = vault.settle(id);

        uint256 netFees = gross * 8 / 10;
        assertEq(settlement.mstrSold, 0);
        assertEq(settlement.fromBackstop, 0);
        assertEq(settlement.juniorYield, netFees - borrowFee);
        assertEq(mstr.balanceOf(junior), MSTR_IN);
        assertEq(usdg.balanceOf(junior), netFees - borrowFee);
        assertEq(vault.backstop(), gross - netFees);

        vm.prank(senior);
        vault.withdrawSenior(seniorNeed);
        assertApproxEqAbs(usdg.balanceOf(senior), seniorNeed + borrowFee, 1_000);
        assertEq(mstr.balanceOf(senior), 0);
    }

    function test_belowWaterBackstopCoversGap() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 id = _openMatched();
        uint256 borrowFee = vault.previewBorrowFee(seniorNeed);
        _fundBackstop(donor, borrowFee);

        vm.warp(block.timestamp + 1 hours);
        LeveredLpVault.Settlement memory settlement = vault.settle(id);

        assertEq(settlement.mstrSold, 0);
        assertEq(settlement.fromBackstop, borrowFee);
        assertEq(settlement.juniorYield, 0);
        assertEq(vault.backstop(), 0);
        assertEq(mstr.balanceOf(junior), MSTR_IN);

        vm.prank(senior);
        vault.withdrawSenior(seniorNeed);
        assertApproxEqAbs(usdg.balanceOf(senior), seniorNeed + borrowFee, 1_000);
        assertEq(mstr.balanceOf(senior), 0);
    }

    function test_belowWaterSellsMinimumJunior() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 id = _openMatched();
        uint256 borrowFee = vault.previewBorrowFee(seniorNeed);
        uint256 backstopPart = borrowFee / 2;
        _fundBackstop(donor, backstopPart);

        vm.warp(block.timestamp + 1 hours);
        uint256 gap = borrowFee - backstopPart;
        uint256 expectedSold = vault.previewMstrToCover(gap);

        LeveredLpVault.Settlement memory settlement = vault.settle(id);

        assertEq(settlement.fromBackstop, backstopPart);
        assertEq(settlement.mstrSold, expectedSold);
        assertGt(settlement.mstrSold, 0);
        assertLt(settlement.mstrSold, MSTR_IN);
        assertGe(settlement.mstrSold * PRICE / 1e18, gap);
        assertLt((settlement.mstrSold - 1) * PRICE / 1e18, gap);
        assertEq(mstr.balanceOf(junior), MSTR_IN - settlement.mstrSold);
        assertEq(settlement.feeShortfallUsdg, 0);

        vm.prank(senior);
        vault.withdrawSenior(seniorNeed);
        assertApproxEqAbs(mstr.balanceOf(senior), settlement.mstrSold, 1_000);
        assertApproxEqAbs(usdg.balanceOf(senior), seniorNeed + backstopPart, 1_000);
    }

    function test_earlyExitFreeWhenFeesCoverCoupon() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 id = _openMatched();

        vm.warp(block.timestamp + 30 minutes);
        uint256 coupon = vault.previewEarlyExitCoupon(seniorNeed, 30 minutes);
        // Gross so that after 20% cut, net fees >= coupon
        uint256 gross = coupon * 10 / 8 + 1 ether;
        _payFee(id, gross);

        LeveredLpVault.EarlyExitResult memory result = vault.previewEarlyExit(id);
        assertEq(result.usdgGap, 0);
        assertEq(result.mstrSold, 0);
        assertGt(result.juniorLeftoverFees, 0);

        vm.prank(junior);
        result = vault.earlyExit(id);

        assertEq(result.mstrReturned, MSTR_IN);
        assertEq(mstr.balanceOf(junior), MSTR_IN);
        assertEq(usdg.balanceOf(junior), result.juniorLeftoverFees);
        assertEq(vault.reservedSenior(), 0);

        vm.prank(senior);
        vault.withdrawSenior(seniorNeed);
        assertApproxEqAbs(usdg.balanceOf(senior), seniorNeed + result.couponOwed, 1_000);
    }

    function test_earlyExitPaysGapFromPositionShares() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 id = _openMatched();

        vm.warp(block.timestamp + 30 minutes);
        // No fees — gap covered by selling MSTR from the position
        LeveredLpVault.EarlyExitResult memory preview = vault.previewEarlyExit(id);
        assertGt(preview.couponOwed, 0);
        assertEq(preview.fromPositionFees, 0);
        assertEq(preview.usdgGap, preview.couponOwed);
        assertGt(preview.mstrSold, 0);

        vm.prank(junior);
        LeveredLpVault.EarlyExitResult memory result = vault.earlyExit(id);

        assertEq(result.mstrSold, preview.mstrSold);
        assertEq(mstr.balanceOf(junior), MSTR_IN - result.mstrSold);
        assertEq(usdg.balanceOf(junior), 0); // no spare wallet pull
        assertLt(mstr.balanceOf(junior), MSTR_IN);

        vm.prank(senior);
        vault.withdrawSenior(seniorNeed);
        assertApproxEqAbs(mstr.balanceOf(senior), result.mstrSold, 1_000);
        assertApproxEqAbs(usdg.balanceOf(senior), seniorNeed, 1_000);
    }

    function test_earlyExitCannotDoubleExit() public {
        uint256 id = _openMatched();
        vm.prank(junior);
        vault.earlyExit(id);
        vm.prank(junior);
        vm.expectRevert(LeveredLpVault.AlreadySettled.selector);
        vault.earlyExit(id);
        vm.expectRevert(LeveredLpVault.AlreadySettled.selector);
        vault.settle(id);
    }

    function test_earlyExitOnlyJunior() public {
        uint256 id = _openMatched();
        vm.prank(attacker);
        vm.expectRevert(LeveredLpVault.NotJunior.selector);
        vault.earlyExit(id);
    }

    function test_earlyExitBlockedAfterTerm() public {
        uint256 id = _openMatched();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(junior);
        vm.expectRevert(LeveredLpVault.TermElapsed.selector);
        vault.earlyExit(id);
        // No fees: maturity settle may sell minimum MSTR for the borrow fee.
        LeveredLpVault.Settlement memory settlement = vault.settle(id);
        assertEq(mstr.balanceOf(junior), settlement.mstrKept);
        assertEq(settlement.mstrKept + settlement.mstrSold, MSTR_IN);
    }

    function test_lenderReplaceUnlocksExit() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        _depositSenior(senior, seniorNeed);
        _depositJunior(junior, MSTR_IN);
        assertEq(vault.freePrincipal(senior), 0);

        vm.prank(senior);
        vm.expectRevert(LeveredLpVault.InsufficientFree.selector);
        vault.withdrawSenior(1);

        // Replacement lender posts idle USDG → original senior can exit pro-rata free share
        _depositSenior(senior2, seniorNeed);
        uint256 free = vault.freePrincipal(senior);
        assertGt(free, 0);

        vm.prank(senior);
        vault.withdrawSenior(free);
        assertEq(vault.seniorPrincipal(senior), seniorNeed - free);
    }

    function test_pauseBlocksNewDeposits() public {
        uint256 id = _openMatched();
        address blocked = makeAddr("blocked");

        vault.pause();
        assertTrue(vault.paused());

        usdg.mint(blocked, 1 ether);
        vm.startPrank(blocked);
        usdg.approve(address(vault), 1 ether);
        vm.expectRevert(LeveredLpVault.Paused.selector);
        vault.depositSenior(1 ether);
        vm.stopPrank();

        mstr.mint(blocked, 1 ether);
        vm.startPrank(blocked);
        mstr.approve(address(vault), 1 ether);
        vm.expectRevert(LeveredLpVault.Paused.selector);
        vault.depositJunior(1 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);
        vault.settle(id);
        assertEq(mstr.balanceOf(junior) + mstr.balanceOf(address(vault)), MSTR_IN);
        assertEq(usdg.balanceOf(blocked), 1 ether);
        assertEq(mstr.balanceOf(blocked), 1 ether);
    }

    function test_randomAddressCannotPullFunds() public {
        uint256 id = _openMatched();
        uint256 vaultMstr = mstr.balanceOf(address(vault));
        uint256 vaultUsdg = usdg.balanceOf(address(vault));

        vm.startPrank(attacker);
        vm.expectRevert(LeveredLpVault.InsufficientFree.selector);
        vault.withdrawSenior(1 ether);
        vm.expectRevert(LeveredLpVault.ExternalLpForbidden.selector);
        vault.joinPool("");
        vm.expectRevert(LeveredLpVault.NotOwner.selector);
        vault.rescueToken(address(usdg), attacker, 1);
        vm.expectRevert(LeveredLpVault.NotJunior.selector);
        vault.earlyExit(id);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);
        vm.prank(attacker);
        vault.settle(id);

        assertEq(mstr.balanceOf(attacker), 0);
        assertEq(usdg.balanceOf(attacker), 0);
        assertEq(mstr.balanceOf(address(vault)) + mstr.balanceOf(junior), vaultMstr);
        assertEq(usdg.balanceOf(address(vault)), vaultUsdg);
    }

    function test_ownerCannotStealPrincipal() public {
        _openMatched();
        uint256 vaultMstr = mstr.balanceOf(address(vault));
        uint256 vaultUsdg = usdg.balanceOf(address(vault));

        vm.expectRevert(LeveredLpVault.PrincipalToken.selector);
        vault.rescueToken(address(mstr), address(this), 1);
        vm.expectRevert(LeveredLpVault.PrincipalToken.selector);
        vault.rescueToken(address(usdg), address(this), 1);

        MockERC20 junk = new MockERC20("Junk", "JUNK", 18);
        junk.mint(address(vault), 5 ether);
        vault.rescueToken(address(junk), address(this), 5 ether);

        assertEq(junk.balanceOf(address(this)), 5 ether);
        assertEq(mstr.balanceOf(address(vault)), vaultMstr);
        assertEq(usdg.balanceOf(address(vault)), vaultUsdg);
        assertEq(mstr.balanceOf(address(this)), 0);
        assertEq(usdg.balanceOf(address(this)), 0);
    }

    function test_twoXTracksHoldCloserThanUnlevered() public {
        uint256 id = _openMatched();
        oracle.setPrice(PRICE * 4);

        (uint256 hold, uint256 levered, uint256 unlevered) = vault.mark(id);
        assertEq(levered, hold);
        assertGt(hold, unlevered);
        assertLt(_dist(levered, hold), _dist(unlevered, hold));
        assertEq(hold, 4_000 ether);
        assertEq(unlevered, 3_000 ether);
    }

    function test_externalCannotLpBesideVault() public {
        assertEq(vault.dualPoolAdapter(), address(0));
        assertEq(mstr.allowance(address(vault), vault.ROBINHOOD_POOL_MANAGER()), 0);
        assertEq(usdg.allowance(address(vault), vault.ROBINHOOD_POOL_MANAGER()), 0);
        vm.expectRevert(LeveredLpVault.ExternalLpForbidden.selector);
        vault.joinPool("");
    }

    function test_broadcastDisarmed() public {
        DeployLeveredLpVault deploy = new DeployLeveredLpVault();
        assertFalse(deploy.broadcastArmed());
        assertEq(deploy.MSTR(), 0xec262a75e413fAfD0dF80480274532C79D42da09);
        assertEq(deploy.USDG(), 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
        assertEq(deploy.TERM(), 7 days);
        vm.expectRevert(DeployLeveredLpVault.BroadcastBlocked.selector);
        deploy.run();
    }

    function test_carryTestnetScriptDisarmed() public {
        DeployCarryTestnet deploy = new DeployCarryTestnet();
        assertFalse(deploy.broadcastArmed());
        assertEq(deploy.RH_TESTNET_CHAIN_ID(), 46630);
        assertEq(deploy.TERM(), 7 days);
        // Anvil / default forge chain 31337: dry-run path deploys in-process without broadcast.
        deploy.run();
    }

    function test_fixedOracleHasNoWriter() public {
        FixedPriceOracle fixedOracle = new FixedPriceOracle(PRICE);
        assertEq(fixedOracle.mstrPriceWad(), PRICE);
    }

    function test_earlyExitCouponFormula() public {
        uint256 principal = 1_000 ether;
        uint256 elapsed = 7 days;
        uint256 owed = vault.previewEarlyExitCoupon(principal, elapsed);
        // principal * 0.04 * 7 / 365
        uint256 expected = principal * 4 / 100 * 7 / 365;
        assertEq(owed, expected);
    }

    function test_depositCapsEnforceTotalAndPerWallet() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        vault.setDepositCaps(seniorNeed, seniorNeed, seniorNeed);

        _depositSenior(senior, seniorNeed);
        vm.expectRevert(LeveredLpVault.CapExceeded.selector);
        _depositSenior(senior2, 1 ether);

        uint256 id = _depositJunior(junior, MSTR_IN);
        assertTrue(vault.isMatched(id));

        vm.expectRevert(LeveredLpVault.CapExceeded.selector);
        _depositJunior(attacker, MSTR_IN);
    }

    function test_depositCapsReleaseOnUnmatchedWithdraw() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        vault.setDepositCaps(0, seniorNeed, 0);
        uint256 id = _depositJunior(junior, MSTR_IN);
        assertEq(vault.totalJuniorUsdg(), seniorNeed);
        vm.prank(junior);
        vault.withdrawUnmatched(id);
        assertEq(vault.totalJuniorUsdg(), 0);
        assertEq(vault.walletJuniorUsdg(junior), 0);
        // Cap frees up for a new deposit.
        _depositJunior(junior, MSTR_IN);
        assertEq(vault.totalJuniorUsdg(), seniorNeed);
    }

    function test_setDepositCapsOnlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(LeveredLpVault.NotOwner.selector);
        vault.setDepositCaps(1, 1, 1);
    }

    function _openMatched() internal returns (uint256 id) {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        _depositSenior(senior, seniorNeed);
        id = _depositJunior(junior, MSTR_IN);
        assertTrue(vault.isMatched(id));
    }

    function _depositSenior(address account, uint256 amount) internal {
        usdg.mint(account, amount);
        vm.startPrank(account);
        usdg.approve(address(vault), amount);
        vault.depositSenior(amount);
        vm.stopPrank();
    }

    function _depositJunior(address account, uint256 amount) internal returns (uint256 id) {
        mstr.mint(account, amount);
        vm.startPrank(account);
        mstr.approve(address(vault), amount);
        id = vault.depositJunior(amount);
        vm.stopPrank();
    }

    function _payFee(uint256 id, uint256 amount) internal {
        usdg.mint(donor, amount);
        vm.startPrank(donor);
        usdg.approve(address(pool), amount);
        pool.payFee(address(vault), id, amount);
        vm.stopPrank();
    }

    function _fundBackstop(address account, uint256 amount) internal {
        usdg.mint(account, amount);
        vm.startPrank(account);
        usdg.approve(address(vault), amount);
        vault.fundBackstop(amount);
        vm.stopPrank();
    }

    function _dist(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
