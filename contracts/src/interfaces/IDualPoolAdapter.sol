// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Future DualPool seam. Not wired to custody.
/// @notice The live hook must be Uniswap's pinned DualPool bytecode, deployed by
///         their factory on Ethereum at 0x0000000000077769C332e0D3ed8bC8E02A0cE108
///         (that factory is not on Robinhood Chain 4663), or a byte-exact copy
///         pointed at Robinhood PoolManager 0x8366a39cc670b4001a1121b8f6a443a643e40951
///         only after an audit. Do not deploy a modified hook that holds funds.
///         LeveredLpVault does not call this interface and does not approve the PoolManager.
interface IDualPoolAdapter {
    function poolManager() external view returns (address);
    function vault() external view returns (address);
}
