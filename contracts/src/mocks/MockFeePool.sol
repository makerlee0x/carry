// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {LeveredLpVault} from "../LeveredLpVault.sol";

/// @notice Test stand-in for LP fees. It pays USDG into the vault.
///         It is not a DualPool hook and it never takes inventory out.
contract MockFeePool {
    IERC20Minimal public immutable usdg;

    constructor(address usdg_) {
        usdg = IERC20Minimal(usdg_);
    }

    function payFee(address vault, uint256 positionId, uint256 amount) external {
        usdg.transferFrom(msg.sender, address(this), amount);
        usdg.approve(vault, amount);
        LeveredLpVault(vault).accrueLpFee(positionId, amount);
    }
}
