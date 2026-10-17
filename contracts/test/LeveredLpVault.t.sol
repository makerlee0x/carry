// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LeveredLpVault} from "../src/LeveredLpVault.sol";
import {LeveredLpVaultV2} from "../src/LeveredLpVaultV2.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {MockMstrSellRouter} from "../src/mocks/MockMstrSellRouter.sol";
import {PushablePriceOracle} from "../src/oracle/PushablePriceOracle.sol";
import {CarryMath} from "../src/libraries/CarryMath.sol";
import {CarryPool} from "../src/libraries/CarryPool.sol";

contract LeveredLpVaultTest is Test {
    uint256 internal constant PRICE = 100 ether;
    uint256 internal constant MSTR_IN = 10 ether; // $1k at $100
    uint256 internal constant MORPHO = 0.039e18;

    MockERC20 internal mstr;
    MockERC20 internal usdg;
    MockOracle internal oracle;
    LeveredLpVault internal vault;

    address internal senior = makeAddr("senior");
    address internal senior2 = makeAddr("senior2");
    address internal junior = makeAddr("junior");
    address internal donor = makeAddr("donor");

    function setUp() public {
        vm.warp(1_000_000);
        mstr = new MockERC20("Mock MSTR", "MSTR", 18);
        usdg = new MockERC20("Mock USDG", "USDG", 18);
        oracle = new MockOracle(PRICE);
        vault = _deployVault(1 hours, MORPHO, address(this));
        vault.unpause();
        vault.setDepositCaps(0, 25_000 ether, 0); // uncapped senior
    }

    function _deployVault(uint64 term_, uint256 morphoRate, address owner_) internal returns (LeveredLpVault v) {
        LeveredLpVaultV2 implementation = new LeveredLpVaultV2();
        bytes memory initData = abi.encodeCall(
            LeveredLpVault.initialize,
            (address(mstr), address(usdg), address(oracle), term_, morphoRate, owner_)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        v = LeveredLpVault(address(proxy));
    }

    function _depositSenior(address who, uint256 amount) internal {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(vault), amount);
        vault.depositSenior(amount);
        vm.stopPrank();
    }

    function _depositJunior(address who, uint256 mstrAmount) internal returns (uint256 id) {
        mstr.mint(who, mstrAmount);
        vm.startPrank(who);
        mstr.approve(address(vault), mstrAmount);
        id = vault.depositJunior(mstrAmount);
        vm.stopPrank();
    }

    // ─── pool shares ─────────────────────────────────────────────────────────

    function test_version_is_v3() public view {
        assertEq(vault.version(), "v3-lender-pool");
    }

    function test_startsPaused() public {
        LeveredLpVault fresh = _deployVault(7 days, MORPHO, address(this));
        assertTrue(fresh.paused());
    }

    function test_poolShares_mintAndRoundPoolFavor() public {
        uint256 a = 100 ether;
        _depositSenior(senior, a);
        uint256 sh = vault.shares(senior);
        assertGt(sh, 0);
        // Round in pool favor: convertToAssets(shares) <= deposited
        uint256 assets = vault.convertToAssets(sh);
        assertLe(assets, a);
        assertEq(vault.totalSeniorAssets(), a);
        assertEq(vault.freeSenior(), a);
    }

    function test_poolShares_virtualOffset_firstDepositor() public {
        _depositSenior(senior, 25 ether);
        uint256 sh1 = vault.shares(senior);
        // Second depositor gets proportional shares
        _depositSenior(senior2, 25 ether);
        uint256 sh2 = vault.shares(senior2);
        // Nearly equal; virtual offset prevents inflation attack monopoly
        assertApproxEqRel(sh1, sh2, 0.01e18);
    }

    function test_instantWithdraw_whenIdleAndQueueEmpty() public {
        _depositSenior(senior, 100 ether);
        uint256 before = usdg.balanceOf(senior);
        vm.prank(senior);
        vault.withdrawSenior(40 ether);
        assertEq(usdg.balanceOf(senior) - before, 40 ether);
        assertEq(vault.wqCumulativeRequested(), 0);
    }

    function test_withdrawQueue_fifoLazyClaim() public {
        // Senior deposits 100; junior matches 100 → idle 0
        _depositSenior(senior, 100 ether);
        uint256 id = _depositJunior(junior, 1 ether); // $100
        assertTrue(vault.isFullyMatched(id));
        assertEq(vault.freeSenior(), 0);

        // Senior queues withdraw 50 (cannot instant)
        vm.prank(senior);
        vault.withdrawSenior(50 ether);
        assertEq(vault.wqCumulativeRequested(), 50 ether);
        assertEq(vault.claimableWithdraw(senior), 0);

        // New deposit fills queue before matching new juniors
        _depositSenior(senior2, 50 ether);
        assertEq(vault.wqCumulativeFulfilled(), 50 ether);
        assertEq(vault.claimableWithdraw(senior), 50 ether);

        uint256 before = usdg.balanceOf(senior);
        vm.prank(senior);
        vault.claimWithdraw();
        assertEq(usdg.balanceOf(senior) - before, 50 ether);
        assertEq(vault.claimableWithdraw(senior), 0);
    }

    function test_queuePaidBeforeNewMatching() public {
        _depositSenior(senior, 100 ether);
        uint256 id1 = _depositJunior(junior, 1 ether); // matches 100
        assertTrue(vault.isFullyMatched(id1));

        vm.prank(senior);
        vault.withdrawSenior(100 ether); // queue all

        // Open new junior needing 100 — must NOT match until queue filled then leftover
        address junior2 = makeAddr("junior2");
        mstr.mint(junior2, 1 ether);
        vm.startPrank(junior2);
        mstr.approve(address(vault), 1 ether);
        uint256 id2 = vault.depositJunior(1 ether);
        vm.stopPrank();
        assertFalse(vault.isMatched(id2));

        // Deposit 100: fills queue first, no idle left for match
        _depositSenior(senior2, 100 ether);
        assertEq(vault.claimableWithdraw(senior), 100 ether);
        assertFalse(vault.isMatched(id2));

        // Deposit another 100: queue done, can match
        _depositSenior(makeAddr("senior3"), 100 ether);
        assertTrue(vault.isFullyMatched(id2));
    }

    function test_juniorMatch_min25() public {
        _depositSenior(senior, 1000 ether);
        // 0.1 MSTR at $100 = $10 < $25
        mstr.mint(junior, 0.1 ether);
        vm.startPrank(junior);
        mstr.approve(address(vault), 0.1 ether);
        vm.expectRevert(LeveredLpVault.BelowMinDeposit.selector);
        vault.depositJunior(0.1 ether);
        vm.stopPrank();

        uint256 id = _depositJunior(junior, 1 ether); // $100
        assertTrue(vault.isMatched(id));
        assertGe(vault.reservedSenior(), 25 ether);
    }

    function test_depositBothSides_poolModel() public {
        uint256 need = vault.previewSeniorAssets(MSTR_IN);
        _depositSenior(senior, need);
        uint256 id = _depositJunior(junior, MSTR_IN);
        assertTrue(vault.isFullyMatched(id));
        assertEq(vault.reservedSenior(), need);
        assertEq(vault.freeSenior(), 0);
    }

    function test_withdrawUnmatched_alwaysWallet_ignoresAutoCompound() public {
        mstr.mint(junior, 1 ether);
        vm.startPrank(junior);
        mstr.approve(address(vault), 1 ether);
        vault.setAutoCompound(true);
        uint256 id = vault.depositJunior(1 ether);
        // unmatched (no senior)
        assertFalse(vault.isMatched(id));
        vault.withdrawUnmatched(id);
        vm.stopPrank();
        // Paid wallet — no new position opened
        assertEq(mstr.balanceOf(junior), 1 ether);
        assertEq(vault.nextPositionId(), 2);
    }

    function test_autoCompound_underMin_usdgPath() public {
        // Tiny rate + small fee → junior leftover < $25 → wallet (no compound clog).
        LeveredLpVault v = _deployVault(7 days, 0.0001e18, address(this));
        v.unpause();
        v.setDepositCaps(0, 0, 0);
        v.setMinDepositUsdg(25 ether);

        usdg.mint(senior, 100 ether);
        vm.startPrank(senior);
        usdg.approve(address(v), 100 ether);
        v.depositSenior(100 ether);
        vm.stopPrank();

        mstr.mint(junior, 1 ether);
        vm.startPrank(junior);
        mstr.approve(address(v), 1 ether);
        uint256 id = v.depositJunior(1 ether);
        v.setAutoCompound(true);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        usdg.mint(address(this), 10 ether);
        usdg.approve(address(v), 10 ether);
        v.accrueLpFee(id, 0.01 ether);

        uint256 junBefore = usdg.balanceOf(junior);
        uint256 nextBefore = v.nextPositionId();
        vm.prank(junior);
        v.claimFees(id);
        assertEq(v.nextPositionId(), nextBefore);
        assertGt(usdg.balanceOf(junior), junBefore);
    }

    function test_gasRefund_onlyOnMatch_scaled() public {
        vm.deal(junior, 1 ether);
        mstr.mint(junior, 1 ether);
        vm.startPrank(junior);
        mstr.approve(address(vault), 1 ether);
        vault.depositJunior(1 ether); // unmatched open
        vault.fundGasCredit{value: 0.01 ether}();
        vm.stopPrank();

        uint256 refund = vault.gasRefundWei();
        uint256 ethBefore = senior.balance;
        // Deposit senior that fully matches $100
        _depositSenior(senior, 100 ether);
        uint256 got = senior.balance - ethBefore;
        assertEq(got, refund); // full match → full refund

        // Second senior with no open junior → no refund
        address s3 = makeAddr("s3");
        vm.deal(s3, 0);
        uint256 b2 = s3.balance;
        _depositSenior(s3, 25 ether);
        assertEq(s3.balance, b2);
    }

    function test_gasRefund_noneWhenUnmatchedDeposit() public {
        // No open junior
        vm.deal(senior, 0);
        uint256 b = senior.balance;
        _depositSenior(senior, 25 ether);
        assertEq(senior.balance, b);
    }

    function test_earlyExit_coverOrder_feesThenIdleThenWallet() public {
        uint256 need = vault.previewSeniorAssets(1 ether);
        _depositSenior(senior, need);
        // Junior also lends (idle)
        _depositSenior(junior, 50 ether);
        uint256 id = _depositJunior(junior, 1 ether);

        usdg.mint(donor, 1);
        // No fees; accrual will need cover. Warp some time.
        vm.warp(block.timestamp + 30 minutes); // term is 1 hour in setUp

        // Fund junior wallet for residual
        usdg.mint(junior, 10 ether);
        vm.startPrank(junior);
        usdg.approve(address(vault), type(uint256).max);
        vault.earlyExit(id, LeveredLpVault.CoverMode.IdleCarry);
        vm.stopPrank();

        assertEq(uint256(vault.positionState(id)), uint256(LeveredLpVault.PositionState.Closed));
    }

    function test_settle_backstopFirst_thenJunior() public {
        LeveredLpVault v = _deployVault(1 hours, MORPHO, address(this));
        v.unpause();
        usdg.mint(senior, 100 ether);
        vm.startPrank(senior);
        usdg.approve(address(v), 100 ether);
        v.depositSenior(100 ether);
        vm.stopPrank();
        mstr.mint(junior, 1 ether);
        vm.startPrank(junior);
        mstr.approve(address(v), 1 ether);
        uint256 id = v.depositJunior(1 ether);
        vm.stopPrank();

        // No fees → full accrual shortfall at settle
        usdg.mint(address(this), 1 ether);
        usdg.approve(address(v), 1 ether);
        v.fundBackstop(0.01 ether);

        vm.warp(block.timestamp + 1 hours + 1);
        usdg.mint(junior, 10 ether);
        vm.startPrank(junior);
        usdg.approve(address(v), type(uint256).max);
        LeveredLpVault.Settlement memory s = v.settle(id, LeveredLpVault.CoverMode.Wallet);
        vm.stopPrank();
        assertGt(s.fromBackstop, 0);
        assertEq(uint256(v.positionState(id)), uint256(LeveredLpVault.PositionState.Closed));
    }

    function test_floatingRateIndex_notLockedPerPosition() public {
        _depositSenior(senior, 100 ether);
        uint256 id = _depositJunior(junior, 1 ether);
        (,,,,,,,,,,, uint256 idx0,) = vault.positions(id);
        assertGt(idx0, 0);

        vm.warp(block.timestamp + 30 minutes); // stay inside 1h term
        vault.setMorphoRate(0.05e18); // syncs index then updates rate
        assertGt(vault.currentRateIndex(), idx0);

        // Accrual uses floating index (view)
        uint256 accrual = vault.previewEarlyExit(id).accrual;
        assertGt(accrual, 0);
    }

    function test_interestStopsAtMaturity() public {
        LeveredLpVault v = _deployVault(1 days, MORPHO, address(this));
        v.unpause();
        usdg.mint(senior, 100 ether);
        vm.startPrank(senior);
        usdg.approve(address(v), 100 ether);
        v.depositSenior(100 ether);
        vm.stopPrank();
        mstr.mint(junior, 1 ether);
        vm.startPrank(junior);
        mstr.approve(address(v), 1 ether);
        uint256 id = v.depositJunior(1 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        LeveredLpVault.Settlement memory a = v.previewSettle(id);
        vm.warp(block.timestamp + 10 days);
        LeveredLpVault.Settlement memory b = v.previewSettle(id);
        assertEq(a.accrual, b.accrual);
    }

    /// Accrual must stop at maturity even when the rate index moves afterwards (another match, a rate change).
    function test_accrualStopsAtMaturity_afterLaterMatchAndRateChange() public {
        _depositSenior(senior, 1_000 ether);
        uint256 id = _depositJunior(junior, MSTR_IN); // $1k, fully matched
        vm.warp(block.timestamp + 1 hours); // maturity
        uint256 atMaturity = vault.previewSettle(id).accrual;
        assertGt(atMaturity, 0);

        vm.warp(block.timestamp + 5 days);
        _depositSenior(senior2, 100 ether);
        _depositJunior(donor, 1 ether); // a later match
        vault.setMorphoRate(0.05e18); // and a later rate change
        vm.warp(block.timestamp + 5 days);

        assertEq(vault.previewSettle(id).accrual, atMaturity, "interest kept accruing past maturity");
    }

    /// A rate change mid-term accrues each segment at its own rate, and nothing after maturity.
    function test_rateChangeMidTerm_accruesPiecewise() public {
        _depositSenior(senior, 1_000 ether);
        uint256 id = _depositJunior(junior, MSTR_IN);
        vm.warp(block.timestamp + 30 minutes);
        vault.setMorphoRate(0.05e18);
        vm.warp(block.timestamp + 2 hours);
        vault.setMorphoRate(0.01e18);

        uint256 idx1 = 1e18 + 1e18 * MORPHO * 30 minutes / (1e18 * 365 days);
        uint256 idx2 = idx1 + idx1 * 0.05e18 * 30 minutes / (1e18 * 365 days);
        uint256 expected = 1_000 ether * (idx2 - 1e18) / 1e18;
        assertEq(vault.previewSettle(id).accrual, expected);
    }

    /// A partially matched position past its term can never match again; it must leave the open queue
    /// instead of using up match iterations ahead of live positions.
    function test_expiredPartialMatch_leavesOpenQueue() public {
        vault.setMatchCap(1);
        _depositSenior(senior, 25 ether); // only $25 idle
        uint256 a = _depositJunior(junior, MSTR_IN); // $1k target, partially matched
        assertTrue(vault.isMatched(a));
        assertFalse(vault.isFullyMatched(a));
        vm.warp(block.timestamp + 1 hours + 1); // a is past term, still partial

        uint256 b = _depositJunior(donor, 1 ether); // $100, waits behind a
        assertFalse(vault.isMatched(b));
        _depositSenior(senior2, 100 ether); // drops expired a from the queue
        _depositSenior(senior2, 100 ether);
        assertTrue(vault.isFullyMatched(b), "expired partial position blocked matching");
    }

    function _routerAndMaturedPosition() internal returns (uint256 id) {
        MockMstrSellRouter router = new MockMstrSellRouter(address(mstr), address(usdg), PRICE);
        usdg.mint(address(router), 1_000 ether);
        vault.setSellSharesRouter(address(router));
        _depositSenior(senior, 1_000 ether);
        id = _depositJunior(junior, MSTR_IN); // $1k, fully matched, no fees
        vm.warp(block.timestamp + 1 hours + 1);
    }

    /// Junior settles with no USDG (or no approval): MSTR is sold for the interest instead of forgiving it.
    function test_settle_juniorWithoutUsdg_sellsMstrToCover() public {
        uint256 id = _routerAndMaturedPosition();
        uint256 poolBefore = vault.totalSeniorAssets();
        vm.prank(junior);
        LeveredLpVault.Settlement memory s = vault.settle(id);

        assertGt(s.coverUsdg, 0);
        assertGt(s.mstrSold, 0, "MSTR sold to cover");
        assertEq(s.feeShortfallUsdg, 0, "nothing forgiven");
        assertEq(vault.totalSeniorAssets(), poolBefore + s.accrual, "lenders get the full interest");
        assertEq(mstr.balanceOf(junior), MSTR_IN - s.mstrSold);
    }

    /// A lender cannot settle a position that owes cover, so cannot force the junior's MSTR to be sold.
    function test_settle_lenderCannotForceSale() public {
        uint256 id = _routerAndMaturedPosition();
        vm.startPrank(senior);
        vm.expectRevert(LeveredLpVault.NotJunior.selector);
        vault.settle(id);
        vm.expectRevert(LeveredLpVault.SellSharesDisabled.selector);
        vault.settle(id, LeveredLpVault.CoverMode.SellShares);
        vm.stopPrank();
    }

    function test_treasuryCutZero_usesIsSetFlag() public {
        vault.clearTreasuryCuts();
        assertFalse(vault.treasuryCutIsSet());
        _depositSenior(senior, 100 ether);
        uint256 id = _depositJunior(junior, 1 ether);
        usdg.mint(donor, 1 ether);
        vm.startPrank(donor);
        usdg.approve(address(vault), 1 ether);
        vault.accrueLpFee(id, 1 ether);
        vm.stopPrank();
        vm.prank(junior);
        LeveredLpVault.ClaimFeesResult memory r = vault.claimFees(id);
        assertEq(r.treasury, 0);
    }

    function test_stalePrice_revertsOnPushableOracle() public {
        PushablePriceOracle push = new PushablePriceOracle(address(this), PRICE);
        LeveredLpVaultV2 implementation = new LeveredLpVaultV2();
        bytes memory initData = abi.encodeCall(
            LeveredLpVault.initialize,
            (address(mstr), address(usdg), address(push), uint64(1 hours), MORPHO, address(this))
        );
        LeveredLpVault v = LeveredLpVault(address(new ERC1967Proxy(address(implementation), initData)));
        v.unpause();
        v.setMaxPriceStale(1 hours);
        usdg.mint(senior, 25 ether);
        vm.startPrank(senior);
        usdg.approve(address(v), 25 ether);
        v.depositSenior(25 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 hours);
        mstr.mint(junior, 1 ether);
        vm.startPrank(junior);
        mstr.approve(address(v), 1 ether);
        vm.expectRevert(LeveredLpVault.StalePrice.selector);
        v.depositJunior(1 ether);
        vm.stopPrank();
    }

    function test_seniorCap_uncappedZero() public {
        assertEq(vault.maxTotalSeniorUsdg(), 0);
        _depositSenior(senior, 30_000 ether); // > old 25k
        assertEq(vault.totalSeniorAssets(), 30_000 ether);
    }

    function test_uupsUpgradeKeepsStorage() public {
        _depositSenior(senior, 100 ether);
        uint256 assets = vault.totalSeniorAssets();
        LeveredLpVaultV2 next = new LeveredLpVaultV2();
        vault.upgradeToAndCall(address(next), "");
        assertEq(vault.totalSeniorAssets(), assets);
        assertEq(vault.version(), "v3-lender-pool");
    }

    function test_pauseBlocksDeposits_notViews() public {
        vault.pause();
        usdg.mint(senior, 25 ether);
        vm.startPrank(senior);
        usdg.approve(address(vault), 25 ether);
        vm.expectRevert(LeveredLpVault.Paused.selector);
        vault.depositSenior(25 ether);
        vm.stopPrank();
    }

    function test_makerWaterfall_stillApplies() public {
        uint256 accrual = CarryMath.morphoAccrual(100_000 ether, vault.morphoRateWad(), 365 days, 365 days);
        CarryMath.WaterfallSplit memory s = CarryMath.waterfallFromGross(10_000 ether, accrual, 0.2e18, 0.2e18);
        // morphoRateWad 3.9% → floor 3900 on 100k / year
        assertEq(s.seniorFloor, 3900 ether);
    }

    function test_runtimeSize_measured() public {
        LeveredLpVaultV2 impl = new LeveredLpVaultV2();
        uint256 size;
        assembly {
            size := extcodesize(impl)
        }
        // Mainnet gate: implementation must fit EIP-170.
        assertLe(size, 24576, "v3 impl exceeds EIP-170");
        emit log_named_uint("v3_runtime_bytes", size);
        emit log_named_uint("eip170_limit", 24576);
    }

    function test_poolShareMath_library() public pure {
        uint256 sh = CarryPool.convertToShares(100 ether, 0, 0);
        assertGt(sh, 0);
        uint256 assets = CarryPool.convertToAssets(sh, sh, 100 ether);
        assertLe(assets, 100 ether);
    }
}

contract RejectEth {
    fallback() external payable {
        revert("no eth");
    }
    receive() external payable {
        revert("no eth");
    }
}
