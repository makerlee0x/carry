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

/// @notice Stage 2: matched positions go into their market's DualPool pool on a real v4 PoolManager and the
///         real hook, and come back out split treasury / senior / junior.
contract VaultDualPoolTest is Test {
    uint160 constant SQRT_1_1 = 79228162514264337593543950336;

    PoolManager pm;
    PoolSwapTest swapRouter;
    DualPoolHook hook;
    MockMorphoVault morpho;
    MockOracle oracle;
    MockMstrSellRouter sellRouter;
    CarryStrategy strat;
    LeveredLpVault vault;
    MockERC20 usdg;
    MockERC20 mstr;
    PoolKey key;
    DualPoolKey dKey;

    address operator = address(0x0B0B);
    address trader = address(0x7A7E);
    address lender = address(0x1E1D);
    address junior = address(0x10C0);

    function setUp() public {
        vm.warp(1_000_000);
        pm = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(pm)));
        usdg = new MockERC20("USDG", "USDG", 18);
        mstr = new MockERC20("MSTR", "MSTR", 18);
        morpho = new MockMorphoVault(IERC20(address(usdg)), 0.04e18);
        oracle = new MockOracle(1e18); // the pool starts at 1:1, so MSTR is priced at $1 here

        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
        address hookAddr = address(uint160(flags) | (uint160(0x4444) << 144));
        deployCodeTo(
            "DualPoolHook.sol:DualPoolHook", abi.encode(address(pm), uint32(500_000), operator, uint64(0)), hookAddr
        );
        hook = DualPoolHook(hookAddr);

        (address c0, address c1) =
            address(usdg) < address(mstr) ? (address(usdg), address(mstr)) : (address(mstr), address(usdg));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(hookAddr));
        dKey = DualPoolKey(c0, c1, 3000, 60, hookAddr);

        LiquidityBucket[] memory buckets = new LiquidityBucket[](1);
        buckets[0] = LiquidityBucket({tickLower: -600, tickUpper: 600, weightBps: 10_000});
        IERC4626 v0 = c0 == address(usdg) ? IERC4626(address(morpho)) : IERC4626(address(0));
        IERC4626 v1 = c1 == address(usdg) ? IERC4626(address(morpho)) : IERC4626(address(0));
        vm.prank(operator);
        hook.initializePool(key, DualPoolHook.PoolConfig(SQRT_1_1, buckets, true, v0, v1, 0));

        usdg.mint(operator, 100_000e18);
        mstr.mint(operator, 100_000e18);
        vm.startPrank(operator);
        usdg.approve(address(hook), type(uint256).max);
        mstr.approve(address(hook), type(uint256).max);
        hook.bootstrap(key, 100_000e18, 100_000e18);
        vm.stopPrank();

        LeveredLpVault impl = new LeveredLpVault();
        bytes memory init = abi.encodeCall(
            LeveredLpVault.initialize, (address(mstr), address(usdg), address(oracle), uint64(7 days), 0, address(this))
        );
        vault = LeveredLpVault(address(new ERC1967Proxy(address(impl), init)));
        vault.unpause();
        strat = new CarryStrategy(address(vault), IERC4626(address(morpho)));
        vault.setStrategy(ICarryStrategy(address(strat)));
        vault.setMarketPool(0, dKey);
        sellRouter = new MockMstrSellRouter(address(usdg));
        sellRouter.setPrice(address(mstr), 1e18);
        usdg.mint(address(sellRouter), 1_000_000e18);
        vault.setSellSharesRouter(address(sellRouter));

        usdg.mint(trader, 1_000_000e18);
        mstr.mint(trader, 1_000_000e18);
        vm.startPrank(trader);
        usdg.approve(address(swapRouter), type(uint256).max);
        mstr.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _lend(uint256 amount) internal {
        usdg.mint(lender, amount);
        vm.startPrank(lender);
        usdg.approve(address(vault), amount);
        vault.depositSenior(amount);
        vm.stopPrank();
    }

    function _junior(uint256 amount) internal returns (uint256 id) {
        mstr.mint(junior, amount);
        vm.startPrank(junior);
        mstr.approve(address(vault), amount);
        id = vault.depositJunior(amount);
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

    function _poolShares(uint256 id) internal view returns (uint256) {
        return vault.positionPoolShares(id);
    }

    /// Cash the vault can reach covers everything it owes.
    function _assertSolvent() internal view {
        uint256 cash = usdg.balanceOf(address(vault)) + vault.strategyDeployed() + vault.poolDeployed();
        assertGe(cash + 1, vault.totalSeniorAssets() + vault.backstop() + vault.totalUnsplitFees(), "solvent");
        assertEq(usdg.balanceOf(address(strat)), 0, "no loose USDG in strategy");
        assertEq(mstr.balanceOf(address(strat)), 0, "no loose MSTR in strategy");
    }

    // ------------------------------------------------------------------ tests

    function test_fullMatchEntersThePool() public {
        _lend(1_000e18);
        uint256 id = _junior(1_000e18);
        assertTrue(vault.isFullyMatched(id));
        assertGt(_poolShares(id), 0, "position holds pool shares");
        assertEq(hook.sharesOf(key, address(strat)), _poolShares(id));
        assertApproxEqRel(vault.poolDeployed(), 1_000e18, 1e12, "senior USDG in the pool");
        assertLt(mstr.balanceOf(address(vault)), 1e12, "stock went into the pool (dust stays)");
        assertEq(vault.reservedSenior(), 1_000e18);
        _assertSolvent();
    }

    function test_partialMatchStaysOut() public {
        _lend(500e18);
        uint256 id = _junior(1_000e18);
        assertFalse(vault.isFullyMatched(id));
        assertEq(_poolShares(id), 0);
        _lend(500e18); // tops it up: now fully matched, so it enters
        vm.prank(junior);
        vault.setAutoCompound(false);
        // matching runs on the next junior or compound; trigger it with a tiny second junior
        _junior(30e18);
        assertGt(_poolShares(id), 0, "entered once fully matched");
    }

    /// Two-way flow earns fees: the result above holding splits 20% treasury / 40% senior / 40% junior.
    function test_feesSplit_treasurySeniorJunior() public {
        _lend(1_000e18);
        uint256 id = _junior(1_000e18);
        uint256 navBefore = vault.totalSeniorAssets();
        uint256 backstopBefore = vault.backstop();

        for (uint256 i; i < 5; i++) {
            _swap(true, 20_000e18);
            _swap(false, 20_000e18);
        }
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(junior);
        LeveredLpVault.Settlement memory s = vault.settle(id);

        uint256 treasury = vault.backstop() - backstopBefore;
        uint256 lenderGain = vault.totalSeniorAssets() - navBefore;
        assertGt(treasury, 0, "fees earned");
        // senior gain = Morpho yield on its pooled USDG + 2x the treasury cut (40% vs 20%)
        // senior gain = Morpho yield on its pooled USDG (4% for 7 days on ~1,000) + twice the treasury cut
        uint256 morphoYield = uint256(1_000e18) * 4 / 100 * 7 days / 365 days;
        assertApproxEqRel(lenderGain, morphoYield + 2 * treasury, 0.01e18, "senior 40% vs treasury 20%");
        assertEq(s.treasury, treasury);
        // junior keeps the rest: at least its stock back in value
        uint256 juniorValue = mstr.balanceOf(junior) + usdg.balanceOf(junior);
        assertGe(juniorValue + 1e15, 1_000e18, "junior whole plus its 40%");
        assertEq(_poolShares(id), 0);
        assertEq(vault.poolDeployed(), 0);
        _assertSolvent();
    }

    /// MSTR falls and the pool buys it: the senior is still paid in USDG (stock sold for the gap), the junior
    /// takes the loss.
    function test_priceDrop_seniorWhole_juniorTakesLoss() public {
        _lend(1_000e18);
        uint256 id = _junior(1_000e18);
        uint256 navBefore = vault.totalSeniorAssets();

        _swap(true, 150_000e18); // dump MSTR: the pool ends up mostly MSTR
        oracle.setPrice(0.95e18);
        sellRouter.setPrice(address(mstr), 0.95e18);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(junior);
        LeveredLpVault.Settlement memory s = vault.settle(id);

        assertGt(s.mstrSold, 0, "stock sold to pay the senior in USDG");
        assertGe(vault.totalSeniorAssets(), navBefore, "lender principal intact");
        assertLt(mstr.balanceOf(junior) * 95 / 100 + usdg.balanceOf(junior), 1_000e18 * 95 / 100, "junior down");
        _assertSolvent();
    }

    /// Pool worth less than the senior's principal: senior gets everything, the backstop covers the rest.
    function test_crash_backstopCoversSeniorPrincipal() public {
        _lend(1_000e18);
        uint256 id = _junior(1_000e18);
        usdg.mint(address(this), 1_000e18);
        usdg.approve(address(vault), 1_000e18);
        vault.fundBackstop(1_000e18);
        uint256 navBefore = vault.totalSeniorAssets();

        _swap(true, 400_000e18); // far past the range: the pool is all MSTR
        oracle.setPrice(0.3e18);
        sellRouter.setPrice(address(mstr), 0.3e18);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(junior);
        vault.settle(id);

        assertEq(vault.totalSeniorAssets(), navBefore, "backstop made the lender whole");
        assertLt(vault.backstop(), 1_000e18, "backstop paid");
        assertLt(mstr.balanceOf(junior), 1e12, "junior wiped out (keeps only dust that never went in)");
        _assertSolvent();
    }

    function test_earlyExit_returnsPoolShare() public {
        _lend(1_000e18);
        uint256 id = _junior(1_000e18);
        uint256 navBefore = vault.totalSeniorAssets();
        vm.prank(junior);
        vault.earlyExit(id);
        assertApproxEqRel(mstr.balanceOf(junior), 1_000e18, 1e12, "stock back");
        assertGe(vault.totalSeniorAssets() + 1, navBefore);
        assertEq(vault.poolDeployed(), 0);
        _assertSolvent();
    }

    function test_setMarketPool_rejectsWrongPair() public {
        DualPoolKey memory bad = dKey;
        bad.currency1 = address(0xBEEF);
        vm.expectRevert(LeveredLpVault.BadMarket.selector);
        vault.setMarketPool(0, bad);
        vm.expectRevert(LeveredLpVault.BadMarket.selector);
        vault.setMarketPool(7, dKey);
        vm.prank(trader);
        vm.expectRevert();
        vault.setMarketPool(0, dKey);
    }

    function test_onlyVaultMovesPoolShares() public {
        vm.expectRevert(CarryStrategy.NotVault.selector);
        strat.enterPool(1, dKey, 1, 1);
        vm.expectRevert(CarryStrategy.NotVault.selector);
        strat.exitPool(1, dKey, 1e18, 0, 0, address(0));
    }
}
