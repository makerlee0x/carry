// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DualPoolKey} from "./IDualPoolLp.sol";

/// @notice What a matched position's pool share paid out at close, already split in the agreed order
///         (treasury, then senior, then junior). All tokens are sent to the vault.
struct PoolExit {
    uint256 treasury; // USDG: treasury cut of the result above holding
    uint256 senior; // USDG: senior's pooled USDG + Morpho yield + its cut, or less if the pool fell short
    uint256 juniorUsdg; // USDG left for the junior
    uint256 juniorStock; // stock left for the junior (from the pool; the vault adds any leftover it kept)
    uint256 usdgIn; // USDG the position put into the pool
    uint256 stockIn; // stock the position put into the pool
    uint256 stockSold; // stock sold through the router to pay treasury and senior in USDG
}

/// @notice The legs of CarryStrategy that the vault calls.
interface ICarryStrategy {
    function deposit(uint256 assets) external returns (uint256 shares);
    function withdraw(uint256 assets, address to) external returns (uint256 shares);
    function idleAssets() external view returns (uint256);

    function enterPool(uint256 positionId, DualPoolKey calldata key, uint256 stockAmt, uint256 usdgAmt)
        external
        returns (uint256 shares, uint256 usdgUsed);

    function exitPool(
        uint256 positionId,
        DualPoolKey calldata key,
        uint256 priceWad,
        uint256 treasuryCutWad,
        uint256 seniorCutWad,
        address router
    ) external returns (PoolExit memory);
}
