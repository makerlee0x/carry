// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPushablePriceOracle} from "../interfaces/IPushablePriceOracle.sol";

/// @notice Owner-pushed MSTR price with timestamp for staleness checks (testnet / keeper feed).
contract PushablePriceOracle is IPushablePriceOracle {
    address public owner;
    uint256 public priceWad;
    uint64 public lastUpdatedAt;

    error ZeroPrice();
    error ZeroAddress();
    error NotOwner();

    event PricePushed(uint256 priceWad, uint64 updatedAt);
    event OwnerUpdated(address indexed owner);

    constructor(address owner_, uint256 priceWad_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (priceWad_ == 0) revert ZeroPrice();
        owner = owner_;
        priceWad = priceWad_;
        lastUpdatedAt = uint64(block.timestamp);
        emit PricePushed(priceWad_, lastUpdatedAt);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
        emit OwnerUpdated(newOwner);
    }

    function pushPrice(uint256 priceWad_) external {
        if (msg.sender != owner) revert NotOwner();
        if (priceWad_ == 0) revert ZeroPrice();
        priceWad = priceWad_;
        lastUpdatedAt = uint64(block.timestamp);
        emit PricePushed(priceWad_, lastUpdatedAt);
    }

    function mstrPriceWad() external view returns (uint256) {
        return priceWad;
    }
}