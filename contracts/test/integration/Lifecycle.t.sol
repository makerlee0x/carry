// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CarryBase} from "./CarryBase.sol";
import {LeveredLpVault} from "../../src/LeveredLpVault.sol";
import {MockMstrSellRouter} from "../../src/mocks/MockMstrSellRouter.sol";

/// @notice End-to-end multi-wallet scenarios. Each test drives a full position lifecycle through
///         the proxy and checks the books (see CarryBase) after every step, plus the money each
///         wallet ends up with. Unit tests check one function; these check that the money adds up.
contract LifecycleTest is CarryBase {
    address internal lenderA = makeAddr("lenderA");
    address internal lenderB = makeAddr("lenderB");
    address internal juniorA = makeAddr("juniorA");

    // ─── happy paths ─────────────────────────────────────────────────────────

    /// Fees cover interest: lender gets principal + yield, junior gets all MSTR + yield,
    /// vault ends holding only the backstop.
    function test_fullLifecycle_feesCoverInterest_everyoneWhole() public {
        _lend(lenderA, 10_000 ether);
        uint256 id = _stake(juniorA, 50 ether); // $5,000
        assertTrue(vault.isFullyMatched(id));
        _assertBooks("after match");

        _fees(id, 100 ether);
        vm.warp(block.timestamp + 3 days);
        vm.prank(juniorA);
        vault.claimFees(id);
        _assertBooks("after claimFees");

        _fees(id, 50 ether);
        _warpToMaturity(id);
        vm.prank(juniorA);
        vault.settle(id);
        _assertBooks("after settle");

        assertEq(mstr.balanceOf(juniorA), 50 ether, "junior must get every MSTR back");
        assertGt(usdg.balanceOf(juniorA), 0, "junior earns fee yield");

        uint256 out = _withdrawAll(lenderA);
        assertGt(out, 10_000 ether, "lender earns yield");
        _assertBooks("after lender exit");
        assertLe(usdg.balanceOf(address(vault)), vault.backstop() + DUST, "vault should hold only backstop");
    }

    /// Early exit with no fees costs nothing: junior gets all MSTR back, lender stays whole.
    function test_earlyExit_noFees_everyoneWhole() public {
        _lend(lenderA, 10_000 ether);
        uint256 id = _stake(juniorA, 50 ether);
        vm.warp(block.timestamp + 2 days);

        vm.prank(juniorA);
        LeveredLpVault.EarlyExitResult memory r = vault.earlyExit(id);
        _assertBooks("after earlyExit");

        assertEq(r.coverUsdg, 0);
        assertEq(mstr.balanceOf(juniorA), 50 ether, "junior gets all MSTR back");
        assertGe(_lenderAssets(lenderA) + 1, 10_000 ether, "lender principal intact");
    }

    /// A lender who arrives after yield was earned must not capture it.
    function test_lateLender_doesNotCaptureEarlierYield() public {
        _lend(lenderA, 5_000 ether);
        uint256 id = _stake(juniorA, 50 ether);
        _fees(id, 200 ether);
        _warpToMaturity(id);
        vm.prank(juniorA);
        vault.settle(id);

        _lend(lenderB, 5_000 ether);
        _assertBooks("after late lend");
        assertApproxEqAbs(_lenderAssets(lenderB), 5_000 ether, 1e9, "late lender gets exactly what they put in");
        assertGt(_lenderAssets(lenderA), 5_000 ether, "early lender keeps the yield");
    }

    /// Queued withdraw behind a matched position is paid when the position settles.
    function test_queuedWithdraw_paidAfterSettle() public {
        _lend(lenderA, 5_000 ether);
        uint256 id = _stake(juniorA, 50 ether); // pool fully matched, idle 0
        vm.prank(lenderA);
        vault.withdrawSenior(2_000 ether);
        assertEq(vault.claimableWithdraw(lenderA), 0, "nothing claimable while matched");
        _assertBooks("after queue");

        _fees(id, 200 ether);
        _warpToMaturity(id);
        vm.prank(juniorA);
        vault.settle(id);
        _assertBooks("after settle");

        uint256 before = usdg.balanceOf(lenderA);
        vm.prank(lenderA);
        vault.claimWithdraw();
        assertGe(usdg.balanceOf(lenderA) - before, 2_000 ether);
        _assertBooks("after claim");

        _withdrawAll(lenderA);
        _assertBooks("after full exit");
        assertLe(usdg.balanceOf(address(vault)), vault.backstop() + DUST, "vault should hold only backstop");
    }

    /// Auto-compound rollover reopens the junior from vault MSTR; books must still balance.
    function test_autoCompound_rollover_booksBalance() public {
        _lend(lenderA, 20_000 ether);
        vm.prank(juniorA);
        vault.setAutoCompound(true);
        uint256 id = _stake(juniorA, 50 ether);
        _fees(id, 300 ether);
        _warpToMaturity(id);
        vm.prank(juniorA);
        vault.settle(id);
        _assertBooks("after rollover");

        uint256 next = vault.nextPositionId() - 1;
        assertGt(next, id, "rollover opened a new position");
        (address o, uint256 amt,,,,,,, bool settled,,,,) = vault.positions(next);
        assertEq(o, juniorA);
        assertEq(amt, 50 ether, "all MSTR rolled");
        assertFalse(settled);
    }


    // ─── Oct 13 2026 product rules ──



    /// Settle with no fees: nothing is owed, lender principal is intact and the books balance.
    function test_settle_noFees_lenderWhole() public {
        _lend(lenderA, 10_000 ether);
        uint256 id = _stake(juniorA, 50 ether);
        _warpToMaturity(id);

        vm.prank(juniorA);
        LeveredLpVault.Settlement memory s = vault.settle(id);
        assertEq(s.coverUsdg + s.fromPool + s.fromBackstop, 0);
        assertGe(_lenderAssets(lenderA) + 1, 10_000 ether, "lender principal intact");
        assertEq(mstr.balanceOf(juniorA), 50 ether);
        _assertBooks("after no-fee settle");
    }

    /// Product rule: a queued withdraw pays what the shares are worth when it is paid, not a USDG
    /// amount fixed at request time. Asking to exit everything must exit everything, yield included.
    function test_queuedWithdraw_paysValueAtPayout_notRequestTime() public {
        _lend(lenderA, 5_000 ether);
        uint256 id = _stake(juniorA, 50 ether); // all lender money matched
        uint256 requested = _lenderAssets(lenderA);
        vm.prank(lenderA);
        vault.withdrawSenior(requested); // full exit, queued

        _fees(id, 300 ether); // yield lands while queued
        _warpToMaturity(id);
        vm.prank(juniorA);
        vault.settle(id);

        uint256 before = usdg.balanceOf(lenderA);
        vm.prank(lenderA);
        vault.claimWithdraw();
        uint256 paid = usdg.balanceOf(lenderA) - before;

        assertGt(paid, requested, "BUG: queued withdraw paid the request-time amount, not the value at payout");
        assertEq(vault.shares(lenderA), 0, "BUG: full-exit request left shares behind");
        _assertBooks("after floating claim");
    }

    /// Product rule: positions auto-roll at term by default. A healthy position keeps running
    /// (stays matched, keeps accruing, junior can still claim) with no transaction at term.
    function test_healthyPosition_autoRollsAtTerm() public {
        _lend(lenderA, 10_000 ether);
        uint256 id = _stake(juniorA, 50 ether);
        _fees(id, 200 ether);
        vm.warp(block.timestamp + TERM + 3 days);

        vm.prank(juniorA);
        try vault.claimFees(id) {}
        catch {
            fail("BUG: healthy position stopped at term; it should auto-roll");
        }
        assertTrue(vault.isFullyMatched(id), "rolled position stays matched");
        _assertBooks("after roll");
    }

    /// Product rule: a badly underwater position (price below entry by more than the market range,
    /// MSTR -32%) stops rolling. Inside the 48h grace only the junior may settle it.
    function test_underwater_onlyJuniorSettlesDuringGrace() public {
        uint256 id = _underwaterAtTerm();
        vm.warp(block.timestamp + GRACE - 1 hours);
        vm.prank(keeper);
        vm.expectRevert();
        vault.settle(id);
    }

    /// After the 48h grace anyone (junior, senior, Carry) can settle, and queued lenders get paid.
    function test_underwater_carryCanSettleAfterGrace() public {
        uint256 id = _underwaterAtTerm();
        vm.warp(block.timestamp + GRACE + 1);
        vm.prank(keeper);
        try vault.settle(id) {}
        catch {
            fail("BUG: underwater position past 48h grace cannot be settled by Carry; lender capital is stuck");
        }
        assertGt(vault.claimableWithdraw(lenderA), 0, "queued lender is paid once the position closes");
        _assertBooks("after Carry settle");
    }

    function test_underwater_lenderCanSettleAfterGrace() public {
        uint256 id = _underwaterAtTerm();
        vm.warp(block.timestamp + GRACE + 1);
        vm.prank(lenderA);
        try vault.settle(id) {}
        catch {
            fail("BUG: underwater position past 48h grace cannot be settled by a lender");
        }
        _assertBooks("after lender settle");
    }

    /// A healthy rolled position can't be closed by anyone but the junior, however long it runs.
    function test_healthyRolledPosition_othersCannotSettle() public {
        _lend(lenderA, 10_000 ether);
        uint256 id = _stake(juniorA, 50 ether);
        vm.warp(block.timestamp + TERM + GRACE + 1);
        vm.prank(keeper);
        vm.expectRevert(LeveredLpVault.NotJunior.selector);
        vault.settle(id);
        vm.prank(lenderA);
        vm.expectRevert(LeveredLpVault.NotJunior.selector);
        vault.settle(id);
    }

    uint256 internal constant GRACE = 48 hours;
    uint256 internal constant UNDERWATER_DROP_WAD = 0.32e18; // MSTR range; per-market in the contract

    /// Lender fully matched and queued; no fees; price falls 40% (past -32%); warp to term.
    function _underwaterAtTerm() internal returns (uint256 id) {
        _lend(lenderA, 5_000 ether);
        id = _stake(juniorA, 50 ether);
        vm.prank(lenderA);
        vault.withdrawSenior(5_000 ether);
        (,,,, uint256 entry,,,,,,,,) = vault.positions(id);
        oracle.setPrice(entry * 60 / 100);
        assertLt(entry * 60 / 100, entry * (1e18 - UNDERWATER_DROP_WAD) / 1e18);
        _warpToMaturity(id);
    }

}
