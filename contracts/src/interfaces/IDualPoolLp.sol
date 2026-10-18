// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Uniswap v4 PoolKey, field-for-field. `Currency` is an address-backed value type, so
///         this encodes identically to the v4-core struct without importing v4-core here.
struct DualPoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @notice The slice of Uniswap's DualPoolHook the Carry strategy calls (hook/src/alf/DualPoolHook.sol).
interface IDualPoolLp {
    function addLiquidity(
        DualPoolKey calldata key,
        uint256 sharesToMint,
        uint256 maxAmount0,
        uint256 maxAmount1,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);

    function removeLiquidity(
        DualPoolKey calldata key,
        uint256 sharesToBurn,
        uint256 minAmount0,
        uint256 minAmount1,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);

    function sharesOf(DualPoolKey calldata key, address user) external view returns (uint256);
}
