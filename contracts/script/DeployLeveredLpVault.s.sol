// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LeveredLpVault} from "../src/LeveredLpVault.sol";

/// @title DeployLeveredLpVault
/// @notice Robinhood Chain (chain id 4663) ONLY. Refuses every other chain.
/// BROADCAST IS BLOCKED until armed. Product CA = PROXY (UUPS).
contract DeployLeveredLpVault is Script {
    address public constant MSTR = 0xec262a75e413fAfD0dF80480274532C79D42da09;
    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint64 public constant TERM = 7 days;
    uint256 public constant MORPHO_RATE_WAD = 0.039e18;

    error BroadcastBlocked();
    error WrongChain();
    error MustDeployPaused();

    function broadcastArmed() public pure returns (bool) {
        return false;
    }

    function run() external {
        if (!broadcastArmed()) revert BroadcastBlocked();
        if (block.chainid != 4663) revert WrongChain();

        address vaultOwner = vm.envAddress("VAULT_OWNER");
        address oracle = vm.envAddress("ORACLE_ADDRESS");

        vm.startBroadcast();
        LeveredLpVault implementation = new LeveredLpVault();
        bytes memory initData = abi.encodeCall(
            LeveredLpVault.initialize, (MSTR, USDG, oracle, TERM, MORPHO_RATE_WAD, vaultOwner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        LeveredLpVault vault = LeveredLpVault(address(proxy));
        vm.stopBroadcast();

        if (!vault.paused()) revert MustDeployPaused();
    }
}
