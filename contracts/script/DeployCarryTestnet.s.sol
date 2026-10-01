// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LeveredLpVault} from "../src/LeveredLpVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {MockFeePool} from "../src/mocks/MockFeePool.sol";

/// @title DeployCarryTestnet
/// @notice Robinhood Chain **Testnet** (chain id 46630) ONLY for live broadcast.
///
/// Deploys mock MSTR, mock USDG, MockOracle, MockFeePool, and LeveredLpVault (paused).
/// Does NOT unpause. Does NOT deploy DualPool. Refuses mainnet 4663 and Ethereum 1.
///
/// Dry-run (no key; works on anvil or forked testnet RPC):
///   forge script script/DeployCarryTestnet.s.sol --rpc-url https://rpc.testnet.chain.robinhood.com -vvvv
///
/// Broadcast requires: (1) broadcastArmed() == true, (2) local DEPLOYER_PRIVATE_KEY,
/// (3) testnet ETH for gas. Never commit keys.
contract DeployCarryTestnet is Script {
    uint256 public constant RH_TESTNET_CHAIN_ID = 46630;
    uint256 public constant ANVIL_CHAIN_ID = 31337;
    uint64 public constant TERM = 7 days;
    uint256 public constant BORROW_APR_WAD = 0.05e18;
    uint256 public constant PROTOCOL_CUT_WAD = 0.2e18;
    uint256 public constant DEMO_PRICE_WAD = 100 ether;

    error BroadcastBlocked();
    error WrongChain();
    error MustDeployPaused();
    error MainnetForbidden();

    /// @dev Flip only after Dylan has a testnet deployer wallet and reviews this script.
    /// Session deploy completed 2026-10-01; left disarmed so tests assert safe default.
    function broadcastArmed() public pure returns (bool) {
        return false;
    }

    function run() external {
        if (block.chainid == 4663 || block.chainid == 1) revert MainnetForbidden();

        bool liveBroadcast = broadcastArmed() && block.chainid == RH_TESTNET_CHAIN_ID;
        if (broadcastArmed() && block.chainid != RH_TESTNET_CHAIN_ID) revert WrongChain();
        if (!liveBroadcast && block.chainid != RH_TESTNET_CHAIN_ID && block.chainid != ANVIL_CHAIN_ID) {
            revert WrongChain();
        }

        address vaultOwner =
            liveBroadcast ? vm.envAddress("VAULT_OWNER") : vm.envOr("VAULT_OWNER", address(0xBEEF));

        if (liveBroadcast) {
            vm.startBroadcast();
        } else {
            console2.log("DRY-RUN: broadcastArmed=false or not on 46630; no broadcast txs");
        }

        MockERC20 mockMstr = new MockERC20("Mock MSTR", "mMSTR", 18);
        MockERC20 mockUsdg = new MockERC20("Mock USDG", "mUSDG", 18);
        MockOracle mockOracle = new MockOracle(DEMO_PRICE_WAD);
        MockFeePool mockPool = new MockFeePool(address(mockUsdg));
        LeveredLpVault vault = new LeveredLpVault(
            address(mockMstr),
            address(mockUsdg),
            address(mockOracle),
            TERM,
            BORROW_APR_WAD,
            PROTOCOL_CUT_WAD,
            vaultOwner
        );

        if (liveBroadcast) {
            vm.stopBroadcast();
        }

        if (!vault.paused()) revert MustDeployPaused();
        if (broadcastArmed() && !liveBroadcast) revert BroadcastBlocked();

        console2.log("chainId", block.chainid);
        console2.log("mockMstr", address(mockMstr));
        console2.log("mockUsdg", address(mockUsdg));
        console2.log("mockOracle", address(mockOracle));
        console2.log("mockFeePool", address(mockPool));
        console2.log("vault", address(vault));
        console2.log("vaultOwner", vaultOwner);
        console2.log("paused", vault.paused());
    }
}
