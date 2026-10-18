// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice Test stand-in for a Morpho / Steakhouse USDG ERC-4626 vault. Do not deploy on mainnet.
/// @dev Yield is simulated: totalAssets grows by `rateWad` (annual) on the assets held, and the
///      accrued amount is minted from the (mintable mock) underlying whenever the vault is
///      touched, so every share is always backed by real tokens. `setRate` is open for demos.
contract MockMorphoVault is ERC4626 {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;

    uint256 public rateWad;
    uint256 public lastAccrual;

    event RateSet(uint256 rateWad);

    constructor(IERC20 asset_, uint256 rateWad_) ERC4626(asset_) ERC20("Mock Morpho USDG", "mmUSDG") {
        rateWad = rateWad_;
        lastAccrual = block.timestamp;
    }

    function setRate(uint256 rateWad_) external {
        _accrue();
        rateWad = rateWad_;
        emit RateSet(rateWad_);
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + _pending();
    }

    function _pending() internal view returns (uint256) {
        uint256 held = IERC20(asset()).balanceOf(address(this));
        return held * rateWad * (block.timestamp - lastAccrual) / WAD / YEAR;
    }

    function _accrue() internal {
        uint256 p = _pending();
        lastAccrual = block.timestamp;
        if (p > 0) IMintable(asset()).mint(address(this), p);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _accrue();
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        _accrue();
        super._withdraw(caller, receiver, owner_, assets, shares);
    }
}
