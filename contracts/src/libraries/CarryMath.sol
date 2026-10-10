// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice External library to keep LeveredLpVault under EIP-170 runtime size.
library CarryMath {
    uint256 internal constant WAD = 1e18;

    struct WaterfallSplit {
        uint256 accrual;
        uint256 seniorFloor;
        uint256 treasury;
        uint256 seniorPerf;
        uint256 junior;
        uint256 seniorTotal;
    }

    function waterfallFromGross(uint256 gross, uint256 accrual, uint256 cutWad, uint256 seniorPerfCutWad)
        external
        pure
        returns (WaterfallSplit memory s)
    {
        s.accrual = accrual;
        s.seniorFloor = gross < accrual ? gross : accrual;
        uint256 left = gross - s.seniorFloor;
        uint256 treasuryCap = gross * cutWad / WAD;
        s.treasury = left < treasuryCap ? left : treasuryCap;
        left -= s.treasury;
        uint256 perfCap = gross * seniorPerfCutWad / WAD;
        s.seniorPerf = left < perfCap ? left : perfCap;
        s.junior = left - s.seniorPerf;
        s.seniorTotal = s.seniorFloor + s.seniorPerf;
    }

    function seniorAssets(uint256 mstrAmount, uint256 priceWad, uint8 mstrDecimals, uint8 usdgDecimals)
        external
        pure
        returns (uint256)
    {
        return mstrAmount * priceWad * (10 ** usdgDecimals) / (WAD * (10 ** mstrDecimals));
    }

    function mstrToCover(uint256 usdgShort, uint256 priceWad, uint8 mstrDecimals, uint8 usdgDecimals)
        external
        pure
        returns (uint256)
    {
        if (usdgShort == 0) return 0;
        uint256 numer = usdgShort * WAD * (10 ** mstrDecimals);
        uint256 denom = priceWad * (10 ** usdgDecimals);
        return ceilDiv(numer, denom);
    }

    function usdgValue(uint256 mstrAmount, uint256 priceWad, uint8 mstrDecimals, uint8 usdgDecimals)
        external
        pure
        returns (uint256)
    {
        return mstrAmount * priceWad * (10 ** usdgDecimals) / (WAD * (10 ** mstrDecimals));
    }

    function morphoAccrual(uint256 principal, uint256 rateWad, uint256 elapsed, uint256 year)
        external
        pure
        returns (uint256)
    {
        return principal * rateWad * elapsed / (WAD * year);
    }

    function ceilDiv(uint256 a, uint256 b) public pure returns (uint256) {
        if (a == 0) return 0;
        return (a - 1) / b + 1;
    }

    function sqrt(uint256 y) external pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
