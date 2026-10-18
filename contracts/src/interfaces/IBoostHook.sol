// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Separate contract that turns a junior's STRATEGY stake into a treasury cut.
interface IBoostHook {
    /// @return cutWad treasury cut for `junior`'s next match; the vault caps it at `baseCutWad`.
    function treasuryCutOf(address junior, uint256 baseCutWad) external view returns (uint256 cutWad);
}
