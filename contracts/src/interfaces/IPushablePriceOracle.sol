// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "./IPriceOracle.sol";

/// @notice Oracle that exposes last push time for vault staleness checks.
interface IPushablePriceOracle is IPriceOracle {
    function lastUpdatedAt() external view returns (uint64);
}
