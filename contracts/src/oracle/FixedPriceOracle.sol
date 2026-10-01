// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @notice Frozen price. No setter, so the vault owner cannot move it.
///         A stale snapshot will mis-settle a live book. Do not unpause a vault
///         that points at one unless that price was reviewed for this deploy.
contract FixedPriceOracle is IPriceOracle {
    uint256 public immutable priceWad;

    error ZeroPrice();

    constructor(uint256 priceWad_) {
        if (priceWad_ == 0) revert ZeroPrice();
        priceWad = priceWad_;
    }

    function mstrPriceWad() external view returns (uint256) {
        return priceWad;
    }
}
