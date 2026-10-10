// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LeveredLpVault} from "../src/LeveredLpVault.sol";
import {LeveredLpVaultV2} from "../src/LeveredLpVaultV2.sol";

/// @title UpgradeCarryVault
/// @notice Deploys a new LeveredLpVaultV2 implementation and UUPS-upgrades the product PROXY.
///         Optionally sets launch deposit caps ($25k / $2.5k).
///
/// Live:
///   broadcastArmed() == true, DEPLOYER_PRIVATE_KEY (= owner), chain 46630.
///   PROXY_ADDRESS defaults to product CA.
contract UpgradeCarryVault is Script {
    uint256 public constant RH_TESTNET_CHAIN_ID = 46630;
    address public constant DEFAULT_PROXY = 0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd;
    uint256 public constant CAP_TOTAL = 25_000 ether;
    uint256 public constant CAP_PER_WALLET = 2_500 ether;

    error BroadcastBlocked();
    error WrongChain();
    error MainnetForbidden();
    error NotOwner();

    function broadcastArmed() public pure returns (bool) {
        return false;
    }

    function run() external {
        if (block.chainid == 4663 || block.chainid == 1) revert MainnetForbidden();

        bool live = broadcastArmed() && block.chainid == RH_TESTNET_CHAIN_ID;
        if (broadcastArmed() && block.chainid != RH_TESTNET_CHAIN_ID) revert WrongChain();

        address proxyAddr = vm.envOr("PROXY_ADDRESS", DEFAULT_PROXY);
        LeveredLpVault proxy = LeveredLpVault(proxyAddr);

        if (live) {
            address owner = proxy.owner();
            if (msg.sender != owner && tx.origin != owner) {
                // Foundry sets msg.sender to the broadcaster EOA when using --private-key.
            }
            vm.startBroadcast();
        } else {
            console2.log("DRY-RUN: broadcastArmed=false; no broadcast txs");
        }

        LeveredLpVaultV2 impl = new LeveredLpVaultV2();
        if (live) {
            if (proxy.owner() != msg.sender) revert NotOwner();
            // Storage-additive upgrade only. Does not touch position #5 state.
            proxy.upgradeToAndCall(address(impl), "");
            proxy.setDepositCaps(CAP_TOTAL, CAP_TOTAL, CAP_PER_WALLET);
            // Sync treasury cut to always-20% (Boosted slot kept equal; ignored by logic).
            proxy.setTreasuryCuts(0.2e18, 0.2e18);
            // Enable junior→senior gas credit refunds on depositSenior.
            proxy.setGasRefundWei(0.0001 ether);
            vm.stopBroadcast();
        }

        console2.log("chainId", block.chainid);
        console2.log("proxy", proxyAddr);
        console2.log("newImplementation", address(impl));
        if (live) {
            console2.log("version", LeveredLpVaultV2(proxyAddr).version());
            console2.log("maxTotalSeniorUsdg", proxy.maxTotalSeniorUsdg());
            console2.log("maxPerWalletUsdg", proxy.maxPerWalletUsdg());
            console2.log("gasRefundWei", proxy.gasRefundWei());
            console2.log("treasuryCutWad", proxy.treasuryCutWad());
        }
    }
}
