// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
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
import {MockOracle} from "../../src/mocks/MockOracle.sol";
import {MockMstrSellRouter} from "../../src/mocks/MockMstrSellRouter.sol";
import {CarryStrategy} from "../../src/CarryStrategy.sol";
import {LeveredLpVault} from "../../src/LeveredLpVault.sol";
import {ICarryStrategy} from "../../src/interfaces/ICarryStrategy.sol";
import {DualPoolKey} from "../../src/interfaces/IDualPoolLp.sol";

/// @notice Stage 2 pool flow with real-USDG decimals (6) against an 18-decimal stock, on a real v4
///         PoolManager and the real hook. MSTR is priced at $1 so value checks read in whole dollars.
contract VaultDualPool6DecTest is Test {
    uint256 constant Q96 = 2 ** 96;

    PoolManager pm;
    PoolSwapTest swapRouter;
    DualPoolHook hook;
    MockMorphoVault morpho;
    MockOracle oracle;
    CarryStrategy strat;
    LeveredLpVault vault;
    MockERC20 usdg;
    MockERC20 mstr;
    PoolKey key;

    address operator = address(0x0B0B);
    address trader = address(0x7A7E);
    address lender = address(0x1E1D);
    address junior = address(0x10C0);

    function setUp() public {
        vm.warp(1_000_000);
        pm = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(pm)));
        usdg = new MockERC20("USDG", "USDG", 6);
        mstr = new MockERC20("MSTR", "MSTR", 18);
        morpho = new MockMorphoVault(IERC20(address(usdg)), 0.04e18);
        oracle = new MockOracle(1e18);

        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
        address hookAddr = address(uint160(flags) | (uint160(0x4444) << 144));
        deployCodeTo(
            "DualPoolHook.sol:DualPoolHook", abi.encode(address(pm), uint32(500_000), operator, uint64(0)), hookAddr
        );
        hook = DualPoolHook(hookAddr);

        bool usdgIs0 = address(usdg) < address(mstr);
        (address c0, address c1) = usdgIs0 ? (address(usdg), address(mstr)) : (address(mstr), address(usdg));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(hookAddr));
        // $1 = 1e6 USDG units = 1e18 MSTR units, so raw price token1/token0 is 1e12 or 1e-12.
        uint160 sqrtP = uint160(usdgIs0 ? Q96 * 1e6 : Q96 / 1e6);
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        tick = tick / 60 * 60;

        LiquidityBucket[] memory buckets = new LiquidityBucket[](1);
        buckets[0] = LiquidityBucket({tickLower: tick - 600, tickUpper: tick + 600, weightBps: 10_000});
        IERC4626 v0 = usdgIs0 ? IERC4626(address(morpho)) : IERC4626(address(0));
        IERC4626 v1 = usdgIs0 ? IERC4626(address(0)) : IERC4626(address(morpho));
        vm.prank(operator);
        hook.initializePool(key, DualPoolHook.PoolConfig(sqrtP, buckets, true, v0, v1, 0));

        usdg.mint(operator, 100_000e6);
        mstr.mint(operator, 100_000e18);
        vm.startPrank(operator);
        usdg.approve(address(hook), type(uint256).max);
        mstr.approve(address(hook), type(uint256).max);
        hook.bootstrap(key, usdgIs0 ? 100_000e6 : 100_000e18, usdgIs0 ? 100_000e18 : 100_000e6);
        vm.stopPrank();

        LeveredLpVault impl = new LeveredLpVault();
        bytes memory init = abi.encodeCall(
            LeveredLpVault.initialize, (address(mstr), address(usdg), address(oracle), uint64(7 days), 0, address(this))
        );
        vault = LeveredLpVault(address(new ERC1967Proxy(address(impl), init)));
        vault.unpause();
        strat = new CarryStrategy(address(vault), IERC4626(address(morpho)));
        vault.setStrategy(ICarryStrategy(address(strat)));
        vault.setMarketPool(0, DualPoolKey(c0, c1, 3000, 60, hookAddr));
        MockMstrSellRouter sellRouter = new MockMstrSellRouter(address(usdg));
        sellRouter.setPrice(address(mstr), 1e18);
        usdg.mint(address(sellRouter), 1_000_000e6);
        vault.setSellSharesRouter(address(sellRouter));

        usdg.mint(trader, 1_000_000e6);
        mstr.mint(trader, 1_000_000e18);
        vm.startPrank(trader);
        usdg.approve(address(swapRouter), type(uint256).max);
        mstr.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(bool sellMstr, uint256 amountIn) internal {
        bool zeroForOne = sellMstr == (address(mstr) < address(usdg));
        vm.prank(trader);
        swapRouter.swap(
            key,
            SwapParams(
                zeroForOne, -int256(amountIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _open() internal returns (uint256 id) {
        usdg.mint(lender, 1_000e6);
        vm.startPrank(lender);
        usdg.approve(address(vault), 1_000e6);
        vault.depositSenior(1_000e6);
        vm.stopPrank();
        mstr.mint(junior, 1_000e18);
        vm.startPrank(junior);
        mstr.approve(address(vault), 1_000e18);
        id = vault.depositJunior(1_000e18);
        vm.stopPrank();
    }

    function test_6dec_entersPoolAtTheRightSize() public {
        uint256 id = _open();
        assertTrue(vault.isFullyMatched(id));
        assertEq(vault.reservedSenior(), 1_000e6, "$1,000 matched in 6-decimal units");
        assertGt(vault.positionPoolShares(id), 0);
        assertApproxEqRel(vault.poolDeployed(), 1_000e6, 1e15, "about $1,000 of USDG in the pool");
        assertLt(mstr.balanceOf(address(vault)), 1e15, "stock went in");
    }

    function test_6dec_feesSplit_andEveryoneWhole() public {
        uint256 id = _open();
        uint256 navBefore = vault.totalSeniorAssets();
        uint256 backstopBefore = vault.backstop();
        for (uint256 i; i < 5; i++) {
            _swap(true, 20_000e18);
            _swap(false, 20_000e6);
        }
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(junior);
        vault.settle(id);

        uint256 treasury = vault.backstop() - backstopBefore;
        uint256 lenderGain = vault.totalSeniorAssets() - navBefore;
        uint256 morphoYield = uint256(1_000e6) * 4 / 100 * 7 days / 365 days;
        assertGt(treasury, 0, "fees earned");
        assertApproxEqRel(lenderGain, morphoYield + 2 * treasury, 0.02e18, "senior 40% vs treasury 20%");
        assertEq(vault.poolDeployed(), 0);
        uint256 cash = usdg.balanceOf(address(vault)) + vault.strategyDeployed();
        assertGe(cash + 1, vault.totalSeniorAssets() + vault.backstop() + vault.totalUnsplitFees(), "solvent");
    }

    function test_6dec_earlyExit_returnsStock() public {
        uint256 id = _open();
        uint256 navBefore = vault.totalSeniorAssets();
        vm.prank(junior);
        vault.earlyExit(id);
        assertApproxEqRel(mstr.balanceOf(junior), 1_000e18, 1e15, "stock back");
        assertGe(vault.totalSeniorAssets() + 1, navBefore);
    }
}
