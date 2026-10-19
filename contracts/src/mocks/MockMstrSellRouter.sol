// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {IMstrSellRouter} from "../interfaces/IMstrSellRouter.sol";

/// @notice Test stub for the stock sell path. Pays USDG at a fixed price per token, minus an optional haircut.
contract MockMstrSellRouter is IMstrSellRouter {
    IERC20Minimal public immutable usdg;
    mapping(address => uint256) public priceWad;
    uint256 public haircutWad;

    error TransferFailed();
    error Slippage();

    constructor(address usdg_) {
        usdg = IERC20Minimal(usdg_);
    }

    function setPrice(address token, uint256 priceWad_) external {
        priceWad[token] = priceWad_;
    }

    function setHaircut(uint256 haircutWad_) external {
        haircutWad = haircutWad_;
    }

    function sellForUsdg(address token, uint256 amount, uint256 minUsdgOut, address recipient)
        external
        returns (uint256 usdgOut)
    {
        if (!IERC20Minimal(token).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        usdgOut = amount * priceWad[token] * (10 ** usdg.decimals()) / (1e18 * (10 ** IERC20Minimal(token).decimals()));
        usdgOut -= usdgOut * haircutWad / 1e18;
        if (usdgOut < minUsdgOut) revert Slippage();
        // Fund payout from this mock's balance (tests mint USDG here first).
        if (!usdg.transfer(recipient, usdgOut)) revert TransferFailed();
    }
}
