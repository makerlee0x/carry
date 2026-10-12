// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice External library: senior pool share + FIFO withdraw-queue math (round in pool's favor).
library CarryPool {
    uint256 internal constant WAD = 1e18;
    /// @dev Virtual offset against first-depositor inflation (ERC4626-style).
    uint256 internal constant VIRTUAL_ASSETS = 1;
    uint256 internal constant VIRTUAL_SHARES = 1e6;

    error ZeroShares();
    error ZeroAssets();

    /// @dev Deposit: mint shares rounded DOWN (pool favor).
    function convertToShares(uint256 assets, uint256 totalShares, uint256 totalAssets)
        external
        pure
        returns (uint256)
    {
        if (assets == 0) return 0;
        return assets * (totalShares + VIRTUAL_SHARES) / (totalAssets + VIRTUAL_ASSETS);
    }

    /// @dev Redeem: assets out rounded DOWN (pool favor).
    function convertToAssets(uint256 shares, uint256 totalShares, uint256 totalAssets)
        external
        pure
        returns (uint256)
    {
        if (shares == 0) return 0;
        return shares * (totalAssets + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES);
    }

    /// @dev Shares needed to withdraw `assets`, rounded UP (pool favor).
    function previewWithdrawShares(uint256 assets, uint256 totalShares, uint256 totalAssets)
        external
        pure
        returns (uint256)
    {
        if (assets == 0) return 0;
        uint256 denom = totalAssets + VIRTUAL_ASSETS;
        return (assets * (totalShares + VIRTUAL_SHARES) + denom - 1) / denom;
    }

    /// @dev Lazy FIFO claimable assets for a queued request (no loops).
    ///      `cursor` = cumulativeRequested before this user's request.
    function claimableQueued(
        uint256 assetsRequested,
        uint256 alreadyClaimed,
        uint256 cursor,
        uint256 cumulativeFulfilled
    ) external pure returns (uint256) {
        if (assetsRequested == 0 || alreadyClaimed >= assetsRequested) return 0;
        if (cumulativeFulfilled <= cursor) return 0;
        uint256 reached = cumulativeFulfilled - cursor;
        uint256 entitled = reached < assetsRequested ? reached : assetsRequested;
        return entitled > alreadyClaimed ? entitled - alreadyClaimed : 0;
    }
}
