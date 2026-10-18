// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LeveredLpVault} from "../src/LeveredLpVault.sol";
import {LeveredLpVaultV2} from "../src/LeveredLpVaultV2.sol";

/// @title UpgradeV3Proxy
/// @notice Upgrades the live v3 lender-pool PROXY in place to the current vault code and registers the
///         existing MSTR market as market 0 in the same transaction (`upgradeToAndCall` + `initializeMarkets`).
///         The two must land together: until `initializeMarkets` runs, market 0 has no token or oracle.
///
/// Signed by the vault owner only. Dry-run unless `broadcastArmed()` is flipped to true.
///   PROXY=0x24B799026AA7baa6856bCFD00c1Be1f583A83e35 forge script script/UpgradeV3Proxy.s.sol --rpc-url <testnet>
///
/// Never prints keys.
contract UpgradeV3Proxy is Script {
    uint256 public constant RH_TESTNET_CHAIN_ID = 46630;

    error WrongChain();
    error MainnetForbidden();

    function broadcastArmed() public pure returns (bool) {
        return false;
    }

    function run() external {
        if (block.chainid == 4663 || block.chainid == 1) revert MainnetForbidden();
        bool live = broadcastArmed() && block.chainid == RH_TESTNET_CHAIN_ID;
        if (broadcastArmed() && block.chainid != RH_TESTNET_CHAIN_ID) revert WrongChain();

        LeveredLpVault vault = LeveredLpVault(vm.envAddress("PROXY"));
        if (live) {
            vm.startBroadcast();
        } else {
            console2.log("DRY-RUN: broadcastArmed=false; simulating as the owner");
            vm.startPrank(vault.owner());
        }

        LeveredLpVaultV2 impl = new LeveredLpVaultV2();
        vault.upgradeToAndCall(address(impl), abi.encodeCall(LeveredLpVault.initializeMarkets, ()));

        if (live) vm.stopBroadcast();
        else vm.stopPrank();

        console2.log("impl", address(impl));
        console2.log("version", vault.version());
        console2.log("marketCount", vault.marketCount());
    }
}
