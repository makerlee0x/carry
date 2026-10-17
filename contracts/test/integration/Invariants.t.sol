// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CarryBase} from "./CarryBase.sol";
import {CarryHandler} from "./CarryHandler.sol";

/// @notice Fuzzed random sequences of deposits, fees, claims, exits, settles and time jumps.
///         After every call the books must balance and lenders must not lose principal.
contract CarryInvariantTest is CarryBase {
    CarryHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new CarryHandler(vault, mstr, usdg);
        for (uint256 i; i < handler.lenderCount(); ++i) {
            _track(handler.lenders(i));
        }
        targetContract(address(handler));
    }

    function invariant_books() public view {
        _assertBooks("invariant");
    }

    /// Lenders are never worse off than what they put in: pool value + what they withdrew >= deposits.
    /// (Juniors never hold pool shares in this handler, so totalSeniorAssets is all lender money.)
    function invariant_lenderPrincipalNeverLost() public view {
        assertGe(
            vault.totalSeniorAssets() + handler.ghostLenderOut() + 1,
            handler.ghostLenderIn(),
            "lenders lost principal"
        );
    }
}
