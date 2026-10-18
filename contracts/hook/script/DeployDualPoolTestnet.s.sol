// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {DualPoolHook} from "../src/alf/DualPoolHook.sol";
import {LiquidityBucket} from "../src/alf/types/Distribution.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockMorphoVault} from "../../src/mocks/MockMorphoVault.sol";
import {CarryStrategy} from "../../src/CarryStrategy.sol";

/// @notice Robinhood Chain testnet (46630): mock Morpho vault, our own DualPoolHook, the MSTR/USDG
///         pool, its first liquidity, and a CarryStrategy pointing at the Carry vault proxy.
///
///   FOUNDRY_PROFILE=hook forge script hook/script/DeployDualPoolTestnet.s.sol \
///     --use ~/.svm/0.8.26/solc-0.8.26 --rpc-url https://rpc.testnet.chain.robinhood.com
///                                              # needs DEPLOYER_KEY in the env; add --broadcast to send
///
/// Env: DEPLOYER_KEY (required). Optional: MORPHO_RATE_WAD (default 4%), MSTR_PRICE_WAD (default 154.34), POOL_FEE (3000),
/// BOOTSTRAP_USDG (default 10,000 USDG; MSTR side is sized at the pool price). The deployer becomes the
/// hook owner. Testnet USDG and MSTR are mintable mocks, so the script mints its own seed liquidity.
contract DeployDualPoolTestnet is Script {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant USDG = 0x25030Bff74764aD72b912276a603717DB1C00644;
    address constant MSTR = 0x762019309B536bbb89577422FaaFBeC9659f8728;
    address constant CARRY_VAULT = 0x24B799026AA7baa6856bCFD00c1Be1f583A83e35; // v3 proxy
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    int24 constant TICK_SPACING = 60;

    function run() external {
        uint256 morphoRate = vm.envOr("MORPHO_RATE_WAD", uint256(0.04e18));
        uint256 mstrPriceWad = vm.envOr("MSTR_PRICE_WAD", uint256(154.34e18));
        uint24 fee = uint24(vm.envOr("POOL_FEE", uint256(3000)));
        uint256 seedUsdg = vm.envOr("BOOTSTRAP_USDG", uint256(10_000e18));
        uint256 seedMstr = seedUsdg * 1e18 / mstrPriceWad;

        bool usdgIs0 = USDG < MSTR;
        (address c0, address c1) = usdgIs0 ? (USDG, MSTR) : (MSTR, USDG);
        // price of currency1 in currency0 (both 18 decimals)
        uint256 priceWad = usdgIs0 ? 1e36 / mstrPriceWad : mstrPriceWad;
        uint160 sqrtPriceX96 = uint160(FixedPointMathLib.sqrt((priceWad << 96) / 1e18 << 96));
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        LiquidityBucket[] memory buckets = new LiquidityBucket[](2);
        buckets[0] = _bucket(tick, 600, 7_000);
        buckets[1] = _bucket(tick, 2_400, 3_000);

        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);
        bytes memory args = abi.encode(POOL_MANAGER, uint32(500_000), deployer, uint64(0));
        (bytes32 salt, address hookAddr) = _mine(flags, abi.encodePacked(type(DualPoolHook).creationCode, args));

        vm.startBroadcast(deployerKey);
        MockMorphoVault morpho = new MockMorphoVault(IERC20(USDG), morphoRate);
        DualPoolHook hook = new DualPoolHook{salt: salt}(IPoolManager(POOL_MANAGER), 500_000, deployer, 0);
        require(address(hook) == hookAddr, "hook address mismatch");

        PoolKey memory key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, TICK_SPACING, IHooks(hookAddr));
        hook.initializePool(
            key,
            DualPoolHook.PoolConfig(
                sqrtPriceX96,
                buckets,
                true,
                usdgIs0 ? IERC4626(address(morpho)) : IERC4626(address(0)),
                usdgIs0 ? IERC4626(address(0)) : IERC4626(address(morpho)),
                0
            )
        );

        MockERC20(USDG).mint(deployer, seedUsdg);
        MockERC20(MSTR).mint(deployer, seedMstr);
        IERC20(USDG).approve(hookAddr, seedUsdg);
        IERC20(MSTR).approve(hookAddr, seedMstr);
        hook.bootstrap(key, usdgIs0 ? seedUsdg : seedMstr, usdgIs0 ? seedMstr : seedUsdg);

        CarryStrategy strategy = new CarryStrategy(CARRY_VAULT, IERC4626(address(morpho)));
        vm.stopBroadcast();

        console2.log("MockMorphoVault ", address(morpho));
        console2.log("DualPoolHook    ", hookAddr);
        console2.log("CarryStrategy   ", address(strategy));
        console2.log("currency0       ", c0);
        console2.log("currency1       ", c1);
        console2.log("initial tick    ", int256(tick));
    }

    function _bucket(int24 tick, int24 half, uint16 weight) internal pure returns (LiquidityBucket memory) {
        int24 lower = _floorToSpacing(tick - half);
        int24 upper = _floorToSpacing(tick + half) + TICK_SPACING;
        return LiquidityBucket({tickLower: lower, tickUpper: upper, weightBps: weight});
    }

    function _floorToSpacing(int24 t) internal pure returns (int24) {
        int24 r = t % TICK_SPACING;
        return r < 0 ? t - r - TICK_SPACING : t - r;
    }

    /// @dev The v4 hook address must carry the permission bits in its low 14 bits.
    function _mine(uint160 flags, bytes memory initCode) internal pure returns (bytes32 salt, address addr) {
        bytes32 initHash = keccak256(initCode);
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            addr = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initHash)))));
            if (uint160(addr) & Hooks.ALL_HOOK_MASK == flags) return (salt, addr);
        }
        revert("no salt found");
    }
}
