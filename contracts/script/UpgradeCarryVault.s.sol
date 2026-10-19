// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LeveredLpVault} from "../src/LeveredLpVault.sol";
import {LeveredLpVaultV2} from "../src/LeveredLpVaultV2.sol";
import {IERC20Minimal} from "../src/interfaces/IERC20Minimal.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title UpgradeCarryVault / DeployCarryV3
/// @notice Deploys fresh Carry v3 lender-pool PROXY (does NOT upgrade live v2.5 PROXY).
///         Live v2.5 product CA 0xc801…72bd is superseded (open settle-watch stays there).
///
/// Live:
///   broadcastArmed() == true, DEPLOYER_PRIVATE_KEY (= owner), chain 46630.
///
/// Never prints keys.
contract UpgradeCarryVault is Script {
    uint256 public constant RH_TESTNET_CHAIN_ID = 46630;
    address public constant SUPERSEDED_V25_PROXY = 0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd;
    /// @dev Dollar amounts, scaled by the USDG token's own decimals (real USDG has 6).
    uint256 public constant CAP_JUNIOR_DOLLARS = 25_000;
    uint256 public constant CAP_SENIOR = 0; // uncapped pool
    uint256 public constant MIN_DEPOSIT_DOLLARS = 25;
    uint256 public constant MORPHO = 0.039e18;
    uint64 public constant TERM = 7 days;

    error BroadcastBlocked();
    error WrongChain();
    error MainnetForbidden();

    function broadcastArmed() public pure returns (bool) {
        return false;
    }

    function run() external {
        if (block.chainid == 4663 || block.chainid == 1) revert MainnetForbidden();

        bool live = broadcastArmed() && block.chainid == RH_TESTNET_CHAIN_ID;
        if (broadcastArmed() && block.chainid != RH_TESTNET_CHAIN_ID) revert WrongChain();

        address mstr = vm.envAddress("MSTR");
        address usdg = vm.envAddress("USDG");
        address oracle = vm.envAddress("ORACLE");
        address owner_ = vm.envOr("VAULT_OWNER", msg.sender);

        if (live) {
            vm.startBroadcast();
        } else {
            console2.log("DRY-RUN: broadcastArmed=false; no broadcast txs");
        }

        LeveredLpVaultV2 impl = new LeveredLpVaultV2();
        bytes memory initData = abi.encodeCall(
            LeveredLpVault.initialize, (mstr, usdg, oracle, TERM, MORPHO, owner_)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        LeveredLpVault vault = LeveredLpVault(address(proxy));

        if (live) {
            uint256 unit = 10 ** IERC20Minimal(usdg).decimals();
            vault.setDepositCaps(CAP_SENIOR, CAP_JUNIOR_DOLLARS * unit);
            vault.setMinDepositUsdg(MIN_DEPOSIT_DOLLARS * unit);
            vault.setGasRefundWei(0.0001 ether);
            vault.unpause();
            vm.stopBroadcast();
        }

        console2.log("chainId", block.chainid);
        console2.log("supersededV25Proxy", SUPERSEDED_V25_PROXY);
        console2.log("v3Proxy", address(proxy));
        console2.log("v3Implementation", address(impl));
        console2.log("version", vault.version());
        console2.log("maxTotalSeniorUsdg", vault.maxTotalSeniorUsdg());
        console2.log("maxTotalJuniorUsdg", vault.maxTotalJuniorUsdg());
        console2.log("minDepositUsdg", vault.minDepositUsdg());
    }
}
