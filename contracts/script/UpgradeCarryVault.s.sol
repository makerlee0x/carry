// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LeveredLpVault} from "../src/LeveredLpVault.sol";
import {LeveredLpVaultV2} from "../src/LeveredLpVaultV2.sol";

/// @title UpgradeCarryVault
/// @notice Deploys LeveredLpVaultV2 (v2.5-funder-idle) and UUPS-upgrades the product PROXY.
///         Migrates live #5/#6/#7 funder-idle accounting in the same broadcast.
///
/// Live:
///   broadcastArmed() == true, DEPLOYER_PRIVATE_KEY (= owner), chain 46630.
///   PROXY_ADDRESS defaults to product CA.
///
/// Never prints keys. Does not early-exit or settle open settle-watch positions.
contract UpgradeCarryVault is Script {
    uint256 public constant RH_TESTNET_CHAIN_ID = 46630;
    address public constant DEFAULT_PROXY = 0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd;
    uint256 public constant CAP_TOTAL = 25_000 ether;
    /// @notice Per-wallet cap removed (0 = unlimited). Keep $25k market totals.
    uint256 public constant CAP_PER_WALLET = 0;
    uint256 public constant MIN_DEPOSIT = 25 ether;

    // Live seniors for migrateAccountingV25 (re-queried before broadcast).
    address public constant SENIOR_DEPLOYER = 0xcA44F2dbB2D43b93b39F01B88E0f0e2966983c57;
    address public constant SENIOR_A = 0x6943f0875AA9138F1E65a27Be48Af4312751651c;
    address public constant SENIOR_B = 0x2f1BB0AA6118f0c172A3d8b4d1D45b2F626E74Bf;
    address public constant SENIOR_DUST = 0x76339f8D6640D6dF94037D87c2c9503C98391803;
    address public constant SENIOR_C = 0xa3aBBE82c795858d77814A6714F8103323d860ea;

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
            vm.startBroadcast();
        } else {
            console2.log("DRY-RUN: broadcastArmed=false; no broadcast txs");
        }

        LeveredLpVaultV2 impl = new LeveredLpVaultV2();
        if (live) {
            if (proxy.owner() != msg.sender) revert NotOwner();
            // Storage-additive upgrade. Same PROXY CA. Does not touch open position clocks/fees.
            proxy.upgradeToAndCall(address(impl), "");

            // Seed per-lender idle + funder slices for open matched positions #5/#6/#7.
            _migrateLive(proxy);

            proxy.setDepositCaps(CAP_TOTAL, CAP_TOTAL, CAP_PER_WALLET);
            proxy.setMinDepositUsdg(MIN_DEPOSIT);
            uint256[] memory mins = new uint256[](3);
            uint256[] memory cuts = new uint256[](3);
            mins[0] = 100 ether;
            cuts[0] = 0.15e18;
            mins[1] = 1_000 ether;
            cuts[1] = 0.1e18;
            mins[2] = 10_000 ether;
            cuts[2] = 0.05e18;
            proxy.setBoostTiers(mins, cuts);
            proxy.setTreasuryCuts(0.2e18, 0.1e18);
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
            console2.log("minDepositUsdg", proxy.minDepositUsdg());
            console2.log("accountingMigrated", proxy.accountingMigrated());
            console2.log("gasRefundWei", proxy.gasRefundWei());
        }
    }

    /// @dev Attribution from live PositionMatched + SeniorDeposit order (FIFO idle).
    ///      #5: deployer 100
    ///      #6: dust 1.999… then A 769.700…
    ///      #7: A remainder 230.299… then B 78.380…
    ///      Idle: B 421.619… + C 2500 (A/dust/deployer fully matched).
    function _migrateLive(LeveredLpVault proxy) internal {
        address[] memory seniors = new address[](5);
        uint256[] memory idles = new uint256[](5);
        seniors[0] = SENIOR_DEPLOYER;
        idles[0] = 0;
        seniors[1] = SENIOR_A;
        idles[1] = 0;
        seniors[2] = SENIOR_B;
        idles[2] = 421_619_997_922_374_429_225;
        seniors[3] = SENIOR_DUST;
        idles[3] = 0;
        seniors[4] = SENIOR_C;
        idles[4] = 2500 ether;

        // 5 funder slices across #5/#6/#7
        uint256[] memory positionIds = new uint256[](5);
        address[] memory funders = new address[](5);
        uint256[] memory amounts = new uint256[](5);
        uint64[] memory matchedAts = new uint64[](5);

        positionIds[0] = 5;
        funders[0] = SENIOR_DEPLOYER;
        amounts[0] = 100 ether;
        matchedAts[0] = 1_791_603_471;

        positionIds[1] = 6;
        funders[1] = SENIOR_DUST;
        amounts[1] = 1_999_997_922_374_429_225;
        matchedAts[1] = 1_791_684_461;

        positionIds[2] = 6;
        funders[2] = SENIOR_A;
        amounts[2] = 769_700_002_077_625_570_775;
        matchedAts[2] = 1_791_684_461;

        positionIds[3] = 7;
        funders[3] = SENIOR_A;
        amounts[3] = 230_299_997_922_374_429_225;
        matchedAts[3] = 1_791_686_438;

        positionIds[4] = 7;
        funders[4] = SENIOR_B;
        amounts[4] = 78_380_002_077_625_570_775;
        matchedAts[4] = 1_791_686_438;

        proxy.migrateAccountingV25(seniors, idles, positionIds, funders, amounts, matchedAts);
    }
}
