// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {DualPoolHook} from "../src/alf/DualPoolHook.sol";
import {LiquidityBucket} from "../src/alf/types/Distribution.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockMorphoVault} from "../../src/mocks/MockMorphoVault.sol";
import {CarryStrategy} from "../../src/CarryStrategy.sol";
import {IDualPoolLp, DualPoolKey} from "../../src/interfaces/IDualPoolLp.sol";

/// @notice Carry strategy against Uniswap's real DualPoolHook on a real v4 PoolManager, with a
///         mock Morpho vault holding the pool's idle USDG.
contract CarryStrategyDualPoolTest is Test {
    uint160 constant SQRT_1_1 = 79228162514264337593543950336;

    PoolManager pm;
    PoolSwapTest router;
    DualPoolHook hook;
    MockMorphoVault morpho;
    CarryStrategy strat;
    MockERC20 usdg;
    MockERC20 mstr;
    PoolKey key;
    DualPoolKey dKey;
    address carryVault = address(0xCA11);
    address operator = address(0x0B0B);
    address trader = address(0x7A7E);

    function setUp() public {
        pm = new PoolManager(address(this));
        router = new PoolSwapTest(IPoolManager(address(pm)));

        MockERC20 a = new MockERC20("USDG", "USDG", 18);
        MockERC20 b = new MockERC20("MSTR", "MSTR", 18);
        (usdg, mstr) = (a, b);
        morpho = new MockMorphoVault(IERC20(address(usdg)), 0.04e18);

        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
        address hookAddr = address(uint160(flags) | (uint160(0x4444) << 144));
        deployCodeTo("DualPoolHook.sol:DualPoolHook", abi.encode(address(pm), uint32(500_000), operator, uint64(0)), hookAddr);
        hook = DualPoolHook(hookAddr);

        (address c0, address c1) = address(usdg) < address(mstr) ? (address(usdg), address(mstr)) : (address(mstr), address(usdg));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(hookAddr));
        dKey = DualPoolKey(c0, c1, 3000, 60, hookAddr);

        LiquidityBucket[] memory buckets = new LiquidityBucket[](1);
        buckets[0] = LiquidityBucket({tickLower: -600, tickUpper: 600, weightBps: 10_000});
        IERC4626 v0 = c0 == address(usdg) ? IERC4626(address(morpho)) : IERC4626(address(0));
        IERC4626 v1 = c1 == address(usdg) ? IERC4626(address(morpho)) : IERC4626(address(0));
        vm.prank(operator);
        hook.initializePool(key, DualPoolHook.PoolConfig(SQRT_1_1, buckets, true, v0, v1, 0));

        // operator seeds the pool (owner-only bootstrap)
        usdg.mint(operator, 1_000_000e18);
        mstr.mint(operator, 1_000_000e18);
        vm.startPrank(operator);
        usdg.approve(address(hook), type(uint256).max);
        mstr.approve(address(hook), type(uint256).max);
        hook.bootstrap(key, 1_000_000e18, 1_000_000e18);
        vm.stopPrank();

        strat = new CarryStrategy(carryVault, IERC4626(address(morpho)));
        usdg.mint(carryVault, 10_000e18);
        mstr.mint(carryVault, 10_000e18);
        vm.startPrank(carryVault);
        usdg.approve(address(strat), type(uint256).max);
        mstr.approve(address(strat), type(uint256).max);
        vm.stopPrank();

        usdg.mint(trader, 100_000e18);
        mstr.mint(trader, 100_000e18);
        vm.startPrank(trader);
        usdg.approve(address(router), type(uint256).max);
        mstr.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        vm.prank(trader);
        router.swap(
            key,
            SwapParams(zeroForOne, -int256(amountIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function test_poolIdleUsdgSitsInMorphoBetweenSwaps() public {
        // all the pool's USDG is in the Morpho vault, none loose in the hook
        assertEq(usdg.balanceOf(address(hook)), 0);
        assertGt(morpho.balanceOf(address(hook)), 0);
        _swap(address(usdg) < address(mstr), 1_000e18);
        assertEq(usdg.balanceOf(address(hook)), 0, "usdg returned to morpho after swap");
        assertGt(morpho.balanceOf(address(hook)), 0);
    }

    function test_strategyLpsInAndOutOfDualPool() public {
        uint256 vaultUsdg = usdg.balanceOf(carryVault);
        uint256 vaultMstr = mstr.balanceOf(carryVault);

        vm.prank(carryVault);
        (uint256 a0, uint256 a1) = strat.addLp(IDualPoolLp(address(hook)), dKey, 1_000e18, 5_000e18, 5_000e18, block.timestamp + 1);
        assertGt(a0 + a1, 0);
        uint256 shares = strat.lpShares(IDualPoolLp(address(hook)), dKey);
        assertEq(shares, 1_000e18);
        assertEq(usdg.balanceOf(address(strat)), 0, "no loose usdg in strategy");
        assertEq(mstr.balanceOf(address(strat)), 0, "no loose mstr in strategy");

        // unused part of the allowance came straight back
        assertEq(usdg.balanceOf(carryVault) + mstr.balanceOf(carryVault) + a0 + a1, vaultUsdg + vaultMstr);

        // two-way flow earns the pool fee
        _swap(true, 20_000e18);
        _swap(false, 20_000e18);

        vm.prank(carryVault);
        strat.removeLp(IDualPoolLp(address(hook)), dKey, shares, 0, 0, block.timestamp + 1);
        assertEq(strat.lpShares(IDualPoolLp(address(hook)), dKey), 0);
        assertEq(usdg.balanceOf(address(strat)) + mstr.balanceOf(address(strat)), 0);
        assertGe(usdg.balanceOf(carryVault) + mstr.balanceOf(carryVault), vaultUsdg + vaultMstr - 1e12, "no loss beyond dust");
    }

    function test_idleLegAndPoolLegWorkTogether() public {
        vm.startPrank(carryVault);
        strat.deposit(2_000e18);
        strat.addLp(IDualPoolLp(address(hook)), dKey, 500e18, 3_000e18, 3_000e18, block.timestamp + 1);
        vm.stopPrank();
        skip(365 days);
        assertApproxEqAbs(strat.idleAssets(), 2_080e18, 2e18);
    }

    function test_onlyVaultCanLp() public {
        vm.expectRevert(CarryStrategy.NotVault.selector);
        strat.addLp(IDualPoolLp(address(hook)), dKey, 1e18, 1e18, 1e18, block.timestamp + 1);
        vm.expectRevert(CarryStrategy.NotVault.selector);
        strat.removeLp(IDualPoolLp(address(hook)), dKey, 1e18, 0, 0, block.timestamp + 1);
    }
}
