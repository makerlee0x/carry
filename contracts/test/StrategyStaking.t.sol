// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StrategyStaking} from "../src/StrategyStaking.sol";
import {IERC20Minimal} from "../src/interfaces/IERC20Minimal.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract StrategyStakingTest is Test {
    uint256 internal constant COOLDOWN = 7 days;

    MockERC20 internal strategy;
    StrategyStaking internal staking;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        strategy = new MockERC20("Strategy", "STRATEGY", 18);
        staking = _deploy(address(strategy));
        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < users.length; ++i) {
            strategy.mint(users[i], 100_000_000 ether);
            vm.prank(users[i]);
            strategy.approve(address(staking), type(uint256).max);
        }
    }

    function _deploy(address token) internal returns (StrategyStaking) {
        bytes memory init = abi.encodeCall(StrategyStaking.initialize, (IERC20Minimal(token), COOLDOWN, address(this)));
        return StrategyStaking(address(new ERC1967Proxy(address(new StrategyStaking()), init)));
    }

    function test_upgrade_onlyOwner_keepsStakes() public {
        vm.prank(alice);
        staking.stakeAndLink(25_000 ether, bob);
        address next = address(new StrategyStaking());

        vm.prank(alice);
        vm.expectRevert();
        staking.upgradeToAndCall(next, "");

        staking.upgradeToAndCall(next, "");
        assertEq(staking.stakedOf(bob), 25_000 ether);
        assertEq(staking.positionWalletOf(alice), bob);
        assertEq(address(staking.strategy()), address(strategy));
        assertEq(staking.cooldown(), COOLDOWN);
    }

    function test_initialize_onlyOnce() public {
        vm.expectRevert();
        staking.initialize(IERC20Minimal(address(strategy)), COOLDOWN, alice);
        StrategyStaking impl = new StrategyStaking();
        vm.expectRevert();
        impl.initialize(IERC20Minimal(address(strategy)), COOLDOWN, alice);
    }

    function test_stake_countsTowardSelf() public {
        vm.prank(alice);
        staking.stake(25_000 ether);
        assertEq(staking.stakedOf(alice), 25_000 ether);
        assertEq(staking.totalStaked(), 25_000 ether);
        assertEq(strategy.balanceOf(address(staking)), 25_000 ether);
    }

    function test_stakeAndLink_countsTowardPositionWallet() public {
        vm.prank(alice);
        staking.stakeAndLink(100_000 ether, bob);
        assertEq(staking.stakedOf(alice), 0);
        assertEq(staking.stakedOf(bob), 100_000 ether);
        assertEq(staking.positionWalletOf(alice), bob);
    }

    function test_linkedStakesAddUp() public {
        vm.prank(alice);
        staking.stakeAndLink(300_000 ether, carol);
        vm.prank(bob);
        staking.stakeAndLink(200_000 ether, carol);
        vm.prank(carol);
        staking.stake(1 ether);
        assertEq(staking.stakedOf(carol), 500_001 ether);
    }

    function test_relink_lockedDuringCooldown() public {
        vm.startPrank(alice);
        staking.stake(25_000 ether);
        vm.expectRevert(abi.encodeWithSelector(StrategyStaking.LinkLocked.selector, block.timestamp + COOLDOWN));
        staking.link(bob);
        vm.warp(block.timestamp + COOLDOWN);
        staking.link(bob);
        vm.stopPrank();
        assertEq(staking.stakedOf(alice), 0);
        assertEq(staking.stakedOf(bob), 25_000 ether);
    }

    function test_relink_restartsLock() public {
        uint256 t = 1_000_000;
        vm.warp(t);
        vm.startPrank(alice);
        staking.stake(25_000 ether);
        t += COOLDOWN;
        vm.warp(t);
        staking.link(bob);
        vm.expectRevert(abi.encodeWithSelector(StrategyStaking.LinkLocked.selector, t + COOLDOWN));
        staking.link(carol);
        vm.stopPrank();
    }

    function test_topUp_restartsLinkLock() public {
        uint256 t = 1_000_000;
        vm.warp(t);
        vm.startPrank(alice);
        staking.stake(25_000 ether);
        t += COOLDOWN - 1;
        vm.warp(t);
        staking.stake(1 ether);
        vm.warp(t + 1);
        vm.expectRevert(abi.encodeWithSelector(StrategyStaking.LinkLocked.selector, t + COOLDOWN));
        staking.link(bob);
        vm.stopPrank();
    }

    function test_link_freeWithNoActiveStake() public {
        vm.startPrank(alice);
        staking.link(bob);
        staking.link(carol);
        staking.link(alice);
        vm.stopPrank();
        assertEq(staking.positionWalletOf(alice), alice);
    }

    function test_link_backToSelfClearsLink() public {
        vm.startPrank(alice);
        staking.stakeAndLink(25_000 ether, bob);
        vm.warp(block.timestamp + COOLDOWN);
        staking.link(alice);
        vm.stopPrank();
        assertEq(staking.stakedOf(alice), 25_000 ether);
        assertEq(staking.stakedOf(bob), 0);
    }

    function test_requestUnstake_stopsCountingAtOnce() public {
        vm.startPrank(alice);
        staking.stakeAndLink(100_000 ether, bob);
        staking.requestUnstake(40_000 ether);
        vm.stopPrank();
        assertEq(staking.stakedOf(bob), 60_000 ether);
        assertEq(staking.totalStaked(), 60_000 ether);
        assertEq(strategy.balanceOf(address(staking)), 100_000 ether);
    }

    function test_withdraw_onlyAfterCooldown() public {
        vm.startPrank(alice);
        staking.stake(25_000 ether);
        staking.requestUnstake(25_000 ether);
        uint256 endsAt = block.timestamp + COOLDOWN;
        vm.expectRevert(abi.encodeWithSelector(StrategyStaking.CooldownActive.selector, endsAt));
        staking.withdraw();
        vm.warp(endsAt);
        uint256 before = strategy.balanceOf(alice);
        staking.withdraw();
        vm.stopPrank();
        assertEq(strategy.balanceOf(alice) - before, 25_000 ether);
        assertEq(strategy.balanceOf(address(staking)), 0);
    }

    function test_secondRequest_restartsCooldownOnAllCooling() public {
        uint256 t = 1_000_000;
        vm.warp(t);
        vm.startPrank(alice);
        staking.stake(50_000 ether);
        staking.requestUnstake(25_000 ether);
        t += COOLDOWN - 1;
        vm.warp(t);
        staking.requestUnstake(25_000 ether);
        vm.warp(t + 1);
        vm.expectRevert(abi.encodeWithSelector(StrategyStaking.CooldownActive.selector, t + COOLDOWN));
        staking.withdraw();
        vm.stopPrank();
    }

    /// One stake cannot boost a second position wallet inside the term: moving it means waiting
    /// out the link lock, and unstaking locks the tokens.
    function test_flashBoost_cannotHop() public {
        vm.startPrank(alice);
        staking.stakeAndLink(10_000_000 ether, bob);
        vm.expectRevert(abi.encodeWithSelector(StrategyStaking.LinkLocked.selector, block.timestamp + COOLDOWN));
        staking.link(carol);
        staking.requestUnstake(10_000_000 ether);
        staking.link(carol); // allowed, but nothing moves with it
        vm.expectRevert(abi.encodeWithSelector(StrategyStaking.CooldownActive.selector, block.timestamp + COOLDOWN));
        staking.withdraw();
        vm.stopPrank();
        assertEq(staking.stakedOf(carol), 0);
        assertEq(staking.stakedOf(bob), 0);
    }

    function test_reverts_onBadInput() public {
        vm.startPrank(alice);
        vm.expectRevert(StrategyStaking.ZeroAmount.selector);
        staking.stake(0);
        vm.expectRevert(StrategyStaking.ZeroAddress.selector);
        staking.link(address(0));
        vm.expectRevert(StrategyStaking.InsufficientStake.selector);
        staking.requestUnstake(1);
        vm.expectRevert(StrategyStaking.NothingToWithdraw.selector);
        staking.withdraw();
        vm.stopPrank();
        address impl = address(new StrategyStaking());
        bytes memory init = abi.encodeCall(StrategyStaking.initialize, (IERC20Minimal(address(0)), COOLDOWN, alice));
        vm.expectRevert(StrategyStaking.ZeroAddress.selector);
        new ERC1967Proxy(impl, init);
    }

    function test_feeOnTransferToken_rejected() public {
        TaxToken tax = new TaxToken();
        StrategyStaking s = _deploy(address(tax));
        tax.mint(alice, 100 ether);
        vm.startPrank(alice);
        tax.approve(address(s), type(uint256).max);
        vm.expectRevert(StrategyStaking.FeeOnTransfer.selector);
        s.stake(100 ether);
        vm.stopPrank();
    }

    /// Random stake / link / unstake / withdraw sequences keep the books equal to the token balance.
    function testFuzz_accountingHolds(uint256 seed) public {
        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < 40; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address who = users[seed % 3];
            uint256 op = (seed >> 8) % 5;
            uint256 amt = ((seed >> 16) % 1_000_000 ether) + 1;
            vm.startPrank(who);
            if (op == 0) {
                staking.stake(amt);
            } else if (op == 1) {
                try staking.link(users[(seed >> 32) % 3]) {} catch {}
            } else if (op == 2) {
                (uint256 staked,,,,) = staking.stakers(who);
                if (staked > 0) staking.requestUnstake((amt % staked) + 1);
            } else if (op == 3) {
                try staking.withdraw() {} catch {}
            } else {
                vm.warp(block.timestamp + ((seed >> 40) % (2 * COOLDOWN)));
            }
            vm.stopPrank();
            _checkBooks(users);
        }
    }

    function _checkBooks(address[3] memory users) internal view {
        uint256 sumStakedOf;
        uint256 sumStaked;
        uint256 sumCooling;
        for (uint256 i; i < 3; ++i) {
            sumStakedOf += staking.stakedOf(users[i]);
            (uint256 staked, uint256 cooling,,,) = staking.stakers(users[i]);
            sumStaked += staked;
            sumCooling += cooling;
        }
        assertEq(sumStakedOf, staking.totalStaked());
        assertEq(sumStaked, staking.totalStaked());
        assertEq(strategy.balanceOf(address(staking)), sumStaked + sumCooling);
    }
}

/// Takes 1% on every transferFrom.
contract TaxToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount - amount / 100;
        return true;
    }
}
