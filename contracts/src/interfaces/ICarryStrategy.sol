// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The idle-USDG leg of CarryStrategy that the vault calls.
interface ICarryStrategy {
    function deposit(uint256 assets) external returns (uint256 shares);
    function withdraw(uint256 assets, address to) external returns (uint256 shares);
    function idleAssets() external view returns (uint256);
}
