// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBoostHook} from "./interfaces/IBoostHook.sol";
import {IStrategyStaking} from "./interfaces/IStrategyStaking.sol";

/// @title StrategyBoostHook
/// @notice Maps STRATEGY staked toward a junior to a treasury cut. Holds no tokens. The vault caps the
/// result at its base cut, so a bad tier table can only lower Carry's take, never the senior's.
contract StrategyBoostHook is IBoostHook {
    IStrategyStaking public immutable staking;
    /// @dev Site Level I-V. Cuts are placeholders until maker picks them.
    uint256[5] public minStake = [25_000e18, 100_000e18, 500_000e18, 2_000_000e18, 10_000_000e18];
    uint256[5] public cutWad = [0.175e18, 0.1625e18, 0.1375e18, 0.1e18, 0.05e18];

    constructor(IStrategyStaking staking_) {
        staking = staking_;
    }

    function treasuryCutOf(address junior, uint256 baseCutWad) external view returns (uint256 cut) {
        uint256 stake = staking.stakedOf(junior);
        cut = baseCutWad;
        for (uint256 i; i < 5; ++i) {
            if (stake >= minStake[i]) cut = cutWad[i];
        }
    }
}
