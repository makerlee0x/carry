// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LeveredLpVault} from "../src/LeveredLpVault.sol";
import {LeveredLpVaultV2} from "../src/LeveredLpVaultV2.sol";
import {IERC20Minimal} from "../src/interfaces/IERC20Minimal.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

/// @notice One lender pool serving several stock markets, each with its own token, oracle, range and cap.
contract MultiMarketTest is Test {
    MockERC20 mstr;
    MockERC20 nvda;
    MockERC20 usdg;
    MockOracle mstrOracle;
    MockOracle nvdaOracle;
    LeveredLpVault vault;
    uint256 nvdaId;

    address lender = makeAddr("lender");
    address juniorM = makeAddr("juniorM");
    address juniorN = makeAddr("juniorN");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_000_000);
        mstr = new MockERC20("Mock MSTR", "MSTR", 18);
        nvda = new MockERC20("Mock NVDA", "NVDA", 18);
        usdg = new MockERC20("Mock USDG", "USDG", 18);
        mstrOracle = new MockOracle(100 ether);
        nvdaOracle = new MockOracle(50 ether);
        LeveredLpVaultV2 impl = new LeveredLpVaultV2();
        bytes memory init = abi.encodeCall(
            LeveredLpVault.initialize,
            (address(mstr), address(usdg), address(mstrOracle), uint64(7 days), 0, address(this))
        );
        vault = LeveredLpVault(address(new ERC1967Proxy(address(impl), init)));
        vault.unpause();
        nvdaId = vault.addMarket(IERC20Minimal(address(nvda)), IPriceOracle(address(nvdaOracle)), 0.08e18, 0);
    }

    function _lend(uint256 amount) internal {
        usdg.mint(lender, amount);
        vm.startPrank(lender);
        usdg.approve(address(vault), amount);
        vault.depositSenior(amount);
        vm.stopPrank();
    }

    function _junior(address who, MockERC20 token, uint256 marketId, uint256 amount) internal returns (uint256 id) {
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(vault), amount);
        id = vault.depositJunior(marketId, amount);
        vm.stopPrank();
    }

    function _marketOf(uint256 id) internal view returns (uint256 m) {
        (,,,,,,,,,,,,, m) = vault.positions(id);
    }

    function test_market0IsMstr() public view {
        assertEq(vault.marketCount(), 2);
        (IERC20Minimal token,, bool active, uint64 range, IPriceOracle o,,) = vault.markets(0);
        assertEq(address(token), address(mstr));
        assertEq(address(o), address(mstrOracle));
        assertEq(range, 0.32e18);
        assertTrue(active);
        assertTrue(vault.isMarketToken(address(nvda)));
    }

    /// One lender's USDG matches juniors in two different stocks.
    function test_oneLenderPool_servesTwoMarkets() public {
        _lend(2_000 ether);
        uint256 a = _junior(juniorM, mstr, 0, 10 ether); // $1,000 of MSTR
        uint256 b = _junior(juniorN, nvda, nvdaId, 20 ether); // $1,000 of NVDA
        assertTrue(vault.isFullyMatched(a));
        assertTrue(vault.isFullyMatched(b));
        assertEq(_marketOf(a), 0);
        assertEq(_marketOf(b), nvdaId);
        assertEq(vault.reservedSenior(), 2_000 ether);
        assertEq(nvda.balanceOf(address(vault)), 20 ether);
    }

    /// Settle and early exit return each junior's own stock token.
    function test_exitReturnsTheMarketsToken() public {
        _lend(2_000 ether);
        uint256 a = _junior(juniorM, mstr, 0, 10 ether);
        uint256 b = _junior(juniorN, nvda, nvdaId, 20 ether);

        vm.prank(juniorN);
        vault.earlyExit(b);
        assertEq(nvda.balanceOf(juniorN), 20 ether);
        assertEq(mstr.balanceOf(juniorN), 0);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(juniorM);
        vault.settle(a);
        assertEq(mstr.balanceOf(juniorM), 10 ether);
        assertEq(nvda.balanceOf(juniorM), 0);
    }

    /// The stop-rolling range is per market: NVDA -10% stops (range 8%), MSTR -10% keeps rolling (range 32%).
    function test_rangeIsPerMarket() public {
        _lend(2_000 ether);
        uint256 a = _junior(juniorM, mstr, 0, 10 ether);
        uint256 b = _junior(juniorN, nvda, nvdaId, 20 ether);
        mstrOracle.setPrice(90 ether);
        nvdaOracle.setPrice(45 ether);
        vm.warp(block.timestamp + 7 days + 48 hours + 1);

        vm.prank(stranger);
        vault.settle(b); // NVDA past its range: anyone can settle after grace
        assertEq(nvda.balanceOf(juniorN), 20 ether);

        vm.prank(stranger);
        vm.expectRevert(LeveredLpVault.NotJunior.selector);
        vault.settle(a); // MSTR still inside its range
    }

    function test_juniorCapIsPerMarket() public {
        vault.setMarket(nvdaId, IPriceOracle(address(nvdaOracle)), 0.08e18, 1_000 ether, true);
        _lend(3_000 ether);
        _junior(juniorN, nvda, nvdaId, 20 ether); // $1,000: at cap
        nvda.mint(juniorN, 2 ether);
        vm.startPrank(juniorN);
        nvda.approve(address(vault), 2 ether);
        vm.expectRevert(LeveredLpVault.CapExceeded.selector);
        vault.depositJunior(nvdaId, 2 ether);
        vm.stopPrank();
        _junior(juniorM, mstr, 0, 10 ether); // MSTR unaffected by NVDA's cap
    }

    function test_inactiveMarket_blocksNewJuniorsOnly() public {
        _lend(2_000 ether);
        uint256 b = _junior(juniorN, nvda, nvdaId, 20 ether);
        vault.setMarket(nvdaId, IPriceOracle(address(nvdaOracle)), 0.08e18, 0, false);

        nvda.mint(juniorN, 1 ether);
        vm.startPrank(juniorN);
        nvda.approve(address(vault), 1 ether);
        vm.expectRevert(LeveredLpVault.BadMarket.selector);
        vault.depositJunior(nvdaId, 1 ether);
        vault.earlyExit(b); // the open position still exits
        vm.stopPrank();
        assertEq(nvda.balanceOf(juniorN), 21 ether);
    }

    function test_addMarket_rejectsDuplicatesAndBadParams() public {
        vm.expectRevert(LeveredLpVault.BadMarket.selector);
        vault.addMarket(IERC20Minimal(address(nvda)), IPriceOracle(address(nvdaOracle)), 0.08e18, 0);
        vm.expectRevert(LeveredLpVault.BadMarket.selector);
        vault.addMarket(IERC20Minimal(address(usdg)), IPriceOracle(address(nvdaOracle)), 0.08e18, 0);
        MockERC20 tsla = new MockERC20("Mock TSLA", "TSLA", 18);
        vm.expectRevert(LeveredLpVault.BadMarket.selector);
        vault.addMarket(IERC20Minimal(address(tsla)), IPriceOracle(address(0)), 0.08e18, 0);
        vm.expectRevert(LeveredLpVault.BadMarket.selector);
        vault.addMarket(IERC20Minimal(address(tsla)), IPriceOracle(address(nvdaOracle)), 1e18, 0);
        vm.expectRevert(LeveredLpVault.BadMarket.selector);
        vault.depositJunior(99, 1 ether);
    }

    function test_onlyOwnerManagesMarkets() public {
        MockERC20 tsla = new MockERC20("Mock TSLA", "TSLA", 18);
        vm.startPrank(stranger);
        vm.expectRevert();
        vault.addMarket(IERC20Minimal(address(tsla)), IPriceOracle(address(nvdaOracle)), 0.1e18, 0);
        vm.expectRevert();
        vault.setMarket(nvdaId, IPriceOracle(address(nvdaOracle)), 0.1e18, 0, false);
        vm.stopPrank();
    }

    function test_rescueToken_blocksEveryMarketToken() public {
        vm.expectRevert(LeveredLpVault.PrincipalToken.selector);
        vault.rescueToken(address(nvda), address(this), 1);
        vm.expectRevert(LeveredLpVault.PrincipalToken.selector);
        vault.rescueToken(address(mstr), address(this), 1);
    }

    /// Upgrade path for the live proxy: with no markets registered yet, `initializeMarkets` registers MSTR as
    /// market 0 from the existing slots and keeps the existing junior total.
    function test_initializeMarkets_registersLegacyMstr() public {
        _lend(1_000 ether);
        _junior(juniorM, mstr, 0, 10 ether);
        uint256 totalJunior = vault.totalJuniorUsdg();
        bytes32 countSlot = bytes32(uint256(_marketCountSlot()));
        vm.store(address(vault), countSlot, bytes32(0));
        assertEq(vault.marketCount(), 0);

        vm.prank(stranger);
        vm.expectRevert();
        vault.initializeMarkets();

        vault.initializeMarkets();
        assertEq(vault.marketCount(), 1);
        (IERC20Minimal token,,,,,, uint256 juniorUsdg) = vault.markets(0);
        assertEq(address(token), address(mstr));
        assertEq(juniorUsdg, totalJunior);

        vm.expectRevert();
        vault.initializeMarkets(); // one time only
    }

    function _marketCountSlot() internal returns (uint256 slot) {
        // Find marketCount's slot by probing: it is the only slot whose value equals marketCount().
        uint256 want = vault.marketCount();
        for (slot = 0; slot < 200; slot++) {
            if (uint256(vm.load(address(vault), bytes32(slot))) == want && _isMarketCount(slot, want)) return slot;
        }
        revert("marketCount slot not found");
    }

    function _isMarketCount(uint256 slot, uint256 want) internal returns (bool) {
        vm.store(address(vault), bytes32(slot), bytes32(want + 7));
        bool hit = vault.marketCount() == want + 7;
        vm.store(address(vault), bytes32(slot), bytes32(want));
        return hit;
    }
}
