// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LeveredLpVault} from "../src/LeveredLpVault.sol";

/// @title DeployCarryVaultV2
/// @notice Deploys UUPS implementation + ERC1967Proxy on Robinhood testnet (46630).
///         Reuses existing mock MSTR/USDG/oracle from the v1 grant deploy when addresses
///         are provided via env; otherwise deploys fresh mocks (anvil dry-run).
///
/// Live broadcast:
///   broadcastArmed() == true, DEPLOYER_PRIVATE_KEY, VAULT_OWNER, chain 46630.
///   Optional: MSTR_ADDRESS, USDG_ADDRESS, ORACLE_ADDRESS (reuse v1 mocks).
///
/// Product CA = PROXY. Future upgrades keep the same proxy address.
contract DeployCarryVaultV2 is Script {
    uint256 public constant RH_TESTNET_CHAIN_ID = 46630;
    uint256 public constant ANVIL_CHAIN_ID = 31337;
    uint64 public constant TERM = 7 days;
    uint256 public constant MORPHO_RATE_WAD = 0.039e18;

    // v1 grant deploy mocks (46630) — reused so token addresses stay stable in config.
    address public constant V1_MOCK_MSTR = 0x762019309B536bbb89577422FaaFBeC9659f8728;
    address public constant V1_MOCK_USDG = 0x25030Bff74764aD72b912276a603717DB1C00644;
    address public constant V1_MOCK_ORACLE = 0xc74Af7E23A2B4b46B5Fe05E5c7c5ec0BB5dbc5B7;

    error BroadcastBlocked();
    error WrongChain();
    error MustDeployPaused();
    error MainnetForbidden();

    /// @dev Flip only for reviewed live broadcast. Tests assert false by default.
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

        address mstrAddr = vm.envOr("MSTR_ADDRESS", liveBroadcast ? V1_MOCK_MSTR : address(0));
        address usdgAddr = vm.envOr("USDG_ADDRESS", liveBroadcast ? V1_MOCK_USDG : address(0));
        address oracleAddr = vm.envOr("ORACLE_ADDRESS", liveBroadcast ? V1_MOCK_ORACLE : address(0));

        if (liveBroadcast) {
            vm.startBroadcast();
        } else {
            console2.log("DRY-RUN: broadcastArmed=false or not on 46630; no broadcast txs");
        }

        if (mstrAddr == address(0) || usdgAddr == address(0) || oracleAddr == address(0)) {
            // Anvil / local: deploy mocks via inline minimal path
            revert("Set MSTR_ADDRESS USDG_ADDRESS ORACLE_ADDRESS or use DeployCarryTestnet for full stack");
        }

        LeveredLpVault impl = new LeveredLpVault();
        bytes memory initData = abi.encodeCall(
            LeveredLpVault.initialize, (mstrAddr, usdgAddr, oracleAddr, TERM, MORPHO_RATE_WAD, vaultOwner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        LeveredLpVault vault = LeveredLpVault(address(proxy));

        if (liveBroadcast) {
            vm.stopBroadcast();
        }

        if (!vault.paused()) revert MustDeployPaused();
        if (broadcastArmed() && !liveBroadcast) revert BroadcastBlocked();

        console2.log("chainId", block.chainid);
        console2.log("implementation", address(impl));
        console2.log("proxy", address(proxy));
        console2.log("vaultOwner", vaultOwner);
        console2.log("mstr", mstrAddr);
        console2.log("usdg", usdgAddr);
        console2.log("oracle", oracleAddr);
        console2.log("paused", vault.paused());
        console2.log("morphoRateWad", vault.morphoRateWad());
    }
}
