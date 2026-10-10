// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {DeployLeveredLpVault} from "../script/DeployLeveredLpVault.s.sol";
import {DeployCarryTestnet} from "../script/DeployCarryTestnet.s.sol";
import {LeveredLpVault} from "../src/LeveredLpVault.sol";
import {LeveredLpVaultV2} from "../src/LeveredLpVaultV2.sol";
import {FixedPriceOracle} from "../src/oracle/FixedPriceOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFeePool} from "../src/mocks/MockFeePool.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

contract LeveredLpVaultTest is Test {
    uint256 internal constant PRICE = 100 ether;
    uint256 internal constant MSTR_IN = 10 ether; // $1k at $100
    uint256 internal constant MORPHO = 0.04e18; // 4% for sheet examples

    MockERC20 internal mstr;
    MockERC20 internal usdg;
    MockOracle internal oracle;
    MockFeePool internal pool;
    LeveredLpVault internal vault;
    address internal impl;

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
        vault = _deployVault(1 hours, MORPHO, address(this));
        pool = new MockFeePool(address(usdg));
        vault.unpause();
    }

    function _deployVault(uint64 term_, uint256 morphoRate, address owner_) internal returns (LeveredLpVault v) {
        LeveredLpVault implementation = new LeveredLpVault();
        impl = address(implementation);
        bytes memory initData = abi.encodeCall(
            LeveredLpVault.initialize,
            (address(mstr), address(usdg), address(oracle), term_, morphoRate, owner_)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        v = LeveredLpVault(address(proxy));
    }

    // ─── lifecycle / safety ──────────────────────────────────────────────────

    function test_startsPaused() public {
        LeveredLpVault fresh = _deployVault(7 days, 0.039e18, address(this));
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
        assertTrue(vault.isFullyMatched(id));
        assertEq(uint256(vault.positionState(id)), uint256(LeveredLpVault.PositionState.Active));

        (address owner,, uint256 seniorPrincipal,,,,,, bool settled,,,) = vault.positions(id);
        assertEq(owner, junior);
        assertEq(seniorPrincipal, seniorNeed);
        assertFalse(settled);
    }

    function test_openThenMatchOnSeniorDeposit() public {
        uint256 id = _depositJunior(junior, MSTR_IN);
        assertFalse(vault.isMatched(id));
        assertEq(uint256(vault.positionState(id)), uint256(LeveredLpVault.PositionState.Idle));
        (,,,,,, uint64 openedAt,, bool settled,,,) = vault.positions(id);
        assertEq(openedAt, 0);
        assertFalse(settled);
        assertEq(vault.openHead(), id);

        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        _depositSenior(senior, seniorNeed);

        assertTrue(vault.isMatched(id));
        (,, uint256 seniorPrincipal,,,, uint64 matchedAt,,,,, uint256 rateLocked) = vault.positions(id);
        assertEq(seniorPrincipal, seniorNeed);
        assertEq(matchedAt, block.timestamp);
        assertEq(rateLocked, MORPHO);
        assertEq(vault.openHead(), 0);
    }

    function test_withdrawUnmatchedReturnsShares() public {
        uint256 id = _depositJunior(junior, MSTR_IN);
        vm.prank(junior);
        vault.withdrawUnmatched(id);
        assertEq(mstr.balanceOf(junior), MSTR_IN);
        (,,,,,,,, bool settled,,,) = vault.positions(id);
        assertTrue(settled);
        assertEq(uint256(vault.positionState(id)), uint256(LeveredLpVault.PositionState.Closed));
    }

    function test_accrueFeesNoCutOnFeeIn() public {
        uint256 id = _openMatched();
        uint256 gross = 1_000 ether;
        _payFee(id, gross);

        assertEq(vault.backstop(), 0);
        (,,,,, uint256 feeUsdg,,,,,,) = vault.positions(id);
        assertEq(feeUsdg, gross);
        assertEq(usdg.balanceOf(address(vault)), vault.previewSeniorAssets(MSTR_IN) + gross);
    }

    function test_pauseBlocksNewDeposits() public {
        uint256 id = _openMatched();
        vault.pause();
        usdg.mint(attacker, 1 ether);
        vm.startPrank(attacker);
        usdg.approve(address(vault), 1 ether);
        vm.expectRevert(LeveredLpVault.Paused.selector);
        vault.depositSenior(1 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);
        vault.settle(id);
        assertEq(mstr.balanceOf(junior) + mstr.balanceOf(address(vault)), MSTR_IN);
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
    }

    function test_randomAddressCannotPullFunds() public {
        uint256 id = _openMatched();
        vm.startPrank(attacker);
        vm.expectRevert(LeveredLpVault.InsufficientFree.selector);
        vault.withdrawSenior(1 ether);
        vm.expectRevert(LeveredLpVault.ExternalLpForbidden.selector);
        vault.joinPool("");
        vm.expectRevert();
        vault.rescueToken(address(usdg), attacker, 1);
        vm.expectRevert(LeveredLpVault.NotJunior.selector);
        vault.earlyExit(id);
        vm.stopPrank();
    }

    function test_externalCannotLpBesideVault() public {
        assertEq(vault.dualPoolAdapter(), address(0));
        vm.expectRevert(LeveredLpVault.ExternalLpForbidden.selector);
        vault.joinPool("");
    }

    function test_twoXTracksHoldCloserThanUnlevered() public {
        uint256 id = _openMatched();
        oracle.setPrice(PRICE * 4);
        (uint256 hold, uint256 levered, uint256 unlevered) = vault.mark(id);
        assertEq(levered, hold);
        assertGt(hold, unlevered);
        assertEq(hold, 4_000 ether);
        assertEq(unlevered, 3_000 ether);
    }

    function test_depositCapsEnforceTotalAndPerWallet() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        vault.setDepositCaps(seniorNeed, seniorNeed, seniorNeed);
        _depositSenior(senior, seniorNeed);

        usdg.mint(senior2, 1 ether);
        vm.startPrank(senior2);
        usdg.approve(address(vault), 1 ether);
        vm.expectRevert(LeveredLpVault.CapExceeded.selector);
        vault.depositSenior(1 ether);
        vm.stopPrank();
    }

    function test_setDepositCapsOnlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vault.setDepositCaps(1, 1, 1);
    }

    function test_morphoRateOwnerSet() public {
        assertEq(vault.morphoRateWad(), MORPHO);
        vault.setMorphoRate(0.039e18);
        assertEq(vault.morphoFloorAprWad(), 0.039e18);
        vault.setMorphoRate(0.05e18); // cap
        vm.expectRevert(LeveredLpVault.BadApr.selector);
        vault.setMorphoRate(0.06e18);
        vm.expectRevert(LeveredLpVault.BadApr.selector);
        vault.setMorphoRate(0.3e18);
    }

    function test_broadcastDisarmed() public {
        DeployLeveredLpVault deploy = new DeployLeveredLpVault();
        assertFalse(deploy.broadcastArmed());
        vm.expectRevert(DeployLeveredLpVault.BroadcastBlocked.selector);
        deploy.run();
    }

    function test_carryTestnetScriptDisarmed() public {
        DeployCarryTestnet deploy = new DeployCarryTestnet();
        assertFalse(deploy.broadcastArmed());
        deploy.run();
    }

    function test_fixedOracleHasNoWriter() public {
        FixedPriceOracle fixedOracle = new FixedPriceOracle(PRICE);
        assertEq(fixedOracle.mstrPriceWad(), PRICE);
    }

    // ─── Maker waterfall ($10k sheet ratios) ─────────────────────────────────

    /// @notice $10k senior / $10k junior book, 7d, morpho 4%, gross ~$26.85 @ 7% on $20k.
    ///         Scaled with exact sheet dollars using 18-decimal USDG units.
    function test_makerWaterfall_10kSheet() public {
        // Use 7-day term vault at morpho 4%
        LeveredLpVault v = _deployVault(7 days, 0.04e18, address(this));
        v.unpause();
        // Rebind helpers via local deposits
        uint256 seniorP = 10_000 ether;
        uint256 mstrAmt = 100 ether; // $10k at $100
        usdg.mint(senior, seniorP);
        vm.startPrank(senior);
        usdg.approve(address(v), seniorP);
        v.depositSenior(seniorP);
        vm.stopPrank();
        mstr.mint(junior, mstrAmt);
        vm.startPrank(junior);
        mstr.approve(address(v), mstrAmt);
        uint256 id = v.depositJunior(mstrAmt);
        vm.stopPrank();
        assertTrue(v.isFullyMatched(id));

        vm.warp(block.timestamp + 7 days);
        // Before settle term check — claimFees blocked after term; use previewWaterfall directly
        // Sheet: accrual = 10000 * 0.04 * 7/365 ≈ 7.6712328767
        uint256 elapsed = 7 days;
        uint256 accrual = v.previewSeniorAccrual(seniorP, elapsed);
        uint256 expectedAccrual = seniorP * 4 / 100 * 7 / 365;
        assertEq(accrual, expectedAccrual);

        // gross @ 7% on $20k book = 20000 * 0.07 * 7/365
        uint256 gross = uint256(20_000 ether) * 7 / 100 * 7 / 365;
        LeveredLpVault.WaterfallSplit memory s = v.previewWaterfall(gross, seniorP, elapsed, false);

        // Sheet: floor 7.67, treasury 5.37, seniorPerf 5.37, junior 8.44
        assertApproxEqAbs(s.seniorFloor, 7.67 ether, 0.01 ether);
        assertApproxEqAbs(s.treasury, 5.37 ether, 0.01 ether);
        assertApproxEqAbs(s.seniorPerf, 5.37 ether, 0.01 ether);
        assertApproxEqAbs(s.junior, 8.44 ether, 0.02 ether);
        assertEq(s.seniorFloor + s.treasury + s.seniorPerf + s.junior, gross);
        assertApproxEqAbs(s.seniorTotal, 13.04 ether, 0.02 ether);
    }

    function test_claimFeesAppliesWaterfallNotOnFeeIn() public {
        uint256 id = _openMatched();
        vm.warp(block.timestamp + 30 minutes);
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 accrual = vault.previewSeniorAccrual(seniorNeed, 30 minutes);
        uint256 gross = 10 ether;
        _payFee(id, gross);
        assertEq(vault.backstop(), 0);

        LeveredLpVault.ClaimFeesResult memory preview = vault.previewClaimFees(id);
        assertEq(preview.gross, gross);
        assertEq(preview.accrual, accrual);
        assertEq(preview.seniorFloor + preview.treasury + preview.seniorPerf + preview.toJunior, gross);

        uint256 junBefore = usdg.balanceOf(junior);
        vm.prank(junior);
        LeveredLpVault.ClaimFeesResult memory result = vault.claimFees(id);
        assertEq(usdg.balanceOf(junior), junBefore + result.toJunior);
        assertEq(vault.backstop(), result.treasury);
        (,,,,, uint256 feeUsdg,,,,,,) = vault.positions(id);
        assertEq(feeUsdg, 0);
        assertTrue(vault.isMatched(id));
    }

    function test_claimFeesOnlyJunior() public {
        uint256 id = _openMatched();
        vm.warp(block.timestamp + 30 minutes);
        _payFee(id, 5 ether);
        vm.prank(attacker);
        vm.expectRevert(LeveredLpVault.NotJunior.selector);
        vault.claimFees(id);
    }

    function test_settleAppliesWaterfall() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 id = _openMatched();
        uint256 gross = 5 ether;
        _payFee(id, gross);
        vm.warp(block.timestamp + 1 hours);

        LeveredLpVault.Settlement memory settlement = vault.settle(id);
        assertEq(settlement.seniorFloor + settlement.treasury + settlement.seniorPerf + settlement.juniorYield, gross);
        assertEq(mstr.balanceOf(junior), MSTR_IN);
        assertEq(usdg.balanceOf(junior), settlement.juniorYield);
        assertEq(uint256(vault.positionState(id)), uint256(LeveredLpVault.PositionState.Closed));

        vm.prank(senior);
        vault.withdrawSenior(seniorNeed);
        // Senior gets principal + floor + perf (USDG path; no shortfall with fat fees)
        assertApproxEqAbs(
            usdg.balanceOf(senior), seniorNeed + settlement.seniorFloor + settlement.seniorPerf, 1_000
        );
    }

    // ─── partial match ───────────────────────────────────────────────────────

    function test_partialMatchThenAutoMatchOnSeniorDeposit() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 half = seniorNeed / 2;
        _depositSenior(senior, half);
        uint256 id = _depositJunior(junior, MSTR_IN);

        assertTrue(vault.isMatched(id));
        assertFalse(vault.isFullyMatched(id));
        (,, uint256 sp, uint256 target,,,,,,,,) = vault.positions(id);
        assertEq(sp, half);
        assertEq(target, seniorNeed);
        assertEq(vault.openHead(), id); // residual still queued

        _depositSenior(senior2, seniorNeed - half);
        assertTrue(vault.isFullyMatched(id));
        assertEq(vault.openHead(), 0);
        (,, uint256 sp2,,,,,,,,, ) = vault.positions(id);
        assertEq(sp2, seniorNeed);
    }

    // ─── early cover paths ───────────────────────────────────────────────────

    function test_earlyExitSellSharesWhenNoFees() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 id = _openMatched();
        vm.warp(block.timestamp + 30 minutes);

        LeveredLpVault.EarlyExitResult memory preview =
            vault.previewEarlyExit(id, LeveredLpVault.CoverMode.SellShares);
        assertGt(preview.accrual, 0);
        assertEq(preview.seniorFloor, 0);
        assertGt(preview.mstrSold, 0);

        vm.prank(junior);
        LeveredLpVault.EarlyExitResult memory result =
            vault.earlyExit(id, LeveredLpVault.CoverMode.SellShares);
        assertEq(result.mstrSold, preview.mstrSold);
        assertEq(mstr.balanceOf(junior), MSTR_IN - result.mstrSold);

        vm.prank(senior);
        vault.withdrawSenior(seniorNeed);
        assertApproxEqAbs(mstr.balanceOf(senior), result.mstrSold, 1_000);
        assertApproxEqAbs(usdg.balanceOf(senior), seniorNeed, 1_000);
    }

    function test_earlyExitWalletCover() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 id = _openMatched();
        vm.warp(block.timestamp + 30 minutes);

        LeveredLpVault.EarlyExitResult memory preview =
            vault.previewEarlyExit(id, LeveredLpVault.CoverMode.Wallet);
        assertGt(preview.coverUsdg, 0);

        usdg.mint(junior, preview.coverUsdg);
        vm.startPrank(junior);
        usdg.approve(address(vault), preview.coverUsdg);
        LeveredLpVault.EarlyExitResult memory result = vault.earlyExit(id, LeveredLpVault.CoverMode.Wallet);
        vm.stopPrank();

        assertEq(result.mstrSold, 0);
        assertEq(mstr.balanceOf(junior), MSTR_IN);
        assertEq(vault.backstop(), result.treasuryOnCover);

        vm.prank(senior);
        vault.withdrawSenior(seniorNeed);
        assertApproxEqAbs(usdg.balanceOf(senior), seniorNeed + result.accrual, 1_000);
    }

    function test_earlyExitIdleCarryCover() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        // Match first, then junior posts idle USDG (stays free for cover).
        _depositSenior(senior, seniorNeed);
        uint256 id = _depositJunior(junior, MSTR_IN);
        uint256 idle = 50 ether;
        _depositSenior(junior, idle);
        assertEq(vault.freeSenior(), idle);
        assertEq(vault.seniorPrincipal(junior), idle);

        vm.warp(block.timestamp + 30 minutes);
        LeveredLpVault.EarlyExitResult memory preview =
            vault.previewEarlyExit(id, LeveredLpVault.CoverMode.IdleCarry);
        assertGt(preview.coverUsdg, 0);
        assertLe(preview.coverUsdg, idle);

        uint256 juniorPrincipalBefore = vault.seniorPrincipal(junior);
        vm.prank(junior);
        vault.earlyExit(id, LeveredLpVault.CoverMode.IdleCarry);
        assertEq(mstr.balanceOf(junior), MSTR_IN);
        assertEq(vault.seniorPrincipal(junior), juniorPrincipalBefore - preview.coverUsdg);
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
        vault.settle(id);
        assertEq(uint256(vault.positionState(id)), uint256(LeveredLpVault.PositionState.Closed));
    }

    function test_boostedTreasuryTierStub() public {
        vault.setBoostStaked(junior, true);
        uint256 id = _openMatched();
        assertEq(uint256(vault.positionState(id)), uint256(LeveredLpVault.PositionState.Boosted));
        (,,,,,,,,, bool boosted,,) = vault.positions(id);
        assertTrue(boosted);

        vm.warp(block.timestamp + 30 minutes);
        uint256 gross = 10 ether;
        _payFee(id, gross);
        LeveredLpVault.WaterfallSplit memory s =
            vault.previewWaterfall(gross, vault.previewSeniorAssets(MSTR_IN), 30 minutes, true);
        LeveredLpVault.WaterfallSplit memory plain =
            vault.previewWaterfall(gross, vault.previewSeniorAssets(MSTR_IN), 30 minutes, false);
        assertLt(s.treasury, plain.treasury);
        assertEq(s.treasury, gross * vault.boostedTreasuryCutWad() / 1e18);
    }

    // ─── upgrade smoke ───────────────────────────────────────────────────────

    function test_uupsUpgradeKeepsStorage() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 id = _openMatched();
        _payFee(id, 1 ether);

        LeveredLpVaultV2 v2impl = new LeveredLpVaultV2();
        vault.upgradeToAndCall(address(v2impl), "");

        LeveredLpVaultV2 upgraded = LeveredLpVaultV2(address(vault));
        assertEq(upgraded.version(), "v2.1-maker-fixes");
        assertEq(upgraded.reservedSenior(), seniorNeed);
        assertEq(upgraded.morphoRateWad(), MORPHO);
        (,,,,, uint256 feeUsdg,,,,,,) = upgraded.positions(id);
        assertEq(feeUsdg, 1 ether);
        assertEq(upgraded.owner(), address(this));

        // Non-owner cannot upgrade
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        upgraded.upgradeToAndCall(impl, "");
    }

    // ─── Maker bugfixes ──────────────────────────────────────────────────────

    /// @notice 1-wei fee claim must not drop unpaid senior accrual when lastFeeSplitAt resets.
    function test_claimFees_unpaidAccrualCarries_oneWeiGrief() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 id = _openMatched();
        vm.warp(block.timestamp + 30 minutes);

        uint256 accrual = vault.previewSeniorAccrual(seniorNeed, 30 minutes);
        assertGt(accrual, 1);

        _payFee(id, 1); // 1 wei grief
        vm.prank(junior);
        LeveredLpVault.ClaimFeesResult memory first = vault.claimFees(id);
        assertEq(first.seniorFloor, 1);
        assertEq(first.accrual, accrual);

        (,,,,,,,,, , uint256 unpaid,) = vault.positions(id);
        assertEq(unpaid, accrual - 1);

        // Later claim with fat fees pays the carried unpaid gap.
        vm.warp(block.timestamp + 1 minutes);
        uint256 more = vault.previewSeniorAccrual(seniorNeed, 1 minutes);
        uint256 gross2 = unpaid + more + 1 ether;
        _payFee(id, gross2);
        LeveredLpVault.ClaimFeesResult memory preview = vault.previewClaimFees(id);
        assertEq(preview.accrual, unpaid + more);
        assertEq(preview.seniorFloor, unpaid + more);

        vm.prank(junior);
        vault.claimFees(id);
        (,,,,,,,,, , uint256 unpaidAfter,) = vault.positions(id);
        assertEq(unpaidAfter, 0);
    }

    /// @notice Settle never sells junior MSTR; shortfall comes from backstop only.
    function test_settle_doesNotSellJuniorMstr() public {
        uint256 id = _openMatched();
        // No fees → full accrual shortfall at maturity.
        vm.warp(block.timestamp + 1 hours);
        uint256 juniorMstrBefore = mstr.balanceOf(junior);

        LeveredLpVault.Settlement memory settlement = vault.settle(id);
        assertEq(settlement.mstrSold, 0);
        assertEq(settlement.mstrKept, MSTR_IN);
        assertEq(mstr.balanceOf(junior), juniorMstrBefore + MSTR_IN);
        assertGt(settlement.accrual, 0);
        assertEq(settlement.seniorFloor, 0);
        // Without backstop funding, shortfall remains unpaid.
        assertEq(settlement.feeShortfallUsdg, settlement.accrual - settlement.fromBackstop);
    }

    function test_settle_shortfallFromBackstopOnly() public {
        uint256 id = _openMatched();
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        vm.warp(block.timestamp + 1 hours);
        uint256 accrual = vault.previewSeniorAccrual(seniorNeed, 1 hours);
        usdg.mint(donor, accrual);
        vm.startPrank(donor);
        usdg.approve(address(vault), accrual);
        vault.fundBackstop(accrual);
        vm.stopPrank();

        LeveredLpVault.Settlement memory settlement = vault.settle(id);
        assertEq(settlement.mstrSold, 0);
        assertEq(settlement.mstrKept, MSTR_IN);
        assertEq(settlement.fromBackstop, accrual);
        assertEq(settlement.feeShortfallUsdg, 0);
        assertEq(mstr.balanceOf(junior), MSTR_IN);
    }

    /// @notice Rate hike after open must not change locked accrual for that position.
    function test_morphoRateLockedAtMatch_notRetroactive() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 id = _openMatched();
        (,,,,,,,,,, , uint256 locked) = vault.positions(id);
        assertEq(locked, MORPHO);

        vault.setMorphoRate(0.05e18);
        assertEq(vault.morphoRateWad(), 0.05e18);

        vm.warp(block.timestamp + 30 minutes);
        uint256 expected = seniorNeed * MORPHO * 30 minutes / (1e18 * 365 days);
        LeveredLpVault.EarlyExitResult memory preview =
            vault.previewEarlyExit(id, LeveredLpVault.CoverMode.SellShares);
        assertEq(preview.accrual, expected);
        assertLt(preview.accrual, seniorNeed * 0.05e18 * 30 minutes / (1e18 * 365 days));
    }

    /// @notice Partial match mid-term must not backdate new principal; no match after term.
    function test_partialMatch_accrualNotBackdated_andNoMatchAfterTerm() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 half = seniorNeed / 2;
        _depositSenior(senior, half);
        uint256 id = _depositJunior(junior, MSTR_IN);
        assertTrue(vault.isMatched(id));
        assertFalse(vault.isFullyMatched(id));

        vm.warp(block.timestamp + 30 minutes);
        uint256 unpaidBefore = half * MORPHO * 30 minutes / (1e18 * 365 days);

        _depositSenior(senior2, seniorNeed - half);
        assertTrue(vault.isFullyMatched(id));
        (,,,,,,,,, , uint256 unpaid, ) = vault.positions(id);
        assertEq(unpaid, unpaidBefore);

        // Immediately after top-up, only banked unpaid accrues (no elapsed on full principal).
        LeveredLpVault.EarlyExitResult memory preview =
            vault.previewEarlyExit(id, LeveredLpVault.CoverMode.Wallet);
        assertEq(preview.accrual, unpaidBefore);

        // After term: further senior deposits must not match a new partial on a matured book.
        // Open a fresh partial that starts, wait past term, then try to finish — residual stays unmatched.
        uint256 id2 = _depositJunior(junior, MSTR_IN);
        _depositSenior(senior, half);
        assertTrue(vault.isMatched(id2));
        assertFalse(vault.isFullyMatched(id2));
        vm.warp(block.timestamp + 1 hours); // term elapsed
        uint256 freeBefore = vault.freeSenior();
        _depositSenior(senior2, seniorNeed); // plenty of idle
        assertFalse(vault.isFullyMatched(id2));
        (,, uint256 sp2,,,,,,,,, ) = vault.positions(id2);
        assertEq(sp2, half); // no post-term match
        assertGe(vault.freeSenior(), freeBefore);
    }

    function test_lenderReplaceUnlocksExit() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        _depositSenior(senior, seniorNeed);
        _depositJunior(junior, MSTR_IN);
        assertEq(vault.freePrincipal(senior), 0);

        _depositSenior(senior2, seniorNeed);
        uint256 free = vault.freePrincipal(senior);
        assertGt(free, 0);
        vm.prank(senior);
        vault.withdrawSenior(free);
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

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
}
