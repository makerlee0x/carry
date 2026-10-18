// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {DeployLeveredLpVault} from "../script/DeployLeveredLpVault.s.sol";
import {DeployCarryTestnet} from "../script/DeployCarryTestnet.s.sol";
import {DeployStrategyStaking} from "../script/DeployStrategyStaking.s.sol";

/// @dev Kept separate from LeveredLpVault.t.sol so via-IR does not hit jump-tag limits
///      when compiling the vault + script deploy graphs in one unit.
contract DeployScriptsTest is Test {
    function test_broadcastDisarmed() public {
        DeployLeveredLpVault deploy = new DeployLeveredLpVault();
        assertFalse(deploy.broadcastArmed());
        vm.expectRevert(DeployLeveredLpVault.BroadcastBlocked.selector);
        deploy.run();
    }

    function test_strategyStakingScriptDisarmed() public {
        DeployStrategyStaking deploy = new DeployStrategyStaking();
        assertFalse(deploy.broadcastArmed());
        deploy.run();
    }

    function test_strategyStakingScriptRefusesMainnet() public {
        DeployStrategyStaking deploy = new DeployStrategyStaking();
        vm.chainId(4663);
        vm.expectRevert(DeployStrategyStaking.MainnetForbidden.selector);
        deploy.run();
    }

    function test_carryTestnetScriptDisarmed() public {
        DeployCarryTestnet deploy = new DeployCarryTestnet();
        assertFalse(deploy.broadcastArmed());
        deploy.run();
    }
}
