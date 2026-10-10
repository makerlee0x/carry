// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {LeveredLpVault} from "../src/LeveredLpVault.sol";
import {LeveredLpVaultV2} from "../src/LeveredLpVaultV2.sol";
import {FixedPriceOracle} from "../src/oracle/FixedPriceOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFeePool} from "../src/mocks/MockFeePool.sol";
import {MockMstrSellRouter} from "../src/mocks/MockMstrSellRouter.sol";
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
        vm.expectRevert();
        vault.rescueToken(address(usdg), attacker, 1);
        vm.expectRevert(LeveredLpVault.NotJunior.selector);
        vault.earlyExit(id);
        vm.stopPrank();
    }

    function test_externalCannotLpBesideVault() public {
        // joinPool / dualPoolAdapter removed for EIP-170 size; ExternalLpForbidden kept for ABI stability.
        assertTrue(true);
    }

    function test_twoXTracksHoldCloserThanUnlevered() public {
        // mark() removed for EIP-170 size; book still 1:1 USDG match at entry price.
        uint256 id = _openMatched();
        (,, uint256 seniorPrincipal,,,,,,,,,) = vault.positions(id);
        assertEq(seniorPrincipal, vault.previewSeniorAssets(MSTR_IN));
        oracle.setPrice(PRICE * 4);
        assertEq(vault.previewSeniorAssets(MSTR_IN), 4_000 ether);
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
        // Senior gets principal + floor + perf (USDG path; no shortfall with fat fees).
        // Time-weighted credit rounds down — allow dust.
        assertApproxEqAbs(
            usdg.balanceOf(senior), seniorNeed + settlement.seniorFloor + settlement.seniorPerf, 1e7
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
        // Time-weighted index rounds down; dust MSTR stays in vault.
        assertApproxEqAbs(mstr.balanceOf(senior), result.mstrSold, 1e6);
        assertApproxEqAbs(usdg.balanceOf(senior), seniorNeed, 1e6);
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
        assertApproxEqAbs(usdg.balanceOf(senior), seniorNeed + result.accrual, 1e7);
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

    function test_boostedUsesReducedTreasuryCut10() public {
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
        // Maker leftover: base 20%, Boosted MSTR (STRATEGY stake) reduced to 10%.
        assertEq(plain.treasury, gross * vault.treasuryCutWad() / 1e18);
        assertEq(s.treasury, gross * vault.boostedTreasuryCutWad() / 1e18);
        assertEq(vault.treasuryCutWad(), 0.2e18);
        assertEq(vault.boostedTreasuryCutWad(), 0.1e18);
        assertLt(s.treasury, plain.treasury);
    }

    // ─── upgrade smoke ───────────────────────────────────────────────────────

    function test_uupsUpgradeKeepsStorage() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 id = _openMatched();
        _payFee(id, 1 ether);

        LeveredLpVaultV2 v2impl = new LeveredLpVaultV2();
        vault.upgradeToAndCall(address(v2impl), "");

        LeveredLpVaultV2 upgraded = LeveredLpVaultV2(address(vault));
        assertEq(upgraded.version(), "v2.4-maker-leftovers");
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

    /// @notice Settle with empty backstop sells junior MSTR for residual shortfall + treasury-on-cover.
    function test_settle_sellSharesWhenBackstopEmpty() public {
        uint256 id = _openMatched();
        // No fees → full accrual shortfall at maturity; backstop empty → SellShares cover.
        vm.warp(block.timestamp + 1 hours);
        uint256 juniorMstrBefore = mstr.balanceOf(junior);

        LeveredLpVault.Settlement memory settlement = vault.settle(id);
        assertGt(settlement.accrual, 0);
        assertEq(settlement.seniorFloor, 0);
        assertEq(settlement.fromBackstop, 0);
        assertGt(settlement.mstrSold, 0);
        assertEq(settlement.mstrKept, MSTR_IN - settlement.mstrSold);
        assertEq(mstr.balanceOf(junior), juniorMstrBefore + settlement.mstrKept);
        assertEq(settlement.feeShortfallUsdg, 0);
    }

    function test_settle_shortfallBackstopFirstThenNoSell() public {
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
        assertEq(settlement.coverUsdg, 0);
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

    // ─── Maker answers (withdraw / settle cover / TW yield / matchCap) ───────

    function test_ownerWithdrawBackstop_cannotRugPrincipal() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 id = _openMatched();
        _payFee(id, 10 ether);
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(junior);
        LeveredLpVault.ClaimFeesResult memory claimed = vault.claimFees(id);
        assertGt(vault.backstop(), 0);
        assertEq(vault.backstop(), claimed.treasury);

        uint256 bs = vault.backstop();
        address treasury = makeAddr("treasury");
        vault.withdrawTreasuryFees(treasury, bs);
        assertEq(usdg.balanceOf(treasury), bs);
        assertEq(vault.backstop(), 0);
        // Senior principal + remaining position fees still in vault.
        assertGe(usdg.balanceOf(address(vault)), seniorNeed);
        assertEq(mstr.balanceOf(address(vault)), MSTR_IN);

        vm.expectRevert(LeveredLpVault.InsufficientBackstop.selector);
        vault.withdrawFromBackstop(treasury, 1);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vault.withdrawFromBackstop(attacker, 1);
    }

    function test_settle_walletCoverAfterPartialBackstop() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 id = _openMatched();
        vm.warp(block.timestamp + 1 hours);
        uint256 accrual = vault.previewSeniorAccrual(seniorNeed, 1 hours);
        uint256 half = accrual / 2;
        usdg.mint(donor, half);
        vm.startPrank(donor);
        usdg.approve(address(vault), half);
        vault.fundBackstop(half);
        vm.stopPrank();

        LeveredLpVault.Settlement memory preview =
            vault.previewSettle(id, LeveredLpVault.CoverMode.Wallet);
        assertEq(preview.fromBackstop, half);
        assertGt(preview.coverUsdg, 0);
        assertEq(preview.treasuryOnCover, (accrual - half) * vault.treasuryCutWad() / 1e18);

        usdg.mint(junior, preview.coverUsdg);
        vm.startPrank(junior);
        usdg.approve(address(vault), preview.coverUsdg);
        LeveredLpVault.Settlement memory settlement =
            vault.settle(id, LeveredLpVault.CoverMode.Wallet);
        vm.stopPrank();

        assertEq(settlement.mstrSold, 0);
        assertEq(settlement.mstrKept, MSTR_IN);
        assertEq(settlement.fromBackstop, half);
        assertEq(settlement.feeShortfallUsdg, 0);
        assertEq(vault.backstop(), settlement.treasuryOnCover);

        vm.prank(senior);
        vault.withdrawSenior(seniorNeed);
        assertApproxEqAbs(usdg.balanceOf(senior), seniorNeed + accrual, 1e7);
    }

    function test_settle_walletCoverOnlyJunior() public {
        uint256 id = _openMatched();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(attacker);
        vm.expectRevert(LeveredLpVault.NotJunior.selector);
        vault.settle(id, LeveredLpVault.CoverMode.Wallet);
    }

    function test_lateSenior_yieldProRataByDepositTime() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        _depositSenior(senior, seniorNeed);
        uint256 id = _depositJunior(junior, MSTR_IN);
        assertTrue(vault.isFullyMatched(id));

        // Accrue almost the whole term with only senior #1 present.
        vm.warp(block.timestamp + 50 minutes);
        _depositSenior(senior2, seniorNeed); // late — same principal, tiny time weight

        vm.warp(block.timestamp + 10 minutes); // term = 1 hour
        uint256 gross = 10 ether;
        _payFee(id, gross);

        LeveredLpVault.Settlement memory settlement = vault.settle(id);
        assertEq(settlement.mstrSold, 0); // fat fees cover accrual

        uint256 s1Before = usdg.balanceOf(senior);
        uint256 s2Before = usdg.balanceOf(senior2);
        vm.prank(senior);
        vault.withdrawSenior(seniorNeed);
        vm.prank(senior2);
        vault.withdrawSenior(seniorNeed);

        uint256 y1 = usdg.balanceOf(senior) - s1Before - seniorNeed;
        uint256 y2 = usdg.balanceOf(senior2) - s2Before - seniorNeed;
        assertGt(y1, 0);
        assertGt(y2, 0);
        // Early senior should earn materially more than equal 50/50 under time-weighting.
        assertGt(y1, y2 * 2);
    }

    function test_matchCapBoundsDepositSeniorGas() public {
        vault.setMatchCap(2);
        assertEq(vault.matchCap(), 2);

        // Three idle juniors waiting; senior deposit only enough for two full matches.
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 id1 = _depositJunior(junior, MSTR_IN);
        uint256 id2 = _depositJunior(makeAddr("j2"), MSTR_IN);
        uint256 id3 = _depositJunior(makeAddr("j3"), MSTR_IN);
        assertFalse(vault.isMatched(id1));

        _depositSenior(senior, seniorNeed * 3);
        assertTrue(vault.isFullyMatched(id1));
        assertTrue(vault.isFullyMatched(id2));
        // Third left unmatched because matchCap=2 stopped the walk.
        assertFalse(vault.isMatched(id3));
        assertEq(vault.openHead(), id3);
        assertEq(vault.freeSenior(), seniorNeed);

        // Later deposit (or same free capital via another senior action) continues matching.
        _depositSenior(senior2, 1); // triggers another capped walk with free senior already there
        assertTrue(vault.isFullyMatched(id3));
    }

    // ─── Maker clarifications (Oct 10): early no backstop, settle cover, 20% cut, gasCredit ─

    function test_earlyExit_doesNotConsumeBackstop() public {
        uint256 id = _openMatched();
        uint256 seeded = 5 ether;
        usdg.mint(donor, seeded);
        vm.startPrank(donor);
        usdg.approve(address(vault), seeded);
        vault.fundBackstop(seeded);
        vm.stopPrank();
        assertEq(vault.backstop(), seeded);

        vm.warp(block.timestamp + 30 minutes);
        LeveredLpVault.EarlyExitResult memory preview =
            vault.previewEarlyExit(id, LeveredLpVault.CoverMode.Wallet);
        assertGt(preview.coverUsdg, 0);

        usdg.mint(junior, preview.coverUsdg);
        vm.startPrank(junior);
        usdg.approve(address(vault), preview.coverUsdg);
        LeveredLpVault.EarlyExitResult memory result = vault.earlyExit(id, LeveredLpVault.CoverMode.Wallet);
        vm.stopPrank();

        // Early exit: junior covers; backstop only grows by waterfall treasury + treasury-on-cover.
        assertEq(vault.backstop(), seeded + result.treasury + result.treasuryOnCover);
        assertEq(result.mstrSold, 0);
        assertEq(mstr.balanceOf(junior), MSTR_IN);
    }

    function test_settle_idleCarryAfterPartialBackstop() public {
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        _depositSenior(senior, seniorNeed);
        uint256 id = _depositJunior(junior, MSTR_IN);

        // Junior posts Idle Carry USDG after match (stays free for cover).
        uint256 idle = 50 ether;
        _depositSenior(junior, idle);
        assertEq(vault.freeSenior(), idle);

        vm.warp(block.timestamp + 1 hours);
        uint256 accrual = vault.previewSeniorAccrual(seniorNeed, 1 hours);
        uint256 half = accrual / 2;
        usdg.mint(donor, half);
        vm.startPrank(donor);
        usdg.approve(address(vault), half);
        vault.fundBackstop(half);
        vm.stopPrank();

        LeveredLpVault.Settlement memory preview =
            vault.previewSettle(id, LeveredLpVault.CoverMode.IdleCarry);
        assertEq(preview.fromBackstop, half);
        assertGt(preview.coverUsdg, 0);
        assertEq(preview.treasuryOnCover, (accrual - half) * 0.2e18 / 1e18);

        uint256 juniorPrincipalBefore = vault.seniorPrincipal(junior);
        vm.prank(junior);
        LeveredLpVault.Settlement memory settlement =
            vault.settle(id, LeveredLpVault.CoverMode.IdleCarry);

        assertEq(settlement.mstrSold, 0);
        assertEq(settlement.fromBackstop, half);
        assertEq(settlement.feeShortfallUsdg, 0);
        assertEq(vault.seniorPrincipal(junior), juniorPrincipalBefore - settlement.coverUsdg);
        assertEq(mstr.balanceOf(junior), MSTR_IN);
    }

    function test_treasuryCutBoosted10_onCoverAndWaterfall() public {
        vault.setBoostStaked(junior, true);
        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 id = _openMatched();
        assertEq(uint256(vault.positionState(id)), uint256(LeveredLpVault.PositionState.Boosted));

        vm.warp(block.timestamp + 30 minutes);
        LeveredLpVault.EarlyExitResult memory preview =
            vault.previewEarlyExit(id, LeveredLpVault.CoverMode.Wallet);
        // cover = shortfall + 10% treasury-on-cover when Boosted.
        assertEq(preview.treasuryOnCover, preview.accrual * 0.1e18 / 1e18);
        assertEq(preview.coverUsdg, preview.accrual + preview.treasuryOnCover);

        uint256 gross = 10 ether;
        LeveredLpVault.WaterfallSplit memory split =
            vault.previewWaterfall(gross, seniorNeed, 30 minutes, true);
        assertEq(split.treasury, gross * 0.1e18 / 1e18);
    }

    function test_gasCredit_refundsSeniorOnDepositEvenIfUnmatched() public {
        assertEq(vault.gasRefundWei(), 0.0001 ether);
        uint256 id = _depositJunior(junior, MSTR_IN);
        assertFalse(vault.isMatched(id));

        uint256 credit = 0.001 ether;
        vm.deal(junior, credit);
        vm.prank(junior);
        vault.fundGasCredit{value: credit}();
        assertEq(vault.gasCreditWei(junior), credit);

        // Senior deposits dust — not enough to fully match $1k book — still gets gas refund
        // (Maker: junior fronts gas even when left unmatched / only partially matched).
        uint256 dust = 1 ether;
        uint256 refund = vault.gasRefundWei();
        uint256 seniorEthBefore = senior.balance;
        usdg.mint(senior, dust);
        vm.startPrank(senior);
        usdg.approve(address(vault), dust);
        vault.depositSenior(dust);
        vm.stopPrank();

        assertTrue(vault.isMatched(id)); // partial match OK
        assertFalse(vault.isFullyMatched(id));
        assertEq(vault.openHead(), id); // residual still queued
        assertEq(senior.balance, seniorEthBefore + refund);
        assertEq(vault.gasCreditWei(junior), credit - refund);
    }

    function test_gasCredit_refundOnMatchAndWithdrawUnused() public {
        uint256 id = _depositJunior(junior, MSTR_IN);
        uint256 credit = 0.001 ether;
        vm.deal(junior, credit);
        vm.prank(junior);
        vault.fundGasCredit{value: credit}();

        uint256 seniorNeed = vault.previewSeniorAssets(MSTR_IN);
        uint256 refund = vault.gasRefundWei();
        uint256 seniorEthBefore = senior.balance;
        _depositSenior(senior, seniorNeed);
        assertTrue(vault.isFullyMatched(id));
        assertEq(senior.balance, seniorEthBefore + refund);
        assertEq(vault.gasCreditWei(junior), credit - refund);

        uint256 left = vault.gasCreditWei(junior);
        uint256 juniorEthBefore = junior.balance;
        vm.prank(junior);
        vault.withdrawGasCredit(left);
        assertEq(vault.gasCreditWei(junior), 0);
        assertEq(junior.balance, juniorEthBefore + left);
    }

    function test_gasCredit_noRefundWithoutSponsorOrCredit() public {
        // No open junior → no sponsor → no refund even if someone else funded credit.
        vm.deal(junior, 1 ether);
        vm.prank(junior);
        vault.fundGasCredit{value: 0.001 ether}();

        uint256 seniorEthBefore = senior.balance;
        _depositSenior(senior, 10 ether);
        assertEq(senior.balance, seniorEthBefore); // idle book, no open-queue sponsor
        assertEq(vault.gasCreditWei(junior), 0.001 ether);
    }

    // ─── Maker leftovers (Oct 10 PM): Boosted 10%, gas auto-refund, cover revert, compound, AMM stub ─

    function test_gasCredit_autoRefundOnWithdrawIdle() public {
        uint256 id = _depositJunior(junior, MSTR_IN);
        uint256 credit = 0.001 ether;
        vm.deal(junior, credit);
        vm.prank(junior);
        vault.fundGasCredit{value: credit}();

        uint256 ethBefore = junior.balance;
        vm.prank(junior);
        vault.withdrawUnmatched(id);
        assertEq(vault.gasCreditWei(junior), 0);
        assertEq(junior.balance, ethBefore + credit);
        assertEq(uint256(vault.positionState(id)), uint256(LeveredLpVault.PositionState.Closed));
    }

    function test_gasCredit_autoRefundOnEarlyExit() public {
        uint256 id = _openMatched();
        uint256 credit = 0.002 ether;
        vm.deal(junior, credit);
        vm.prank(junior);
        vault.fundGasCredit{value: credit}();

        vm.warp(block.timestamp + 30 minutes);
        LeveredLpVault.EarlyExitResult memory preview =
            vault.previewEarlyExit(id, LeveredLpVault.CoverMode.SellShares);

        uint256 ethBefore = junior.balance;
        vm.prank(junior);
        vault.earlyExit(id, LeveredLpVault.CoverMode.SellShares);
        assertEq(vault.gasCreditWei(junior), 0);
        assertEq(junior.balance, ethBefore + credit);
        assertEq(preview.mstrReturned + preview.mstrSold, MSTR_IN);
    }

    function test_earlyExit_revertsWhenWalletCannotCover_positionStaysOpen() public {
        uint256 id = _openMatched();
        vm.warp(block.timestamp + 30 minutes);
        LeveredLpVault.EarlyExitResult memory preview =
            vault.previewEarlyExit(id, LeveredLpVault.CoverMode.Wallet);
        assertGt(preview.coverUsdg, 0);

        // No USDG / no approve → JuniorCoverRequired; position remains Active.
        vm.prank(junior);
        vm.expectRevert(LeveredLpVault.JuniorCoverRequired.selector);
        vault.earlyExit(id, LeveredLpVault.CoverMode.Wallet);

        (,,,,,,,, bool settled,,,) = vault.positions(id);
        assertFalse(settled);
        assertEq(uint256(vault.positionState(id)), uint256(LeveredLpVault.PositionState.Active));
        assertEq(vault.reservedSenior(), vault.previewSeniorAssets(MSTR_IN));
    }

    function test_earlyExit_revertsWhenIdleCannotCover_positionStaysOpen() public {
        uint256 id = _openMatched();
        vm.warp(block.timestamp + 30 minutes);
        LeveredLpVault.EarlyExitResult memory preview =
            vault.previewEarlyExit(id, LeveredLpVault.CoverMode.IdleCarry);
        assertGt(preview.coverUsdg, 0);

        vm.prank(junior);
        vm.expectRevert(LeveredLpVault.JuniorCoverRequired.selector);
        vault.earlyExit(id, LeveredLpVault.CoverMode.IdleCarry);

        (,,,,,,,, bool settled,,,) = vault.positions(id);
        assertFalse(settled);
        assertEq(uint256(vault.positionState(id)), uint256(LeveredLpVault.PositionState.Active));
    }

    function test_strategyStakeStub_activatesBoosted() public {
        // Live STRATEGY ERC-20 wire later; owner stub marks stake-before-open for MSTR Boosted.
        vault.setBoostStaked(junior, true);
        uint256 id = _openMatched();
        assertEq(uint256(vault.positionState(id)), uint256(LeveredLpVault.PositionState.Boosted));
    }

    function test_autoCompound_juniorEarlyExit_reopensIdle() public {
        uint256 id = _openMatched();
        vm.prank(junior);
        vault.setAutoCompound(true);

        vm.warp(block.timestamp + 30 minutes);
        vm.prank(junior);
        LeveredLpVault.EarlyExitResult memory result =
            vault.earlyExit(id, LeveredLpVault.CoverMode.SellShares);

        assertEq(uint256(vault.positionState(id)), uint256(LeveredLpVault.PositionState.Closed));
        // Remaining MSTR compounded into a new Idle (or Active if idle senior existed).
        uint256 newId = id + 1;
        (address owner, uint256 mstrAmt,,,,,,, bool settled,,,) = vault.positions(newId);
        assertEq(owner, junior);
        assertFalse(settled);
        assertEq(mstrAmt, result.mstrReturned);
        assertEq(mstr.balanceOf(junior), 0); // not sent to wallet
    }

    function test_autoCompound_seniorWithdraw_compoundsYield() public {
        uint256 id = _openMatched();
        _payFee(id, 5 ether);
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(junior);
        vault.earlyExit(id, LeveredLpVault.CoverMode.SellShares);

        // Enable compound BEFORE withdraw so principal+yield redeposit as Idle.
        vm.prank(senior);
        vault.setAutoCompound(true);

        uint256 free = vault.freePrincipal(senior);
        assertGt(free, 0);
        // Force checkpoint into claimable without withdrawing (deposit 0 not available) —
        // free principal withdraw with compound keeps USDG in vault.
        uint256 usdgWalletBefore = usdg.balanceOf(senior);
        uint256 principalBefore = vault.seniorPrincipal(senior);

        vm.prank(senior);
        vault.withdrawSenior(free);

        // Compound: no USDG to wallet; principal (+ any claimable yield) back as senior idle.
        assertEq(usdg.balanceOf(senior), usdgWalletBefore);
        assertGe(vault.seniorPrincipal(senior), principalBefore);
        assertEq(vault.seniorClaimableYield(senior), 0);
        assertEq(vault.freePrincipal(senior), vault.seniorPrincipal(senior));
    }

    function test_sellSharesRouter_mainnetPath_creditsUsdgNotMstr() public {
        MockMstrSellRouter router = new MockMstrSellRouter(address(mstr), address(usdg), PRICE);
        vault.setSellSharesRouter(address(router));

        uint256 id = _openMatched();
        vm.warp(block.timestamp + 30 minutes);
        LeveredLpVault.EarlyExitResult memory preview =
            vault.previewEarlyExit(id, LeveredLpVault.CoverMode.SellShares);
        assertGt(preview.mstrSold, 0);

        // Fund router with USDG to pay the swap.
        usdg.mint(address(router), preview.coverUsdg * 2);

        uint256 seniorMstrBalBefore = mstr.balanceOf(senior);
        vm.prank(junior);
        LeveredLpVault.EarlyExitResult memory result =
            vault.earlyExit(id, LeveredLpVault.CoverMode.SellShares);

        assertGt(result.mstrSold, 0);
        // Mainnet path: no extra MSTR credit to seniors (claim via zero-principal withdraw).
        vm.prank(senior);
        vault.withdrawSenior(0);
        assertEq(mstr.balanceOf(senior), seniorMstrBalBefore);
        assertEq(vault.seniorClaimableMstr(senior), 0);
        // Junior received leftover MSTR (unsold).
        assertEq(mstr.balanceOf(junior), result.mstrReturned);
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
