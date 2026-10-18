// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice What the vault reads from STRATEGY staking when it locks a position's treasury cut.
interface IStrategyStaking {
    /// @return STRATEGY (18 decimals) actively staked toward `positionWallet`, own stake plus linked stakes.
    function stakedOf(address positionWallet) external view returns (uint256);
}
