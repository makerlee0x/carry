// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @notice Test price. A setter exists so tests can move the market.
///         Do not deploy this on Robinhood Chain. Production must use an oracle
///         the vault owner cannot write.
contract MockOracle is IPriceOracle {
    uint256 public priceWad;

    error ZeroPrice();

    constructor(uint256 priceWad_) {
        if (priceWad_ == 0) revert ZeroPrice();
        priceWad = priceWad_;
    }

    function setPrice(uint256 priceWad_) external {
        if (priceWad_ == 0) revert ZeroPrice();
        priceWad = priceWad_;
    }

    function mstrPriceWad() external view returns (uint256) {
        return priceWad;
    }
}
