// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LeveredLpVault} from "../../src/LeveredLpVault.sol";
import {LeveredLpVaultV2} from "../../src/LeveredLpVaultV2.sol";
import {IERC20Minimal} from "../../src/interfaces/IERC20Minimal.sol";

/// @notice Upgrades the live testnet v3 proxy on a fork and drives an existing position through it.
///         Skipped unless TESTNET_RPC is set (CI has no RPC), e.g.
///         TESTNET_RPC=https://rpc.testnet.chain.robinhood.com forge test --match-contract V3UpgradeFork
contract V3UpgradeForkTest is Test {
    LeveredLpVault constant VAULT = LeveredLpVault(0x24B799026AA7baa6856bCFD00c1Be1f583A83e35);

    function test_fork_upgradeKeepsLivePositionsWorking() public {
        string memory rpc = vm.envOr("TESTNET_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        address owner_ = VAULT.owner();
        uint256 navBefore = VAULT.totalSeniorAssets();
        uint256 sharesBefore = VAULT.totalShares();
        uint256 nextId = VAULT.nextPositionId();
        IERC20Minimal mstr = VAULT.mstr();

        LeveredLpVaultV2 impl = new LeveredLpVaultV2();
        vm.startPrank(owner_);
        VAULT.upgradeToAndCall(address(impl), abi.encodeCall(LeveredLpVault.initializeMarkets, ()));
        VAULT.setMaxPriceStale(0); // the fork warps past the oracle's last push
        vm.stopPrank();

        assertEq(VAULT.version(), "v3.2-dualpool");
        assertEq(VAULT.marketCount(), 1);
        (IERC20Minimal token,,,,,,) = VAULT.markets(0);
        assertEq(address(token), address(mstr));
        assertEq(VAULT.totalSeniorAssets(), navBefore, "lender NAV unchanged by the upgrade");
        assertEq(VAULT.totalShares(), sharesBefore);
        assertEq(VAULT.nextPositionId(), nextId);

        // Find a live matched position and settle it as its junior under the new code.
        for (uint256 id = 1; id < nextId; id++) {
            (address junior, uint256 amt,,,,, uint64 openedAt,, bool settled,,,,, uint256 marketId) =
                VAULT.positions(id);
            if (settled || openedAt == 0) continue;
            assertEq(marketId, 0, "legacy positions read market 0");
            vm.warp(uint256(openedAt) + VAULT.term() + 1);
            uint256 before = mstr.balanceOf(junior);
            bool compound = VAULT.autoCompound(junior);
            vm.prank(junior);
            LeveredLpVault.Settlement memory s = VAULT.settle(id);
            assertEq(s.coverUsdg, 0, "no coupon owed after the upgrade");
            if (!compound) assertEq(mstr.balanceOf(junior), before + amt, "junior gets the MSTR back");
            return;
        }
    }
}
