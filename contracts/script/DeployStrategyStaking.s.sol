// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LeveredLpVault} from "../src/LeveredLpVault.sol";
import {StrategyStaking} from "../src/StrategyStaking.sol";
import {IStrategyStaking} from "../src/interfaces/IStrategyStaking.sol";
import {IERC20Minimal} from "../src/interfaces/IERC20Minimal.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title DeployStrategyStaking
/// @notice Testnet 46630 rehearsal: STRATEGY staking (+ mock STRATEGY) wired into a fresh v3 PROXY.
///
/// Env (never printed):
///   DEPLOYER_PRIVATE_KEY
///   STRATEGY (optional; a mock STRATEGY is deployed when unset)
///   VAULT    (optional; fresh PROXY from DeployCarryV3 to call setStrategyStaking on, as its owner)
///   STAKING_OWNER (defaults to msg.sender / deployer; mainnet must be a multisig behind a timelock)
///
/// Set broadcastArmed() to true for live broadcast.
contract DeployStrategyStaking is Script {
    uint256 public constant RH_TESTNET_CHAIN_ID = 46630;
    uint256 public constant COOLDOWN = 7 days;

    error WrongChain();
    error MainnetForbidden();

    function broadcastArmed() public pure returns (bool) {
        return false;
    }

    function run() external {
        if (block.chainid == 4663 || block.chainid == 1) revert MainnetForbidden();
        if (broadcastArmed() && block.chainid != RH_TESTNET_CHAIN_ID) revert WrongChain();
        bool live = broadcastArmed();

        address strategy = vm.envOr("STRATEGY", address(0));
        address vault = vm.envOr("VAULT", address(0));

        if (live) vm.startBroadcast();
        else console2.log("DRY-RUN: broadcastArmed=false; no broadcast txs");

        if (strategy == address(0)) strategy = address(new MockERC20("Mock STRATEGY", "STRATEGY", 18));
        StrategyStaking impl = new StrategyStaking();
        bytes memory init = abi.encodeCall(
            StrategyStaking.initialize, (IERC20Minimal(strategy), COOLDOWN, vm.envOr("STAKING_OWNER", msg.sender))
        );
        StrategyStaking staking = StrategyStaking(address(new ERC1967Proxy(address(impl), init)));
        if (vault != address(0)) LeveredLpVault(vault).setStrategyStaking(IStrategyStaking(address(staking)));

        if (live) vm.stopBroadcast();

        console2.log("chainId", block.chainid);
        console2.log("strategy", strategy);
        console2.log("strategyStakingProxy", address(staking));
        console2.log("strategyStakingImplementation", address(impl));
        console2.log("stakingOwner", staking.owner());
        console2.log("cooldown", staking.cooldown());
        console2.log("vault", vault);
    }
}
