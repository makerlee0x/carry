// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {IStrategyStaking} from "./interfaces/IStrategyStaking.sol";

/// @title StrategyStaking
/// @notice Holds STRATEGY for Carry boost tiers. No owner, no upgrade, no rewards.
/// A staker credits one position wallet (itself by default). The vault reads `stakedOf` when a
/// position matches and locks the tier for the term, so stake that has boosted a position is
/// held in place for `cooldown`:
/// - `requestUnstake` stops counting at once, but tokens leave only after `cooldown`.
/// - A staker with active stake cannot re-link until `cooldown` after its last stake or link.
contract StrategyStaking is IStrategyStaking {
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientStake();
    error LinkLocked(uint256 unlocksAt);
    error CooldownActive(uint256 endsAt);
    error NothingToWithdraw();
    error TransferFailed();
    error FeeOnTransfer();
    error Reentrancy();

    event Staked(address indexed staker, address indexed positionWallet, uint256 amount);
    event UnstakeRequested(address indexed staker, address indexed positionWallet, uint256 amount, uint256 endsAt);
    event Withdrawn(address indexed staker, uint256 amount);
    event Linked(address indexed staker, address indexed from, address indexed to, uint256 amount);

    struct Staker {
        uint256 staked; // counts toward `linkedTo`
        uint256 cooling; // no longer counts; withdrawable at `coolingEnds`
        uint64 coolingEnds;
        uint64 linkUnlocks;
        address linkedTo; // zero means the staker itself
    }

    IERC20Minimal public immutable strategy;
    uint256 public immutable cooldown;

    mapping(address => Staker) public stakers;
    mapping(address => uint256) internal _stakedOf;
    uint256 public totalStaked;

    uint256 private _locked = 1;

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(IERC20Minimal strategy_, uint256 cooldown_) {
        if (address(strategy_) == address(0)) revert ZeroAddress();
        strategy = strategy_;
        cooldown = cooldown_;
    }

    /// @inheritdoc IStrategyStaking
    function stakedOf(address positionWallet) external view returns (uint256) {
        return _stakedOf[positionWallet];
    }

    /// @notice Position wallet this staker's stake counts toward.
    function positionWalletOf(address staker) public view returns (address) {
        address to = stakers[staker].linkedTo;
        return to == address(0) ? staker : to;
    }

    /// @notice Stake toward the current position wallet (yourself unless linked).
    function stake(uint256 amount) external nonReentrant {
        _stake(amount);
    }

    /// @notice Link to `positionWallet`, then stake. Lets a fresh staker do both in one call.
    function stakeAndLink(uint256 amount, address positionWallet) external nonReentrant {
        _link(positionWallet);
        _stake(amount);
    }

    /// @notice Point this staker's stake at another position wallet.
    function link(address positionWallet) external nonReentrant {
        _link(positionWallet);
    }

    /// @notice Stop `amount` counting now; withdraw it after the cooldown. Restarts the cooldown on everything cooling.
    function requestUnstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Staker storage s = stakers[msg.sender];
        if (amount > s.staked) revert InsufficientStake();
        address to = positionWalletOf(msg.sender);
        s.staked -= amount;
        s.cooling += amount;
        s.coolingEnds = uint64(block.timestamp + cooldown);
        _stakedOf[to] -= amount;
        totalStaked -= amount;
        emit UnstakeRequested(msg.sender, to, amount, s.coolingEnds);
    }

    /// @notice Send cooled-down STRATEGY back to the staker.
    function withdraw() external nonReentrant {
        Staker storage s = stakers[msg.sender];
        uint256 amount = s.cooling;
        if (amount == 0) revert NothingToWithdraw();
        if (block.timestamp < s.coolingEnds) revert CooldownActive(s.coolingEnds);
        s.cooling = 0;
        if (!strategy.transfer(msg.sender, amount)) revert TransferFailed();
        emit Withdrawn(msg.sender, amount);
    }

    function _stake(uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        uint256 before = strategy.balanceOf(address(this));
        if (!strategy.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        if (strategy.balanceOf(address(this)) - before != amount) revert FeeOnTransfer();

        Staker storage s = stakers[msg.sender];
        address to = positionWalletOf(msg.sender);
        s.staked += amount;
        s.linkUnlocks = uint64(block.timestamp + cooldown);
        _stakedOf[to] += amount;
        totalStaked += amount;
        emit Staked(msg.sender, to, amount);
    }

    function _link(address positionWallet) internal {
        if (positionWallet == address(0)) revert ZeroAddress();
        Staker storage s = stakers[msg.sender];
        address from = positionWalletOf(msg.sender);
        if (from == positionWallet) return;
        uint256 amount = s.staked;
        if (amount > 0) {
            if (block.timestamp < s.linkUnlocks) revert LinkLocked(s.linkUnlocks);
            _stakedOf[from] -= amount;
            _stakedOf[positionWallet] += amount;
            s.linkUnlocks = uint64(block.timestamp + cooldown);
        }
        s.linkedTo = positionWallet == msg.sender ? address(0) : positionWallet;
        emit Linked(msg.sender, from, positionWallet, amount);
    }
}
