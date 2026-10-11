// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice External library to keep LeveredLpVault under EIP-170 runtime size.
library CarryBook {
    struct FunderSlice {
        address lender;
        uint256 amount;
        uint64 matchedAt;
    }

    error InsufficientFunder();

    function creditByTimeWeight(
        FunderSlice[] storage funders,
        uint256 amount,
        uint256 timestamp
    ) external view returns (address[] memory lenders, uint256[] memory shares) {
        uint256 n = funders.length;
        lenders = new address[](n);
        shares = new uint256[](n);
        if (amount == 0 || n == 0) return (lenders, shares);

        uint256 totalW;
        uint256 totalA;
        for (uint256 i; i < n; ++i) {
            lenders[i] = funders[i].lender;
            totalA += funders[i].amount;
            uint256 matchedAt = funders[i].matchedAt;
            uint256 dur = timestamp > matchedAt ? timestamp - matchedAt : 0;
            totalW += funders[i].amount * dur;
        }
        if (totalW == 0) {
            if (totalA == 0) return (lenders, shares);
            uint256 paid;
            for (uint256 i; i < n; ++i) {
                uint256 share = i + 1 == n ? amount - paid : amount * funders[i].amount / totalA;
                paid += share;
                shares[i] = share;
            }
            return (lenders, shares);
        }
        uint256 paidW;
        for (uint256 i; i < n; ++i) {
            uint256 matchedAt = funders[i].matchedAt;
            uint256 dur = timestamp > matchedAt ? timestamp - matchedAt : 0;
            uint256 w = funders[i].amount * dur;
            uint256 share = i + 1 == n ? amount - paidW : amount * w / totalW;
            paidW += share;
            shares[i] = share;
        }
    }

    function removeFunderAmount(FunderSlice[] storage funders, address lender, uint256 amount) external {
        uint256 remaining = amount;
        uint256 i;
        while (i < funders.length && remaining > 0) {
            if (funders[i].lender != lender) {
                unchecked { ++i; }
                continue;
            }
            if (funders[i].amount <= remaining) {
                remaining -= funders[i].amount;
                funders[i] = funders[funders.length - 1];
                funders.pop();
            } else {
                funders[i].amount -= remaining;
                remaining = 0;
                unchecked { ++i; }
            }
        }
        if (remaining != 0) revert InsufficientFunder();
    }

    function funderAmountOf(FunderSlice[] storage funders, address lender) external view returns (uint256 total) {
        uint256 n = funders.length;
        for (uint256 i; i < n; ++i) {
            if (funders[i].lender == lender) total += funders[i].amount;
        }
    }

    function funderSum(FunderSlice[] storage funders) external view returns (uint256 total) {
        uint256 n = funders.length;
        for (uint256 i; i < n; ++i) total += funders[i].amount;
    }
}
