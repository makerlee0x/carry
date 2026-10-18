// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LeveredLpVault} from "../../src/LeveredLpVault.sol";
import {LeveredLpVaultV2} from "../../src/LeveredLpVaultV2.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockOracle} from "../../src/mocks/MockOracle.sol";

/// @notice Shared fixture for integration + invariant suites.
///         Deploys the vault the way production does (UUPS proxy, 7-day term, 3.9% Morpho stub,
///         uncapped senior, $25k junior) and exposes "books" checks that every scenario runs.
///
///         Books (must hold after every state change):
///         1. USDG solvency: vault USDG balance >= totalSeniorAssets + backstop + totalUnsplitFees.
///         2. No stranded USDG: balance - liabilities <= DUST. USDG the vault holds but owes to nobody
///            means someone paid in and the credit was dropped.
///         3. MSTR: vault MSTR balance == sum of open positions' mstrAmount.
///         4. reservedSenior == sum of open positions' seniorPrincipal.
///         5. totalShares == sum of holders' shares.
///         6. Queue: fulfilled <= requested, queueClaimable <= totalSeniorAssets.
abstract contract CarryBase is Test {
    uint64 internal constant TERM = 7 days;
    uint256 internal constant PRICE = 100 ether; // 1 MSTR = 100 USDG
    uint256 internal constant MORPHO = 0.039e18;
    uint256 internal constant JUNIOR_CAP = 25_000 ether;
    /// @dev Rounding tolerance for "stranded" USDG (1e-12 USDG).
    uint256 internal constant DUST = 1e6;

    MockERC20 internal mstr;
    MockERC20 internal usdg;
    MockOracle internal oracle;
    LeveredLpVault internal vault;

    address internal owner = address(this);
    address internal keeper = makeAddr("keeper");

    address[] internal holders;

    function setUp() public virtual {
        vm.warp(1_760_000_000);
        mstr = new MockERC20("Mock MSTR", "MSTR", 18);
        usdg = new MockERC20("Mock USDG", "USDG", 18);
        oracle = new MockOracle(PRICE);

        LeveredLpVaultV2 impl = new LeveredLpVaultV2();
        bytes memory initData = abi.encodeCall(
            LeveredLpVault.initialize, (address(mstr), address(usdg), address(oracle), TERM, MORPHO, owner)
        );
        vault = LeveredLpVault(address(new ERC1967Proxy(address(impl), initData)));
        vault.unpause();
        vault.setDepositCaps(0, JUNIOR_CAP, 0);
    }

    // ─── actions ─────────────────────────────────────────────────────────────

    function _track(address who) internal {
        for (uint256 i; i < holders.length; ++i) {
            if (holders[i] == who) return;
        }
        holders.push(who);
    }

    function _lend(address who, uint256 amount) internal {
        _track(who);
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(vault), amount);
        vault.depositSenior(amount);
        vm.stopPrank();
    }

    function _stake(address who, uint256 mstrAmount) internal returns (uint256 id) {
        _track(who);
        mstr.mint(who, mstrAmount);
        vm.startPrank(who);
        mstr.approve(address(vault), mstrAmount);
        id = vault.depositJunior(mstrAmount);
        vm.stopPrank();
    }

    /// @dev Simulated LP fee (testnet path: accrueLpFee from a fee source).
    function _fees(uint256 id, uint256 amount) internal {
        usdg.mint(address(this), amount);
        usdg.approve(address(vault), amount);
        vault.accrueLpFee(id, amount);
    }

    function _fundBackstop(uint256 amount) internal {
        usdg.mint(address(this), amount);
        usdg.approve(address(vault), amount);
        vault.fundBackstop(amount);
    }

    function _giveUsdg(address who, uint256 amount) internal {
        usdg.mint(who, amount);
        vm.prank(who);
        usdg.approve(address(vault), type(uint256).max);
    }

    function _warpToMaturity(uint256 id) internal {
        (,,,,,, uint64 openedAt,,,,,,) = vault.positions(id);
        vm.warp(uint256(openedAt) + TERM + 1);
    }

    function _withdrawAll(address who) internal returns (uint256 assets) {
        assets = vault.convertToAssets(vault.shares(who));
        if (assets == 0) return 0;
        vm.prank(who);
        vault.withdrawSenior(assets);
    }

    // ─── views ───────────────────────────────────────────────────────────────

    function _lenderAssets(address who) internal view returns (uint256) {
        return vault.convertToAssets(vault.shares(who));
    }

    function _usdgLiabilities() internal view returns (uint256) {
        return vault.totalSeniorAssets() + vault.backstop() + vault.totalUnsplitFees();
    }

    // ─── books ───────────────────────────────────────────────────────────────

    function _assertUsdgBooks(string memory ctx) internal view {
        uint256 bal = usdg.balanceOf(address(vault));
        uint256 liab = _usdgLiabilities();
        assertGe(bal, liab, string.concat("INSOLVENT [", ctx, "]: vault owes more USDG than it holds"));
        assertLe(bal - liab, DUST, string.concat("STRANDED USDG [", ctx, "]: vault holds USDG owed to nobody"));
    }

    function _assertMstrBooks(string memory ctx) internal view {
        uint256 sum;
        uint256 n = vault.nextPositionId();
        for (uint256 id = 1; id < n; ++id) {
            (, uint256 amt,,,,,,, bool settled,,,,) = vault.positions(id);
            if (!settled) sum += amt;
        }
        assertEq(mstr.balanceOf(address(vault)), sum, string.concat("MSTR books [", ctx, "]: balance != open positions"));
    }

    function _assertPositionBooks(string memory ctx) internal view {
        uint256 sum;
        uint256 n = vault.nextPositionId();
        for (uint256 id = 1; id < n; ++id) {
            (,, uint256 principal,,,,,, bool settled,,,,) = vault.positions(id);
            if (!settled) sum += principal;
        }
        assertEq(vault.reservedSenior(), sum, string.concat("reservedSenior [", ctx, "] != sum open seniorPrincipal"));
    }

    function _assertShareBooks(string memory ctx) internal view {
        uint256 sum;
        for (uint256 i; i < holders.length; ++i) {
            sum += vault.shares(holders[i]);
        }
        assertEq(vault.totalShares(), sum, string.concat("totalShares [", ctx, "] != sum of holder shares"));
    }

    function _assertQueueBooks(string memory ctx) internal view {
        assertLe(
            vault.wqCumulativeFulfilled(), vault.wqCumulativeRequested(), string.concat("queue [", ctx, "] overfilled")
        );
        assertLe(vault.queueClaimable(), vault.totalSeniorAssets(), string.concat("queue [", ctx, "] claimable > pool"));
    }

    function _assertBooks(string memory ctx) internal view {
        _assertUsdgBooks(ctx);
        _assertMstrBooks(ctx);
        _assertPositionBooks(ctx);
        _assertShareBooks(ctx);
        _assertQueueBooks(ctx);
    }
}
