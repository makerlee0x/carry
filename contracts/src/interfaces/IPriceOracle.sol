// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice USDG paid for one whole MSTR token, scaled by 1e18.
///         A whole token is 10**decimals of that asset.
///         The vault stores this address immutably. The owner cannot replace it.
interface IPriceOracle {
    function mstrPriceWad() external view returns (uint256);
}
