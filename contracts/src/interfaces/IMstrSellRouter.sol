// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMstrSellRouter
/// @notice Mainnet SellShares path: swap position MSTR via Uniswap (or equivalent) AMM.
///         Vault calls this when `sellSharesRouter != address(0)`.
///
/// Testnet: leave router unset (`address(0)`). Vault keeps the existing behavior —
/// credit sold MSTR notionally to seniors (no AMM).
///
/// Expected mainnet behavior:
/// 1. Vault approves `mstrAmount` to the router.
/// 2. Router pulls MSTR from the vault, swaps on Uniswap to USDG.
/// 3. Router sends `usdgOut` to `recipient` (vault passes itself, then allocates
///    senior cover + treasury-on-cover; remainder is delivered to the junior
///    wallet or auto-compounded).
interface IMstrSellRouter {
    /// @param mstrAmount Exact MSTR pulled from msg.sender (the vault).
    /// @param minUsdgOut Slippage floor; router MUST revert if unmet.
    /// @param recipient USDG recipient (vault on current wiring).
    /// @return usdgOut USDG amount sent to `recipient`.
    function sellMstrForUsdg(uint256 mstrAmount, uint256 minUsdgOut, address recipient)
        external
        returns (uint256 usdgOut);
}
