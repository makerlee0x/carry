// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CarryMath} from "./CarryMath.sol";

/// @notice Pure cover / waterfall helpers extracted for EIP-170 size.
library CarryCover {
    uint256 internal constant WAD = 1e18;

    function juniorPaidTreasuryCut(uint256 treasuryOnCover, uint256 fromPool, uint256 juniorShortfall)
        external
        pure
        returns (uint256 cutToBackstop)
    {
        if (treasuryOnCover == 0) return 0;
        if (fromPool == 0) return treasuryOnCover;
        uint256 coverTotal = juniorShortfall + treasuryOnCover;
        if (fromPool >= coverTotal) return 0;
        uint256 juniorPaid = coverTotal - fromPool;
        return juniorPaid > juniorShortfall ? juniorPaid - juniorShortfall : 0;
    }

    function previewCoverAmounts(uint256 accrual, uint256 seniorFloor, uint256 backstopBal, uint256 cutWad)
        external
        pure
        returns (uint256 shortfall, uint256 fromBackstop, uint256 treasuryOnCover, uint256 coverTotal)
    {
        shortfall = accrual > seniorFloor ? accrual - seniorFloor : 0;
        fromBackstop = backstopBal < shortfall ? backstopBal : shortfall;
        shortfall -= fromBackstop;
        treasuryOnCover = shortfall * cutWad / WAD;
        coverTotal = shortfall + treasuryOnCover;
    }
}
