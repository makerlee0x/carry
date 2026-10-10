// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LeveredLpVault} from "../src/LeveredLpVault.sol";

/// @notice Deploy a fresh proxy against an existing implementation (clean book).
contract DeployProxyOnly is Script {
    function run() external {
        address impl = vm.envAddress("IMPL_ADDRESS");
        address mstr = vm.envAddress("MSTR_ADDRESS");
        address usdg = vm.envAddress("USDG_ADDRESS");
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        address owner_ = vm.envAddress("VAULT_OWNER");
        uint64 term = uint64(vm.envOr("TERM", uint256(7 days)));
        uint256 morpho = vm.envOr("MORPHO_RATE_WAD", uint256(0.039e18));

        vm.startBroadcast();
        bytes memory initData =
            abi.encodeCall(LeveredLpVault.initialize, (mstr, usdg, oracle, term, morpho, owner_));
        ERC1967Proxy proxy = new ERC1967Proxy(impl, initData);
        vm.stopBroadcast();

        LeveredLpVault vault = LeveredLpVault(address(proxy));
        console2.log("implementation", impl);
        console2.log("proxy", address(proxy));
        console2.log("paused", vault.paused());
        console2.log("owner", vault.owner());
    }
}
