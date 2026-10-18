// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LeveredLpVault} from "../src/LeveredLpVault.sol";
import {LeveredLpVaultV2} from "../src/LeveredLpVaultV2.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {PushablePriceOracle} from "../src/oracle/PushablePriceOracle.sol";
import {CarryMath} from "../src/libraries/CarryMath.sol";
import {CarryPool} from "../src/libraries/CarryPool.sol";
import {IBoostHook} from "../src/interfaces/IBoostHook.sol";
import {IStrategyStaking} from "../src/interfaces/IStrategyStaking.sol";
import {StrategyBoostHook} from "../src/StrategyBoostHook.sol";

contract MockStaking is IStrategyStaking {
    mapping(address => uint256) public stakedOf;

    function set(address wallet, uint256 amount) external {
        stakedOf[wallet] = amount;
    }
}

contract FixedCutHook is IBoostHook {
    uint256 public cut;

    constructor(uint256 cut_) {
        cut = cut_;
    }

    function treasuryCutOf(address, uint256) external view returns (uint256) {
        return cut;
    }
}

contract RevertingHook is IBoostHook {
    function treasuryCutOf(address, uint256) external pure returns (uint256) {
        revert("hook down");
    }
}

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
        assertEq(vault.version(), "v3.2-dualpool");
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

    function _payFee(uint256 id, uint256 amount) internal {
        usdg.mint(donor, amount);
        vm.startPrank(donor);
        usdg.approve(address(vault), amount);
        vault.accrueLpFee(id, amount);
        vm.stopPrank();
    }

    /// No lender coupon: an early exit with no fees costs the junior nothing and leaves the pool as it was.
    function test_earlyExit_noFees_costsNothing() public {
        _depositSenior(senior, 1_000 ether);
        uint256 id = _depositJunior(junior, MSTR_IN);
        assertTrue(vault.isFullyMatched(id));
        uint256 poolBefore = vault.totalSeniorAssets();
        vm.warp(block.timestamp + 30 minutes);

        vm.prank(junior);
        LeveredLpVault.EarlyExitResult memory r = vault.earlyExit(id);

        assertEq(r.accrual, 0);
        assertEq(r.coverUsdg, 0);
        assertEq(r.mstrReturned, MSTR_IN);
        assertEq(mstr.balanceOf(junior), MSTR_IN);
        assertEq(usdg.balanceOf(junior), 0);
        assertEq(vault.totalSeniorAssets(), poolBefore);
        assertEq(vault.reservedSenior(), 0);
        assertEq(uint256(vault.positionState(id)), uint256(LeveredLpVault.PositionState.Closed));
    }

    /// Settle with no fees owes nothing, so the backstop is never drawn.
    function test_settle_noFees_backstopUntouched() public {
        _depositSenior(senior, 100 ether);
        uint256 id = _depositJunior(junior, 1 ether);
        usdg.mint(address(this), 1 ether);
        usdg.approve(address(vault), 1 ether);
        vault.fundBackstop(1 ether);
        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(junior);
        LeveredLpVault.Settlement memory s = vault.settle(id);
        assertEq(s.fromBackstop, 0);
        assertEq(s.coverUsdg, 0);
        assertEq(vault.backstop(), 1 ether);
        assertEq(mstr.balanceOf(junior), 1 ether);
    }

    /// Fees split 40% senior, 20% treasury (base cut), 40% junior.
    function test_settle_splits40_40_20() public {
        _depositSenior(senior, 1_000 ether);
        uint256 id = _depositJunior(junior, MSTR_IN);
        _payFee(id, 10 ether);
        uint256 poolBefore = vault.totalSeniorAssets();
        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(junior);
        LeveredLpVault.Settlement memory s = vault.settle(id);
        assertEq(s.seniorPerf, 4 ether);
        assertEq(s.treasury, 2 ether);
        assertEq(s.juniorYield, 4 ether);
        assertEq(vault.totalSeniorAssets(), poolBefore + 4 ether, "senior share compounds into the pool");
        assertEq(vault.backstop(), 2 ether);
        assertEq(usdg.balanceOf(junior), 4 ether);
    }

    /// Whatever the gross and cut, the parts add up to the gross and the senior gets 40%.
    function testFuzz_waterfall_partsSumToGross(uint256 gross, uint256 cutWad) public pure {
        gross = bound(gross, 0, 1e30);
        cutWad = bound(cutWad, 0, 0.2e18);
        CarryMath.WaterfallSplit memory w = CarryMath.waterfallFromGross(gross, 0, cutWad, 0.4e18);
        assertEq(w.seniorFloor, 0);
        assertEq(w.treasury + w.seniorPerf + w.junior, gross);
        assertEq(w.seniorPerf, gross * 0.4e18 / 1e18);
        assertGe(w.junior, w.seniorPerf);
    }

    /// Positions roll at term without building up any interest owed.
    function test_rolledPosition_owesNothingPastTerm() public {
        _depositSenior(senior, 100 ether);
        uint256 id = _depositJunior(junior, 1 ether);
        vm.warp(block.timestamp + 30 days);
        LeveredLpVault.Settlement memory s = vault.previewSettle(id);
        assertEq(s.accrual, 0);
        assertEq(s.coverUsdg, 0);
        assertEq(s.mstrKept, 1 ether);
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

    /// A lender cannot settle a healthy position: positions roll and only the junior closes them.
    function test_settle_lenderCannotCloseHealthyPosition() public {
        _depositSenior(senior, 1_000 ether);
        uint256 id = _depositJunior(junior, MSTR_IN);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(senior);
        vm.expectRevert(LeveredLpVault.NotJunior.selector);
        vault.settle(id);
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

    // ─── STRATEGY boost hook ─────────────────────────────────────────────────

    /// @dev Opens a matched position, pushes 1 USDG of fees and claims them; returns the treasury share.
    function _treasuryOnFreshPosition() internal returns (uint256 id, uint256 treasury) {
        _depositSenior(senior, 100 ether);
        id = _depositJunior(junior, 1 ether);
        assertTrue(vault.isMatched(id));
        usdg.mint(donor, 1 ether);
        vm.startPrank(donor);
        usdg.approve(address(vault), 1 ether);
        vault.accrueLpFee(id, 1 ether);
        vm.stopPrank();
        vm.prank(junior);
        treasury = vault.claimFees(id).treasury;
    }

    function test_boostHook_noneSet_usesBaseCut() public {
        (uint256 id, uint256 treasury) = _treasuryOnFreshPosition();
        assertGt(treasury, 0);
        assertTrue(vault.positionState(id) != LeveredLpVault.PositionState.Boosted);
    }

    function test_boostHook_lowersCutForStakedJunior() public {
        uint256 snap = vm.snapshotState();
        (, uint256 base) = _treasuryOnFreshPosition();
        vm.revertToState(snap);

        MockStaking staking = new MockStaking();
        staking.set(junior, 100_000 ether); // Level II: 16.25% vs 20% base
        vault.setBoostHook(new StrategyBoostHook(staking));
        (uint256 id, uint256 boosted) = _treasuryOnFreshPosition();
        assertEq(vault.positionState(id) == LeveredLpVault.PositionState.Boosted, true);
        assertApproxEqAbs(boosted, base * 1625 / 2000, 1);
    }

    function test_boostHook_cannotRaiseCutAboveBase() public {
        uint256 snap = vm.snapshotState();
        (, uint256 base) = _treasuryOnFreshPosition();
        vm.revertToState(snap);

        vault.setBoostHook(new FixedCutHook(0.5e18));
        (uint256 id, uint256 treasury) = _treasuryOnFreshPosition();
        assertEq(treasury, base);
        assertTrue(vault.positionState(id) != LeveredLpVault.PositionState.Boosted);
    }

    function test_boostHook_cutLockedAtMatch() public {
        uint256 snap = vm.snapshotState();
        (, uint256 base) = _treasuryOnFreshPosition();
        vm.revertToState(snap);

        MockStaking staking = new MockStaking();
        staking.set(junior, 10_000_000 ether); // Level V: 5%
        vault.setBoostHook(new StrategyBoostHook(staking));
        _depositSenior(senior, 100 ether);
        uint256 id = _depositJunior(junior, 1 ether);

        // Unstaking and unsetting the hook after match leave the locked cut in place.
        staking.set(junior, 0);
        vault.setBoostHook(IBoostHook(address(0)));
        usdg.mint(donor, 1 ether);
        vm.startPrank(donor);
        usdg.approve(address(vault), 1 ether);
        vault.accrueLpFee(id, 1 ether);
        vm.stopPrank();
        vm.prank(junior);
        assertApproxEqAbs(vault.claimFees(id).treasury, base * 5 / 20, 1);
        assertEq(vault.positionState(id) == LeveredLpVault.PositionState.Boosted, true);
    }

    function test_boostHook_revertingHookBlocksMatchUntilUnset() public {
        vault.setBoostHook(new RevertingHook());
        _depositSenior(senior, 100 ether);
        mstr.mint(junior, 1 ether);
        vm.startPrank(junior);
        mstr.approve(address(vault), 1 ether);
        vm.expectRevert(bytes("hook down"));
        vault.depositJunior(1 ether);
        vm.stopPrank();

        vault.setBoostHook(IBoostHook(address(0)));
        assertTrue(vault.isMatched(_depositJunior(junior, 1 ether)));
    }

    function test_boostHook_onlyOwnerSets() public {
        vm.prank(junior);
        vm.expectRevert();
        vault.setBoostHook(IBoostHook(address(0xB00)));
    }

    function test_strategyBoostHook_tiers() public {
        MockStaking staking = new MockStaking();
        StrategyBoostHook hook = new StrategyBoostHook(staking);
        address w = makeAddr("w");
        assertEq(hook.treasuryCutOf(w, 0.2e18), 0.2e18);
        staking.set(w, 24_999 ether);
        assertEq(hook.treasuryCutOf(w, 0.2e18), 0.2e18);
        staking.set(w, 25_000 ether);
        assertEq(hook.treasuryCutOf(w, 0.2e18), 0.175e18);
        staking.set(w, 500_000 ether);
        assertEq(hook.treasuryCutOf(w, 0.2e18), 0.1375e18);
        staking.set(w, 2_000_000 ether);
        assertEq(hook.treasuryCutOf(w, 0.2e18), 0.1e18);
        staking.set(w, 50_000_000 ether);
        assertEq(hook.treasuryCutOf(w, 0.2e18), 0.05e18);
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
        assertEq(vault.version(), "v3.2-dualpool");
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
