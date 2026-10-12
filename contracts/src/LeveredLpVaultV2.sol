// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LeveredLpVault} from "./LeveredLpVault.sol";

/// @notice Deployable implementation alias for Carry v3 lender-pool (inherits version()).
contract LeveredLpVaultV2 is LeveredLpVault {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
}
