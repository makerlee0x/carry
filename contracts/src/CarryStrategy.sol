// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDualPoolLp, DualPoolKey} from "./interfaces/IDualPoolLp.sol";

/// @title Carry strategy: where the vault's idle and matched capital earns.
/// @notice Two legs, both callable only by the Carry vault, which keeps custody accounting:
///  1. Idle leg. Lender USDG not matched to a junior sits in an ERC-4626 Morpho/Steakhouse
///     vault, so the lender's share price follows the real (floating) supply rate.
///  2. Pool leg. Matched USDG and MSTR go to Uniswap's DualPoolHook as an LP; the hook parks
///     its own idle inventory in ERC-4626 vaults between swaps.
/// Tokens only ever move vault -> strategy -> venue and back to the vault; the strategy never
/// holds a balance between calls and has no owner, upgrade path or admin function.
contract CarryStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdg;
    IERC4626 public immutable morpho;
    address public immutable vault;

    error NotVault();
    error ZeroAmount();
    error AssetMismatch();

    event IdleDeposited(uint256 assets, uint256 shares);
    event IdleWithdrawn(uint256 assets, uint256 shares, address to);
    event LpAdded(address indexed hook, uint256 shares, uint256 amount0, uint256 amount1);
    event LpRemoved(address indexed hook, uint256 shares, uint256 amount0, uint256 amount1);

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor(address vault_, IERC4626 morpho_) {
        if (morpho_.asset() == address(0)) revert AssetMismatch();
        vault = vault_;
        morpho = morpho_;
        usdg = IERC20(morpho_.asset());
    }

    // ------------------------------------------------------------------ idle leg

    /// @notice USDG the strategy could withdraw from Morpho right now, including accrued yield.
    function idleAssets() public view returns (uint256) {
        return morpho.convertToAssets(morpho.balanceOf(address(this)));
    }

    /// @notice Pull `assets` USDG from the vault (needs allowance) and supply it to Morpho.
    function deposit(uint256 assets) external onlyVault returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        usdg.safeTransferFrom(msg.sender, address(this), assets);
        usdg.forceApprove(address(morpho), assets);
        shares = morpho.deposit(assets, address(this));
        emit IdleDeposited(assets, shares);
    }

    /// @notice Withdraw exactly `assets` USDG from Morpho to `to`.
    function withdraw(uint256 assets, address to) external onlyVault returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        shares = morpho.withdraw(assets, to, address(this));
        emit IdleWithdrawn(assets, shares, to);
    }

    /// @notice Withdraw everything, principal and yield, to `to`.
    function withdrawAll(address to) external onlyVault returns (uint256 assets) {
        uint256 shares = morpho.balanceOf(address(this));
        if (shares == 0) revert ZeroAmount();
        assets = morpho.redeem(shares, to, address(this));
        emit IdleWithdrawn(assets, shares, to);
    }

    // ------------------------------------------------------------------ pool leg

    /// @notice Add liquidity to a DualPool pool using up to `max0`/`max1` of the vault's tokens.
    ///         Unused tokens go straight back to the vault.
    function addLp(IDualPoolLp hook, DualPoolKey calldata key, uint256 shares, uint256 max0, uint256 max1, uint256 deadline)
        external
        onlyVault
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert ZeroAmount();
        IERC20 t0 = IERC20(key.currency0);
        IERC20 t1 = IERC20(key.currency1);
        t0.safeTransferFrom(msg.sender, address(this), max0);
        t1.safeTransferFrom(msg.sender, address(this), max1);
        t0.forceApprove(address(hook), max0);
        t1.forceApprove(address(hook), max1);
        (amount0, amount1) = hook.addLiquidity(key, shares, max0, max1, deadline);
        t0.forceApprove(address(hook), 0);
        t1.forceApprove(address(hook), 0);
        if (max0 > amount0) t0.safeTransfer(msg.sender, max0 - amount0);
        if (max1 > amount1) t1.safeTransfer(msg.sender, max1 - amount1);
        emit LpAdded(address(hook), shares, amount0, amount1);
    }

    /// @notice Burn `shares` of the strategy's DualPool position; proceeds go to the vault.
    function removeLp(IDualPoolLp hook, DualPoolKey calldata key, uint256 shares, uint256 min0, uint256 min1, uint256 deadline)
        external
        onlyVault
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert ZeroAmount();
        (amount0, amount1) = hook.removeLiquidity(key, shares, min0, min1, deadline);
        if (amount0 > 0) IERC20(key.currency0).safeTransfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(key.currency1).safeTransfer(msg.sender, amount1);
        emit LpRemoved(address(hook), shares, amount0, amount1);
    }

    function lpShares(IDualPoolLp hook, DualPoolKey calldata key) external view returns (uint256) {
        return hook.sharesOf(key, address(this));
    }
}
