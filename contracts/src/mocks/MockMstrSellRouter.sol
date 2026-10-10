// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {IMstrSellRouter} from "../interfaces/IMstrSellRouter.sol";

/// @notice Test stub for mainnet SellShares AMM path. Mints/pays USDG at fixed price.
contract MockMstrSellRouter is IMstrSellRouter {
    IERC20Minimal public immutable mstr;
    IERC20Minimal public immutable usdg;
    uint256 public immutable priceWad;
    uint8 public immutable mstrDecimals;
    uint8 public immutable usdgDecimals;

    error TransferFailed();
    error Slippage();

    constructor(address mstr_, address usdg_, uint256 priceWad_) {
        mstr = IERC20Minimal(mstr_);
        usdg = IERC20Minimal(usdg_);
        priceWad = priceWad_;
        mstrDecimals = mstr.decimals();
        usdgDecimals = usdg.decimals();
    }

    function sellMstrForUsdg(uint256 mstrAmount, uint256 minUsdgOut, address recipient)
        external
        returns (uint256 usdgOut)
    {
        if (!mstr.transferFrom(msg.sender, address(this), mstrAmount)) revert TransferFailed();
        usdgOut = mstrAmount * priceWad * (10 ** usdgDecimals) / (1e18 * (10 ** mstrDecimals));
        if (usdgOut < minUsdgOut) revert Slippage();
        // Fund payout from this mock's balance (tests mint USDG here first).
        if (!usdg.transfer(recipient, usdgOut)) revert TransferFailed();
    }
}
