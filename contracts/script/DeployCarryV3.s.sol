// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LeveredLpVault} from "../src/LeveredLpVault.sol";
import {LeveredLpVaultV2} from "../src/LeveredLpVaultV2.sol";

/// @title DeployCarryV3
/// @notice Fresh UUPS PROXY for Carry v3 lender-pool on Robinhood Chain Testnet 46630.
///         Does NOT upgrade superseded v2.5 PROXY 0xc801…72bd.
///
/// Env (never printed):
///   DEPLOYER_PRIVATE_KEY
///   MSTR / USDG / ORACLE (defaults = live testnet mocks from config.json)
///   VAULT_OWNER (defaults to msg.sender / deployer)
///
/// Set broadcastArmed() to true for live broadcast.
contract DeployCarryV3 is Script {
    uint256 public constant RH_TESTNET_CHAIN_ID = 46630;
    address public constant SUPERSEDED_V25_PROXY = 0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd;
    address public constant DEFAULT_MSTR = 0x762019309B536bbb89577422FaaFBeC9659f8728;
    address public constant DEFAULT_USDG = 0x25030Bff74764aD72b912276a603717DB1C00644;
    address public constant DEFAULT_ORACLE = 0xc74Af7E23A2B4b46B5Fe05E5c7c5ec0BB5dbc5B7;

    uint256 public constant CAP_SENIOR = 0;
    uint256 public constant CAP_JUNIOR = 25_000 ether;
    uint256 public constant CAP_PER_WALLET = 0;
    uint256 public constant MIN_DEPOSIT = 25 ether;
    uint256 public constant MORPHO = 0.039e18;
    uint64 public constant TERM = 7 days;

    error WrongChain();
    error MainnetForbidden();

    function broadcastArmed() public pure returns (bool) {
        return false;
    }

    function run() external {
        if (block.chainid == 4663 || block.chainid == 1) revert MainnetForbidden();
        bool live = broadcastArmed() && block.chainid == RH_TESTNET_CHAIN_ID;
        if (broadcastArmed() && block.chainid != RH_TESTNET_CHAIN_ID) revert WrongChain();

        address mstr = vm.envOr("MSTR", DEFAULT_MSTR);
        address usdg = vm.envOr("USDG", DEFAULT_USDG);
        address oracle = vm.envOr("ORACLE", DEFAULT_ORACLE);

        if (live) vm.startBroadcast();
        else console2.log("DRY-RUN: broadcastArmed=false; no broadcast txs");

        LeveredLpVaultV2 impl = new LeveredLpVaultV2();
        address owner_ = vm.envOr("VAULT_OWNER", msg.sender);
        bytes memory initData =
            abi.encodeCall(LeveredLpVault.initialize, (mstr, usdg, oracle, TERM, MORPHO, owner_));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        LeveredLpVault vault = LeveredLpVault(address(proxy));

        if (live) {
            vault.setDepositCaps(CAP_SENIOR, CAP_JUNIOR, CAP_PER_WALLET);
            vault.setMinDepositUsdg(MIN_DEPOSIT);
            vault.setGasRefundWei(0.0001 ether);
            vault.unpause();
            vm.stopBroadcast();
        }

        console2.log("chainId", block.chainid);
        console2.log("supersededV25Proxy", SUPERSEDED_V25_PROXY);
        console2.log("v3Proxy", address(proxy));
        console2.log("v3Implementation", address(impl));
        console2.log("version", vault.version());
        console2.log("owner", vault.owner());
        console2.log("maxTotalSeniorUsdg", vault.maxTotalSeniorUsdg());
        console2.log("maxTotalJuniorUsdg", vault.maxTotalJuniorUsdg());
        console2.log("paused", vault.paused());
    }
}
