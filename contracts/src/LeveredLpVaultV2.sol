// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LeveredLpVault} from "./LeveredLpVault.sol";

/// @notice Upgrade smoke-test implementation. Adds version(); storage layout unchanged.
contract LeveredLpVaultV2 is LeveredLpVault {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function version() external pure returns (string memory) {
        return "v2.4-maker-leftovers";
    }
}
