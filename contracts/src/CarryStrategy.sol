// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IDualPoolLp, DualPoolKey} from "./interfaces/IDualPoolLp.sol";
import {PoolExit} from "./interfaces/ICarryStrategy.sol";
import {IMstrSellRouter} from "./interfaces/IMstrSellRouter.sol";

/// @title Carry strategy: where the vault's idle and matched capital earns.
/// @notice Two legs, both callable only by the Carry vault, which keeps custody accounting:
///  1. Idle leg. Lender USDG not matched to a junior sits in an ERC-4626 Morpho/Steakhouse
///     vault, so the lender's share price follows the real (floating) supply rate.
///  2. Pool leg. A fully matched position's USDG and stock go to its market's DualPool pool
///     (`enterPool`); the hook parks its own idle inventory in ERC-4626 vaults between swaps.
///     `exitPool` takes the position's share back out and splits it for the vault.
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
    error NoRouter();

    /// @notice Price slippage the close-out sale may take against the oracle.
    uint256 public constant MAX_SELL_SLIPPAGE_WAD = 0.03e18;
    uint256 internal constant WAD = 1e18;
    /// @dev Reference share count for reading the pool's deposit ratio.
    uint256 internal constant PREVIEW_SHARES = 1e24;

    /// @notice One position's share of its market's pool.
    struct PoolLp {
        uint256 shares;
        uint256 usdgIn;
        uint256 stockIn;
        /// @notice Morpho shares `usdgIn` would have bought at entry: the senior's floating-rate entitlement.
        uint256 morphoShares;
    }

    mapping(uint256 => PoolLp) public poolLp;

    event IdleDeposited(uint256 assets, uint256 shares);
    event IdleWithdrawn(uint256 assets, uint256 shares, address to);
    event LpAdded(address indexed hook, uint256 shares, uint256 amount0, uint256 amount1);
    event LpRemoved(address indexed hook, uint256 shares, uint256 amount0, uint256 amount1);
    event PoolEntered(uint256 indexed positionId, address indexed hook, uint256 shares, uint256 usdgIn, uint256 stockIn);
    event PoolExited(
        uint256 indexed positionId, uint256 usdgOut, uint256 stockOut, uint256 treasury, uint256 senior, uint256 stockSold
    );

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

    // ------------------------------------------------------------------ per-position pool leg

    /// @notice Put a matched position into its market's pool. The vault has already sent `stockAmt` stock
    ///         and `usdgAmt` USDG here. Adds as much as the pool's current ratio allows; the rest goes back.
    /// @return shares LP shares now held for the position (0 if the pool can't take any).
    /// @return usdgUsed USDG that went into the pool.
    function enterPool(uint256 positionId, DualPoolKey calldata key, uint256 stockAmt, uint256 usdgAmt)
        external
        onlyVault
        returns (uint256 shares, uint256 usdgUsed)
    {
        bool usdgIs0 = key.currency0 == address(usdg);
        IERC20 stock = IERC20(usdgIs0 ? key.currency1 : key.currency0);
        IDualPoolLp hook = IDualPoolLp(key.hooks);
        (uint256 max0, uint256 max1) = usdgIs0 ? (usdgAmt, stockAmt) : (stockAmt, usdgAmt);

        (uint256 r0, uint256 r1) = hook.previewDeposit(key, PREVIEW_SHARES);
        uint256 s0 = r0 == 0 ? type(uint256).max : max0 * PREVIEW_SHARES / r0;
        uint256 s1 = r1 == 0 ? type(uint256).max : max1 * PREVIEW_SHARES / r1;
        shares = s0 < s1 ? s0 : s1;
        // previewDeposit rounds up; leave room so the hook's pull stays within max0/max1.
        shares = shares > shares / 1e12 + 2 ? shares - shares / 1e12 - 2 : 0;

        uint256 stockUsed;
        if (shares != 0 && shares != type(uint256).max) {
            IERC20(key.currency0).forceApprove(address(hook), max0);
            IERC20(key.currency1).forceApprove(address(hook), max1);
            (uint256 a0, uint256 a1) = hook.addLiquidity(key, shares, max0, max1, block.timestamp);
            IERC20(key.currency0).forceApprove(address(hook), 0);
            IERC20(key.currency1).forceApprove(address(hook), 0);
            (usdgUsed, stockUsed) = usdgIs0 ? (a0, a1) : (a1, a0);

            PoolLp storage lp = poolLp[positionId];
            lp.shares += shares;
            lp.usdgIn += usdgUsed;
            lp.stockIn += stockUsed;
            lp.morphoShares += morpho.convertToShares(usdgUsed);
            emit PoolEntered(positionId, address(hook), shares, usdgUsed, stockUsed);
        } else {
            shares = 0;
        }
        if (usdgAmt > usdgUsed) usdg.safeTransfer(vault, usdgAmt - usdgUsed);
        if (stockAmt > stockUsed) stock.safeTransfer(vault, stockAmt - stockUsed);
    }

    /// @notice Take a position's share out of the pool and split it in the agreed order.
    /// @dev The result is measured against holding: what the pooled USDG would have earned in Morpho plus
    ///      the pooled stock at `priceWad`. Anything above that is split treasury / senior / junior; anything
    ///      below is the junior's first. The senior is paid in USDG; stock is sold through `router` for any gap.
    ///      If the pool is worth less than the senior's entitlement, the senior gets all of it (the vault then
    ///      covers principal from the backstop).
    function exitPool(
        uint256 positionId,
        DualPoolKey calldata key,
        uint256 priceWad,
        uint256 treasuryCutWad,
        uint256 seniorCutWad,
        address router
    ) external onlyVault returns (PoolExit memory x) {
        PoolLp memory lp = poolLp[positionId];
        delete poolLp[positionId];
        bool usdgIs0 = key.currency0 == address(usdg);
        IERC20 stock = IERC20(usdgIs0 ? key.currency1 : key.currency0);

        (uint256 a0, uint256 a1) = IDualPoolLp(key.hooks).removeLiquidity(key, lp.shares, 0, 0, block.timestamp);
        (uint256 u, uint256 s) = usdgIs0 ? (a0, a1) : (a1, a0);
        uint256 unit = 10 ** IERC20Metadata(address(stock)).decimals() * WAD
            / 10 ** IERC20Metadata(address(usdg)).decimals();

        uint256 owed = morpho.convertToAssets(lp.morphoShares);
        uint256 value = u + s * priceWad / unit;
        uint256 hold = owed + lp.stockIn * priceWad / unit;
        uint256 seniorCut;
        if (value > hold) {
            x.treasury = (value - hold) * treasuryCutWad / WAD;
            seniorCut = (value - hold) * seniorCutWad / WAD;
        }
        x.senior = value > owed ? owed + seniorCut : value;

        uint256 need = x.senior + x.treasury;
        if (u < need && s != 0) {
            if (router == address(0)) revert NoRouter();
            uint256 sell = (need - u) * unit / priceWad * (WAD + MAX_SELL_SLIPPAGE_WAD) / WAD + 1;
            if (sell > s) sell = s;
            stock.forceApprove(router, sell);
            u += IMstrSellRouter(router).sellForUsdg(
                address(stock), sell, sell * priceWad / unit * (WAD - MAX_SELL_SLIPPAGE_WAD) / WAD, address(this)
            );
            s -= sell;
            x.stockSold = sell;
        }

        // Treasury first, then senior, then junior.
        if (x.treasury > u) x.treasury = u;
        if (x.senior > u - x.treasury) x.senior = u - x.treasury;
        x.juniorUsdg = u - x.treasury - x.senior;
        x.juniorStock = s;
        x.usdgIn = lp.usdgIn;
        x.stockIn = lp.stockIn;

        if (u != 0) usdg.safeTransfer(vault, u);
        if (s != 0) stock.safeTransfer(vault, s);
        emit PoolExited(positionId, u, s, x.treasury, x.senior, x.stockSold);
    }
}
