// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {LeveredLpVault} from "../../src/LeveredLpVault.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Random-walk driver for the invariant suite. Lenders and juniors are separate wallets
///         so lender principal can be tracked exactly (juniors never hold pool shares here).
///         Calls that revert are expected (wrong state, caps); the handler swallows them.
contract CarryHandler is Test {
    LeveredLpVault internal vault;
    MockERC20 internal mstr;
    MockERC20 internal usdg;

    address[] public lenders;
    address[] public juniors;
    address internal feeSource = makeAddr("feeSource");
    address internal keeper = makeAddr("keeper");

    /// Ghost: USDG lenders put in minus USDG they took out.
    uint256 public ghostLenderIn;
    uint256 public ghostLenderOut;

    mapping(bytes32 => uint256) public calls;

    constructor(LeveredLpVault vault_, MockERC20 mstr_, MockERC20 usdg_) {
        vault = vault_;
        mstr = mstr_;
        usdg = usdg_;
        for (uint256 i; i < 3; ++i) {
            lenders.push(makeAddr(string.concat("fuzzLender", vm.toString(i))));
            juniors.push(makeAddr(string.concat("fuzzJunior", vm.toString(i))));
        }
    }

    function lenderCount() external view returns (uint256) {
        return lenders.length;
    }

    function _lender(uint256 seed) internal view returns (address) {
        return lenders[seed % lenders.length];
    }

    function _junior(uint256 seed) internal view returns (address) {
        return juniors[seed % juniors.length];
    }

    function _position(uint256 seed) internal view returns (uint256 id, address owner_) {
        uint256 n = vault.nextPositionId();
        if (n <= 1) return (0, address(0));
        id = 1 + seed % (n - 1);
        (owner_,,,,,,,,,,,,,) = vault.positions(id);
    }

    /// @dev First open, matched position at or after `seed` (wraps). Biases the fuzzer toward live positions.
    function _active(uint256 seed) internal view returns (uint256 id, address owner_) {
        uint256 n = vault.nextPositionId();
        if (n <= 1) return (0, address(0));
        uint256 count = n - 1;
        for (uint256 k; k < count; ++k) {
            uint256 cand = 1 + (seed + k) % count;
            (address o,, uint256 principal,,,,,, bool settled,,,,,) = vault.positions(cand);
            if (!settled && principal > 0) return (cand, o);
        }
    }

    // ─── lender actions ──────────────────────────────────────────────────────

    function lend(uint256 who, uint256 amount) external {
        address l = _lender(who);
        amount = bound(amount, 25 ether, 20_000 ether);
        usdg.mint(l, amount);
        vm.startPrank(l);
        usdg.approve(address(vault), amount);
        try vault.depositSenior(amount) {
            ghostLenderIn += amount;
            calls["lend"]++;
        } catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 who, uint256 pct) external {
        address l = _lender(who);
        uint256 free = vault.freePrincipal(l);
        if (free == 0) return;
        uint256 amount = free * bound(pct, 1, 100) / 100;
        if (amount == 0) return;
        uint256 before = usdg.balanceOf(l);
        vm.prank(l);
        try vault.withdrawSenior(amount) {
            ghostLenderOut += usdg.balanceOf(l) - before;
            calls["withdraw"]++;
        } catch {}
    }

    function claim(uint256 who) external {
        address l = _lender(who);
        uint256 before = usdg.balanceOf(l);
        vm.prank(l);
        try vault.claimWithdraw() {
            ghostLenderOut += usdg.balanceOf(l) - before;
            calls["claim"]++;
        } catch {}
    }

    // ─── junior actions ──────────────────────────────────────────────────────

    function stake(uint256 who, uint256 mstrAmount) external {
        address j = _junior(who);
        mstrAmount = bound(mstrAmount, 0.25 ether, 20 ether);
        mstr.mint(j, mstrAmount);
        vm.startPrank(j);
        mstr.approve(address(vault), mstrAmount);
        try vault.depositJunior(mstrAmount) {
            calls["stake"]++;
        } catch {}
        vm.stopPrank();
    }

    function unstake(uint256 seed) external {
        (uint256 id, address o) = _position(seed);
        if (id == 0) return;
        vm.prank(o);
        try vault.withdrawUnmatched(id) {
            calls["unstake"]++;
        } catch {}
    }

    function fees(uint256 seed, uint256 amount) external {
        (uint256 id,) = _active(seed);
        if (id == 0) return;
        amount = bound(amount, 1 ether, 500 ether);
        usdg.mint(feeSource, amount);
        vm.startPrank(feeSource);
        usdg.approve(address(vault), amount);
        try vault.accrueLpFee(id, amount) {
            calls["fees"]++;
        } catch {}
        vm.stopPrank();
    }

    function claimFees(uint256 seed) external {
        (uint256 id, address o) = _active(seed);
        if (id == 0) return;
        vm.prank(o);
        try vault.claimFees(id) {
            calls["claimFees"]++;
        } catch {}
    }

    function earlyExit(uint256 seed, uint256 topUp) external {
        (uint256 id, address o) = _active(seed);
        if (id == 0) return;
        _topUp(o, topUp);
        vm.prank(o);
        try vault.earlyExit(id) {
            calls["earlyExit"]++;
        } catch {}
    }

    /// Jumps to maturity if needed (a position is only settleable after its term).
    function settle(uint256 seed, uint256 topUp, bool byKeeper) external {
        (uint256 id, address o) = _active(seed);
        if (id == 0) return;
        (,,,,,, uint64 openedAt,,,,,,,) = vault.positions(id);
        uint256 maturity = uint256(openedAt) + vault.term();
        if (block.timestamp <= maturity) vm.warp(maturity + 1);
        _topUp(o, topUp);
        vm.prank(byKeeper ? keeper : o);
        try vault.settle(id) {
            calls["settle"]++;
        } catch {}
    }

    function _topUp(address j, uint256 amount) internal {
        amount = bound(amount, 0, 200 ether);
        if (amount == 0) return;
        usdg.mint(j, amount);
        vm.prank(j);
        usdg.approve(address(vault), type(uint256).max);
    }

    // ─── environment ─────────────────────────────────────────────────────────

    function backstop(uint256 amount) external {
        amount = bound(amount, 1 ether, 100 ether);
        usdg.mint(feeSource, amount);
        vm.startPrank(feeSource);
        usdg.approve(address(vault), amount);
        vault.fundBackstop(amount);
        vm.stopPrank();
        calls["backstop"]++;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 hours, 3 days));
        calls["warp"]++;
    }
}
