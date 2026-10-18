// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LeveredLpVaultV2} from "../../src/LeveredLpVaultV2.sol";

/// @notice Mainnet blocker: the implementation must deploy without --disable-code-size-limit.
contract Eip170Test is Test {
    uint256 internal constant EIP170_LIMIT = 24_576;

    function test_implFitsEip170() public {
        uint256 size = address(new LeveredLpVaultV2()).code.length;
        emit log_named_uint("impl runtime bytes", size);
        assertLe(size, EIP170_LIMIT, "BUG: vault impl exceeds EIP-170; cannot deploy on mainnet");
    }
}
