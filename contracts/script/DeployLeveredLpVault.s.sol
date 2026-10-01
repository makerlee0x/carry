// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {LeveredLpVault} from "../src/LeveredLpVault.sol";

/// @title DeployLeveredLpVault
/// @notice Robinhood Chain (chain id 4663) ONLY. Refuses every other chain, including Ethereum mainnet.
///
/// BROADCAST IS BLOCKED until Dylan provides a deployer wallet.
/// `broadcastArmed()` returns false, so `run()` reverts before `vm.startBroadcast`.
/// Do not put a private key in this repo, in this file, or in a committed env file.
/// When a wallet exists, arm this in a review, export the key only in a local shell,
/// and broadcast against https://rpc.mainnet.chain.robinhood.com.
///
/// The vault is constructed paused. This script does not unpause, does not seed
/// inventory, and does not deploy a DualPool hook.
///
/// Required at a later broadcast (not secrets to commit):
///   VAULT_OWNER     pause key, preferably a multisig
///   ORACLE_ADDRESS  reviewed price source the owner cannot write
///                   (see src/oracle/FixedPriceOracle.sol — frozen, easy to misuse)
contract DeployLeveredLpVault is Script {
    address public constant MSTR = 0xec262a75e413fAfD0dF80480274532C79D42da09;
    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint64 public constant TERM = 7 days;
    uint256 public constant BORROW_APR_WAD = 0.05e18;
    uint256 public constant PROTOCOL_CUT_WAD = 0.2e18;

    error BroadcastBlocked();
    error WrongChain();
    error MustDeployPaused();

    /// @dev Flip only after Dylan provides a deployer wallet and the deploy is reviewed.
    function broadcastArmed() public pure returns (bool) {
        return false;
    }

    function run() external {
        if (!broadcastArmed()) revert BroadcastBlocked();
        if (block.chainid != 4663) revert WrongChain();

        address vaultOwner = vm.envAddress("VAULT_OWNER");
        address oracle = vm.envAddress("ORACLE_ADDRESS");

        vm.startBroadcast();
        LeveredLpVault vault = new LeveredLpVault(
            MSTR,
            USDG,
            oracle,
            TERM,
            BORROW_APR_WAD,
            PROTOCOL_CUT_WAD,
            vaultOwner
        );
        vm.stopBroadcast();

        if (!vault.paused()) revert MustDeployPaused();
    }
}
