// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMstrSellRouter
/// @notice Sells a market's stock token for USDG. One router serves every market.
///         The strategy calls it at pool close when the USDG that came back can't pay the
///         treasury and senior in full (Stage 2 pool flow).
///
/// Expected behavior:
/// 1. Caller approves `amount` of `token` to the router.
/// 2. Router pulls it, swaps to USDG on an AMM.
/// 3. Router sends `usdgOut` to `recipient` and MUST revert below `minUsdgOut`.
interface IMstrSellRouter {
    function sellForUsdg(address token, uint256 amount, uint256 minUsdgOut, address recipient)
        external
        returns (uint256 usdgOut);
}
