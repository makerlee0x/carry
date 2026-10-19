// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {IBoostHook} from "./interfaces/IBoostHook.sol";
import {ICarryStrategy, PoolExit} from "./interfaces/ICarryStrategy.sol";
import {DualPoolKey} from "./interfaces/IDualPoolLp.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IPushablePriceOracle} from "./interfaces/IPushablePriceOracle.sol";
import {CarryMath} from "./libraries/CarryMath.sol";
import {CarryPool} from "./libraries/CarryPool.sol";

/// @title LeveredLpVault
/// @notice UUPS 2× junior MSTR / senior USDG book — Carry v3 lender pool.
///
/// v3 lender model:
/// 1. One USDG senior pool; non-transferable internal shares; round in pool favor; virtual offset.
/// 2. Instant withdraw if idle covers and withdraw queue empty; else FIFO cumulative queue + lazy claim.
/// 3. No stored lender rate: senior USDG earns whatever the Morpho strategy pays (booked by `harvest`),
///    plus its share of LP fees. Positions roll at term.
/// 4. Senior yield compounds into the pool. Lenders paid only USDG (stock fees swapped before payout).
/// 5. Withdrawal queue paid before new matching. Lender withdraw never closes a junior position.
/// 6. One lender pool serves many stock markets. Each market has its own token, oracle, range and junior cap;
///    market 0 is the original MSTR market (the `mstr` / `oracle` slots).
///
/// Fresh product PROXY for v3 (v2.5 funder-idle PROXY superseded — open settle-watch stays there).
contract LeveredLpVault is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_TREASURY_CUT_WAD = 0.2e18;
    uint256 public constant SENIOR_PERF_CUT_WAD = 0.4e18;
    uint256 internal constant DEFAULT_TREASURY_CUT_WAD = 0.2e18;
    uint256 internal constant BOOSTED_TREASURY_CUT_WAD = 0.1e18;
    uint256 internal constant DEFAULT_MATCH_CAP = 25;
    uint256 internal constant DEFAULT_GAS_REFUND_WEI = 0.0001 ether;
    /// @dev $25, scaled by USDG decimals at use (real USDG has 6, the testnet mock 18).
    uint256 internal constant DEFAULT_MIN_DEPOSIT_DOLLARS = 25;
    uint64 internal constant MAX_TERM = 7 days;
    /// @dev Positions roll at term. One priced more than its market's range below entry stops rolling, and
    ///      after this grace from the last term boundary anyone may settle it. This is market 0's (MSTR) range.
    uint256 internal constant MSTR_RANGE_DROP_WAD = 0.32e18;
    uint256 internal constant UNDERWATER_GRACE = 48 hours;
    uint256 internal constant DEFAULT_MAX_PRICE_STALE = 1 hours;

    enum CoverMode {
        Wallet,
        IdleCarry,
        SellShares
    }

    enum PositionState {
        Idle,
        Active,
        Boosted,
        Closed
    }

    struct Position {
        address owner;
        uint256 mstrAmount;
        uint256 seniorPrincipal;
        uint256 targetSenior;
        uint256 entryPriceWad;
        uint256 feeUsdg;
        uint64 openedAt;
        uint64 lastFeeSplitAt;
        bool settled;
        bool boosted;
        uint256 unpaidSeniorAccrual; // retired; field kept for layout
        uint256 rateIndexSnapshot; // retired; field kept for layout (live positions still hold old values)
        uint256 treasuryCutLocked;
        /// @notice Market this position belongs to (0 = MSTR; appended, so older positions read 0).
        uint256 marketId;
    }

    /// @notice One stock market sharing the lender pool.
    struct Market {
        IERC20Minimal token;
        uint8 decimals;
        bool active;
        /// @dev Drop below entry, in WAD, past which a position stops rolling (MSTR 0.32e18).
        uint64 rangeDropWad;
        IPriceOracle oracle;
        /// @dev Junior notional cap for this market in USDG (0 = none).
        uint256 juniorCapUsdg;
        uint256 juniorUsdg;
    }

    struct WaterfallSplit {
        uint256 accrual;
        uint256 seniorFloor;
        uint256 treasury;
        uint256 seniorPerf;
        uint256 junior;
        uint256 seniorTotal;
    }

    struct Settlement {
        uint256 mstrKept;
        uint256 mstrSold;
        uint256 accrual;
        uint256 seniorFloor;
        uint256 treasury;
        uint256 seniorPerf;
        uint256 juniorYield;
        uint256 fromBackstop;
        uint256 coverUsdg;
        uint256 treasuryOnCover;
        uint256 feeShortfallUsdg;
        uint256 fromPool;
        CoverMode coverMode;
    }

    struct EarlyExitResult {
        uint256 elapsed;
        uint256 accrual;
        uint256 seniorFloor;
        uint256 treasury;
        uint256 seniorPerf;
        uint256 juniorLeftoverFees;
        uint256 coverUsdg;
        uint256 treasuryOnCover;
        uint256 mstrSold;
        uint256 mstrReturned;
        uint256 feeShortfallUsdg;
        CoverMode coverMode;
    }

    struct ClaimFeesResult {
        uint256 elapsed;
        uint256 accrual;
        uint256 seniorFloor;
        uint256 treasury;
        uint256 seniorPerf;
        uint256 toJunior;
        uint256 gross;
    }

    IERC20Minimal public mstr;
    IERC20Minimal public usdg;
    IPriceOracle public oracle;
    uint64 public term;
    uint8 internal mstrDecimals;
    uint8 internal usdgDecimals;

    bool public paused;
    uint256 public backstop;
    /// @notice Senior pool NAV in USDG (idle + reserved + compounded senior yield).
    uint256 public totalSeniorAssets;
    uint256 public reservedSenior;
    uint256 public nextPositionId;
    /// @notice Unsplit position fee USDG still sitting on open/matched positions.
    uint256 public totalUnsplitFees;

    uint256 public maxTotalSeniorUsdg;
    uint256 public maxTotalJuniorUsdg;
    /// @dev Deprecated UUPS slot (issue #22). Never written or enforced; kept for layout.
    uint256 public maxPerWalletUsdg;
    uint256 public totalJuniorUsdg;
    /// @dev Deprecated UUPS slots (issue #22). No longer updated.
    mapping(address => uint256) public walletSeniorUsdg;
    mapping(address => uint256) public walletJuniorUsdg;
    mapping(uint256 => uint256) internal positionJuniorUsdg;

    uint256 public morphoRateWad;
    uint256 public treasuryCutWad;
    uint256 public boostedTreasuryCutWad;

    mapping(address => bool) internal boostStaked; // retired; slot kept for layout

    uint256 internal openHead;
    uint256 internal openTail;
    mapping(uint256 => uint256) internal openNext;

    mapping(uint256 => Position) public positions;
    /// @notice Non-transferable senior pool shares.
    mapping(address => uint256) public shares;

    uint256 public matchCap;
    uint256 public gasRefundWei;
    mapping(address => uint256) public gasCreditWei;

    address public sellSharesRouter;
    mapping(address => bool) public autoCompound;
    mapping(address => uint256) public pendingEthCredit;
    uint256 public minDepositUsdg;
    uint256 internal boostTierCount; // retired; slot kept for layout
    uint256[4] internal boostTierMinStake; // retired; slot kept for layout
    uint256[4] internal boostTierCutWad; // retired; slot kept for layout
    mapping(address => uint256) internal boostStakeAmount; // retired; slot kept for layout
    mapping(address => bool) internal sellSharesEnabled; // retired; slot kept for layout

    uint256 public totalShares;
    /// @notice USDG set aside for fulfilled withdraw-queue claims (still in vault).
    uint256 public queueClaimable;
    uint256 public wqCumulativeRequested;
    uint256 public wqCumulativeFulfilled;
    mapping(address => uint256) public wqRequested;
    mapping(address => uint256) internal wqClaimed;
    mapping(address => uint256) internal wqCursor;
    mapping(address => uint256) public wqSharesLocked;

    uint256 public rateIndex;
    uint64 internal rateUpdatedAt;

    bool public treasuryCutIsSet;
    uint256 public maxPriceStale;

    /// @notice Separate boost contract read at match; zero means no boost.
    IBoostHook public boostHook;

    /// @notice CarryStrategy holding lender USDG in Morpho (0 = none; USDG stays in the vault).
    ICarryStrategy public strategy;
    /// @notice USDG principal plus booked yield currently held by `strategy`.
    uint256 public strategyDeployed;

    mapping(uint256 => Market) public markets;
    uint256 public marketCount;
    mapping(address => bool) public isMarketToken;

    /// @notice Each market's DualPool pool (`hooks` 0 = none: positions stay out of a pool).
    mapping(uint256 => DualPoolKey) public marketPool;
    /// @notice Senior USDG currently in pools, at what it put in.
    uint256 public poolDeployed;
    /// @notice DualPool shares the strategy holds for each position (0 = not in a pool).
    mapping(uint256 => uint256) public positionPoolShares;

    uint256[31] private __gap;

    error Paused();
    error ZeroAmount();
    error ZeroAddress();
    error BadTerm();
    error BadApr();
    error BadCut();
    error BadPrice();
    error StalePrice();
    error BadPosition();
    error TermNotElapsed();
    error TermElapsed();
    error AlreadySettled();
    error NotJunior();
    error NotMatched();
    error AlreadyMatched();
    error InsufficientFree();
    error InsufficientIdleCover();
    error PrincipalToken();
    error BadMarket();
    error TransferFailed();
    error FeeOnTransfer();
    error CapExceeded();
    error ZeroGross();
    error InsufficientBackstop();
    error JuniorCoverRequired();
    error BadMatchCap();
    error InsufficientGasCredit();
    error GasTransferFailed();
    error ApproveFailed();
    error BelowMinDeposit();
    error SellSharesDisabled();
    error BadTiers();
    error QueueOutstanding();
    error NothingToClaim();
    error NoSellRouter();

    event PausedDeposits(bool paused);
    event SeniorDeposit(address indexed senior, uint256 assets, uint256 sharesMinted);
    event SeniorWithdraw(address indexed senior, uint256 assets, uint256 sharesBurned);
    event SeniorWithdrawQueued(address indexed senior, uint256 assets, uint256 sharesLocked, uint256 cursor);
    event SeniorWithdrawClaimed(address indexed senior, uint256 assets, uint256 sharesBurned);
    event JuniorDeposit(uint256 indexed positionId, address indexed junior, uint256 mstrAmount, bool matched);
    event PositionMatched(
        uint256 indexed positionId, address indexed junior, uint256 seniorPrincipal, uint256 matchedDelta, uint64 openedAt
    );
    event UnmatchedWithdraw(uint256 indexed positionId, address indexed junior, uint256 mstrAmount);
    event LpFeeAccrued(uint256 indexed positionId, uint256 gross, uint256 toBackstop, uint256 toPosition);
    event BackstopFunded(address indexed from, uint256 amount);
    event Settled(
        uint256 indexed positionId,
        address indexed junior,
        uint256 mstrKept,
        uint256 mstrSold,
        uint256 treasury,
        uint256 juniorYield
    );
    event EarlyExit(
        uint256 indexed positionId,
        address indexed junior,
        uint256 accrual,
        uint256 seniorFloor,
        uint256 coverUsdg,
        uint256 mstrSold,
        uint256 mstrReturned,
        uint256 juniorLeftoverFees,
        CoverMode coverMode
    );
    event CapsUpdated(uint256 maxTotalSeniorUsdg, uint256 maxTotalJuniorUsdg);
    event TreasuryCutUpdated(uint256 treasuryCutWad, uint256 boostedTreasuryCutWad, bool isSet);
    event BoostStakeUpdated(address indexed user, bool staked);
    event FeesClaimed(
        uint256 indexed positionId,
        address indexed junior,
        uint256 gross,
        uint256 seniorFloor,
        uint256 treasury,
        uint256 seniorPerf,
        uint256 toJunior
    );
    event WaterfallApplied(
        uint256 indexed positionId,
        uint256 gross,
        uint256 accrual,
        uint256 seniorFloor,
        uint256 treasury,
        uint256 seniorPerf,
        uint256 junior
    );
    event BackstopWithdrawn(address indexed to, uint256 amount);
    event TreasuryFeesWithdrawn(address indexed to, uint256 amount);
    event MatchCapUpdated(uint256 matchCap);
    event GasRefundWeiUpdated(uint256 gasRefundWei);
    event GasCreditFunded(address indexed junior, uint256 amount, uint256 balance);
    event GasCreditWithdrawn(address indexed junior, uint256 amount, uint256 balance);
    event GasCreditConsumed(address indexed junior, address indexed senior, uint256 amount);
    event SellSharesRouterUpdated(address indexed router);
    event AutoCompoundUpdated(address indexed user, bool enabled);
    event MinDepositUpdated(uint256 minDepositUsdg);
    event BoostTiersUpdated(uint256 count);
    event BoostHookUpdated(address indexed hook);
    event BoostStakeAmountUpdated(address indexed user, uint256 amount);
    event PendingEthCredited(address indexed to, uint256 amount, uint256 balance);
    event PendingEthWithdrawn(address indexed to, uint256 amount);
    event MaxPriceStaleUpdated(uint256 maxPriceStale);
    event MarketPoolSet(uint256 indexed marketId, address indexed hook);
    event MarketSet(
        uint256 indexed marketId, address indexed token, address oracle, uint64 rangeDropWad, uint256 juniorCapUsdg, bool active
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev The fifth argument was the fixed Morpho rate. It is unused (lenders earn the strategy's real
    ///      yield) and kept only so deploy scripts keep their call shape.
    function initialize(
        address mstr_,
        address usdg_,
        address oracle_,
        uint64 term_,
        uint256,
        address owner_
    ) external initializer {
        if (mstr_ == address(0) || usdg_ == address(0) || oracle_ == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        if (term_ == 0 || term_ > MAX_TERM) revert BadTerm();

        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        mstr = IERC20Minimal(mstr_);
        usdg = IERC20Minimal(usdg_);
        oracle = IPriceOracle(oracle_);
        term = term_;
        treasuryCutWad = DEFAULT_TREASURY_CUT_WAD;
        boostedTreasuryCutWad = BOOSTED_TREASURY_CUT_WAD;
        treasuryCutIsSet = true;
        gasRefundWei = DEFAULT_GAS_REFUND_WEI;
        maxPriceStale = DEFAULT_MAX_PRICE_STALE;
        // Senior uncapped by default (0). Junior market cap set by owner after deploy.
        maxTotalSeniorUsdg = 0;
        mstrDecimals = mstr.decimals();
        usdgDecimals = usdg.decimals();
        minDepositUsdg = DEFAULT_MIN_DEPOSIT_DOLLARS * 10 ** usdgDecimals;
        nextPositionId = 1;
        _initMarket0();
        paused = true;
        emit PausedDeposits(true);
    }

    /// @notice One-time upgrade step for the live v3 proxy: registers the existing MSTR market as market 0.
    function initializeMarkets() external reinitializer(2) onlyOwner {
        if (marketCount != 0) revert BadMarket();
        _initMarket0();
    }

    function _initMarket0() internal {
        markets[0] = Market({
            token: mstr,
            decimals: mstrDecimals,
            active: true,
            rangeDropWad: uint64(MSTR_RANGE_DROP_WAD),
            oracle: oracle,
            juniorCapUsdg: 0,
            juniorUsdg: totalJuniorUsdg
        });
        isMarketToken[address(mstr)] = true;
        marketCount = 1;
        emit MarketSet(0, address(mstr), address(oracle), uint64(MSTR_RANGE_DROP_WAD), 0, true);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function version() external pure returns (string memory) {
        return "v3.2-dualpool";
    }

    // ─── admin ───────────────────────────────────────────────────────────────

    function pause() external onlyOwner {
        paused = true;
        emit PausedDeposits(true);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit PausedDeposits(false);
    }

    /// @notice Set market total caps. `0` = uncapped. No per-wallet cap (issue #22).
    function setDepositCaps(uint256 maxTotalSeniorUsdg_, uint256 maxTotalJuniorUsdg_) external onlyOwner {
        maxTotalSeniorUsdg = maxTotalSeniorUsdg_;
        maxTotalJuniorUsdg = maxTotalJuniorUsdg_;
        emit CapsUpdated(maxTotalSeniorUsdg_, maxTotalJuniorUsdg_);
    }

    /// @notice Add a stock market to the shared lender pool. No new contract, no upgrade.
    function addMarket(IERC20Minimal token, IPriceOracle oracle_, uint64 rangeDropWad, uint256 juniorCapUsdg)
        external
        onlyOwner
        returns (uint256 marketId)
    {
        if (address(token) == address(0) || address(token) == address(usdg) || isMarketToken[address(token)]) {
            revert BadMarket();
        }
        marketId = marketCount++;
        isMarketToken[address(token)] = true;
        Market storage m = markets[marketId];
        m.token = token;
        m.decimals = token.decimals();
        _setMarket(marketId, oracle_, rangeDropWad, juniorCapUsdg, true);
    }

    /// @notice Change a market's oracle, range or junior cap, or stop new junior deposits (`active` false).
    ///         Open positions keep running either way.
    function setMarket(uint256 marketId, IPriceOracle oracle_, uint64 rangeDropWad, uint256 juniorCapUsdg, bool active)
        external
        onlyOwner
    {
        if (marketId >= marketCount) revert BadMarket();
        _setMarket(marketId, oracle_, rangeDropWad, juniorCapUsdg, active);
    }

    function _setMarket(uint256 marketId, IPriceOracle oracle_, uint64 rangeDropWad, uint256 juniorCapUsdg, bool active)
        internal
    {
        if (address(oracle_) == address(0) || rangeDropWad == 0 || rangeDropWad >= WAD) revert BadMarket();
        Market storage m = markets[marketId];
        m.oracle = oracle_;
        m.rangeDropWad = rangeDropWad;
        m.juniorCapUsdg = juniorCapUsdg;
        m.active = active;
        emit MarketSet(marketId, address(m.token), address(oracle_), rangeDropWad, juniorCapUsdg, active);
    }

    function setTreasuryCuts(uint256 treasuryCutWad_, uint256 boostedTreasuryCutWad_) external onlyOwner {
        if (treasuryCutWad_ > MAX_TREASURY_CUT_WAD || boostedTreasuryCutWad_ > MAX_TREASURY_CUT_WAD) {
            revert BadCut();
        }
        treasuryCutWad = treasuryCutWad_;
        boostedTreasuryCutWad = boostedTreasuryCutWad_;
        treasuryCutIsSet = true;
        emit TreasuryCutUpdated(treasuryCutWad_, boostedTreasuryCutWad_, true);
    }

    /// @notice Clear treasury cut (0% with explicit unset — distinct from "set to 0" via flag).
    function clearTreasuryCuts() external onlyOwner {
        treasuryCutWad = 0;
        boostedTreasuryCutWad = 0;
        treasuryCutIsSet = false;
        emit TreasuryCutUpdated(0, 0, false);
    }

    /// @notice Send a market's fully matched positions into this DualPool pool (`key.hooks` 0 turns it off;
    ///         positions already in a pool stay there until they close).
    function setMarketPool(uint256 marketId, DualPoolKey calldata key) external onlyOwner {
        address t = address(markets[marketId].token);
        address u = address(usdg);
        if (
            t == address(0)
                || key.hooks != address(0)
                    && !(key.currency0 == u && key.currency1 == t || key.currency0 == t && key.currency1 == u)
        ) revert BadMarket();
        marketPool[marketId] = key;
        emit MarketPoolSet(marketId, key.hooks);
    }

    /// @notice Point the vault at a strategy. The old one must be empty (recall first).
    function setStrategy(ICarryStrategy strategy_) external onlyOwner {
        if (strategyDeployed != 0 || poolDeployed != 0) revert InsufficientFree();
        strategy = strategy_;
        if (address(strategy_) != address(0)) usdg.approve(address(strategy_), type(uint256).max);
    }

    /// @notice Move lender USDG (matched or not, minus filled queue claims) into the strategy to earn.
    ///         Payouts recall what they need from the strategy in `_push`.
    function deployIdle(uint256 amount) external onlyOwner nonReentrant {
        _harvest();
        if (amount == 0) revert ZeroAmount();
        if (strategyDeployed + amount + queueClaimable > totalSeniorAssets) revert InsufficientFree();
        strategyDeployed += amount;
        strategy.deposit(amount);
    }

    /// @notice Book the strategy's yield into the senior pool share price. Anyone may call.
    function harvest() external nonReentrant {
        _harvest();
    }

    function setSellSharesRouter(address router) external onlyOwner {
        sellSharesRouter = router;
        emit SellSharesRouterUpdated(router);
    }

    function setAutoCompound(bool enabled) external {
        autoCompound[msg.sender] = enabled;
        emit AutoCompoundUpdated(msg.sender, enabled);
    }

    function setGasRefundWei(uint256 gasRefundWei_) external onlyOwner {
        gasRefundWei = gasRefundWei_;
        emit GasRefundWeiUpdated(gasRefundWei_);
    }

    function fundGasCredit() external payable {
        if (msg.value == 0) revert ZeroAmount();
        gasCreditWei[msg.sender] += msg.value;
        emit GasCreditFunded(msg.sender, msg.value, gasCreditWei[msg.sender]);
    }

    function withdrawGasCredit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = gasCreditWei[msg.sender];
        if (amount > bal) revert InsufficientGasCredit();
        gasCreditWei[msg.sender] = bal - amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert GasTransferFailed();
        emit GasCreditWithdrawn(msg.sender, amount, gasCreditWei[msg.sender]);
    }

    function rescueToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (isMarketToken[token] || token == address(usdg)) revert PrincipalToken();
        if (to == address(0)) revert ZeroAddress();
        _push(IERC20Minimal(token), to, amount);
    }

    function withdrawFromBackstop(address to, uint256 amount) external onlyOwner nonReentrant {
        _withdrawBackstop(to, amount);
        emit BackstopWithdrawn(to, amount);
    }

    function withdrawTreasuryFees(address to, uint256 amount) external onlyOwner nonReentrant {
        _withdrawBackstop(to, amount);
        emit TreasuryFeesWithdrawn(to, amount);
    }

    function setMatchCap(uint256 matchCap_) external onlyOwner {
        matchCap = matchCap_;
        emit MatchCapUpdated(matchCap_);
    }

    function setMinDepositUsdg(uint256 minDepositUsdg_) external onlyOwner {
        minDepositUsdg = minDepositUsdg_;
        emit MinDepositUpdated(minDepositUsdg_);
    }

    function setMaxPriceStale(uint256 maxPriceStale_) external onlyOwner {
        maxPriceStale = maxPriceStale_;
        emit MaxPriceStaleUpdated(maxPriceStale_);
    }

    function withdrawPendingEth() external nonReentrant {
        uint256 amt = pendingEthCredit[msg.sender];
        if (amt == 0) revert ZeroAmount();
        pendingEthCredit[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amt}("");
        if (!ok) revert GasTransferFailed();
        emit PendingEthWithdrawn(msg.sender, amt);
    }

    // ─── senior pool ─────────────────────────────────────────────────────────

    function depositSenior(uint256 amount) external nonReentrant {
        if (paused) revert Paused();
        if (amount == 0) revert ZeroAmount();
        if (amount < _minDeposit()) revert BelowMinDeposit();
        _enforceSeniorCap(msg.sender, amount);
        _harvest();

        // Capture sponsor before match — full match dequeues the junior.
        address gasSponsor = _gasSponsor();
        _pullExact(usdg, msg.sender, amount);
        uint256 minted = _mintSeniorShares(msg.sender, amount);
        if (minted == 0) revert ZeroAmount();

        uint256 matched = _matchOpenPositions(_effectiveMatchCap());
        _payGasRefundOnMatch(msg.sender, gasSponsor, matched, amount);
        emit SeniorDeposit(msg.sender, amount, minted);
    }

    /// @notice Withdraw `assets` USDG from free (non-queued) share value. Always pays wallet (no auto-compound reopen).
    function withdrawSenior(uint256 assets) external nonReentrant {
        if (assets == 0) revert ZeroAmount();
        _harvest();
        uint256 freeShares = _freeShares(msg.sender);
        uint256 freeAssets = CarryPool.convertToAssets(freeShares, totalShares, totalSeniorAssets);
        if (assets > freeAssets) revert InsufficientFree();

        uint256 sharesNeeded = CarryPool.previewWithdrawShares(assets, totalShares, totalSeniorAssets);
        if (sharesNeeded > freeShares) sharesNeeded = freeShares;

        // Instant if idle covers and nobody waiting in queue.
        if (_idleUsdg() >= assets && wqCumulativeRequested == wqCumulativeFulfilled) {
            _redeem(msg.sender, sharesNeeded, assets);
            emit SeniorWithdraw(msg.sender, assets, sharesNeeded);
            _push(usdg, msg.sender, assets);
            return;
        }

        // Queue: keep shares earning until replaced/fulfilled.
        if (wqRequested[msg.sender] != wqClaimed[msg.sender]) revert QueueOutstanding();
        wqCursor[msg.sender] = wqCumulativeRequested;
        wqRequested[msg.sender] = assets;
        wqClaimed[msg.sender] = 0;
        wqSharesLocked[msg.sender] = sharesNeeded;
        wqCumulativeRequested += assets;
        emit SeniorWithdrawQueued(msg.sender, assets, sharesNeeded, wqCursor[msg.sender]);

        _matchOpenPositions(_effectiveMatchCap());
    }

    /// @notice Lazy claim of fulfilled withdraw-queue assets. Always pays wallet.
    function claimWithdraw() external nonReentrant {
        uint256 paid = CarryPool.claimableQueued(
            wqRequested[msg.sender], wqClaimed[msg.sender], wqCursor[msg.sender], wqCumulativeFulfilled
        );
        if (paid == 0) revert NothingToClaim();
        if (queueClaimable < paid) revert InsufficientFree();

        uint256 locked = wqSharesLocked[msg.sender];
        uint256 idle = _idleUsdg();
        wqClaimed[msg.sender] += paid;
        queueClaimable -= paid;
        uint256 burn = CarryPool.previewWithdrawShares(paid, totalShares, totalSeniorAssets);
        if (wqClaimed[msg.sender] >= wqRequested[msg.sender]) {
            // Request filled: pay what the locked shares are worth now, so yield earned while queued
            // is paid too (from idle; any part idle can't cover stays as free shares).
            uint256 value = CarryPool.convertToAssets(locked, totalShares, totalSeniorAssets);
            if (value <= paid + idle) {
                if (value > paid) paid = value;
                burn = locked;
            } else {
                paid += idle;
                burn = CarryPool.previewWithdrawShares(paid, totalShares, totalSeniorAssets);
            }
        }
        if (burn > locked) burn = locked;
        wqSharesLocked[msg.sender] = locked - burn;

        _redeem(msg.sender, burn, paid);

        if (wqClaimed[msg.sender] >= wqRequested[msg.sender]) {
            wqRequested[msg.sender] = 0;
            wqClaimed[msg.sender] = 0;
            wqCursor[msg.sender] = 0;
            wqSharesLocked[msg.sender] = 0;
        }

        emit SeniorWithdrawClaimed(msg.sender, paid, burn);
        _push(usdg, msg.sender, paid);
    }

    // ─── junior ──────────────────────────────────────────────────────────────

    /// @notice Open a junior position in market 0 (MSTR).
    function depositJunior(uint256 mstrAmount) external nonReentrant returns (uint256 positionId) {
        positionId = _depositJunior(0, mstrAmount);
    }

    /// @notice Open a junior position with `amount` of market `marketId`'s stock token.
    function depositJunior(uint256 marketId, uint256 amount) external nonReentrant returns (uint256 positionId) {
        positionId = _depositJunior(marketId, amount);
    }

    function _depositJunior(uint256 marketId, uint256 amount) internal returns (uint256 positionId) {
        if (paused) revert Paused();
        if (amount == 0) revert ZeroAmount();
        if (!markets[marketId].active) revert BadMarket();
        _pullExact(markets[marketId].token, msg.sender, amount);
        positionId = _openJuniorFromVaultBalance(msg.sender, marketId, amount, false);
    }

    /// @notice Explicit unmatched withdraw always pays wallet (auto-compound must not reopen).
    function withdrawUnmatched(uint256 positionId) external nonReentrant {
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert BadPosition();
        if (position.owner != msg.sender) revert NotJunior();
        if (position.settled) revert AlreadySettled();
        if (position.seniorPrincipal != 0) revert AlreadyMatched();

        uint256 amount = position.mstrAmount;
        position.settled = true;
        position.mstrAmount = 0;
        _dequeueOpen(positionId);
        _releaseJuniorCap(msg.sender, positionId);

        emit UnmatchedWithdraw(positionId, msg.sender, amount);
        _refundAllGasCredit(msg.sender);
        _push(markets[position.marketId].token, msg.sender, amount);
    }

    function accrueLpFee(uint256 positionId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage position = positions[positionId];
        if (position.owner == address(0) || position.settled) revert BadPosition();
        if (position.seniorPrincipal == 0) revert NotMatched();
        _pullExact(usdg, msg.sender, amount);
        position.feeUsdg += amount;
        totalUnsplitFees += amount;
        emit LpFeeAccrued(positionId, amount, 0, amount);
    }

    function fundBackstop(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _pullExact(usdg, msg.sender, amount);
        backstop += amount;
        emit BackstopFunded(msg.sender, amount);
    }

    function claimFees(uint256 positionId) external nonReentrant returns (ClaimFeesResult memory result) {
        Position storage position = positions[positionId];
        if (position.owner != msg.sender) revert NotJunior();
        // Same block, same state: the preview is exactly what the split below pays.
        result = previewClaimFees(positionId);
        _splitAndClearFees(positionId);
        position.lastFeeSplitAt = uint64(block.timestamp);

        emit FeesClaimed(
            positionId, msg.sender, result.gross, result.seniorFloor, result.treasury, result.seniorPerf, result.toJunior
        );
        _deliverJuniorUsdg(msg.sender, result.toJunior);
    }

    function previewClaimFees(uint256 positionId) public view returns (ClaimFeesResult memory result) {
        Position storage position = _livePosition(positionId);
        uint256 gross = position.feeUsdg;
        if (gross == 0) revert ZeroGross();
        result.elapsed = _elapsedSinceSplit(position);
        WaterfallSplit memory split = _positionSplit(position);
        result.accrual = split.accrual;
        result.seniorFloor = split.seniorFloor;
        result.treasury = split.treasury;
        result.seniorPerf = split.seniorPerf;
        result.toJunior = split.junior;
        result.gross = gross;
    }

    function settle(uint256 positionId) external nonReentrant returns (Settlement memory) {
        return _settle(positionId, CoverMode.IdleCarry);
    }

    /// @notice Fee-pool part of a settle. A pooled position's pool share is split at close (see `PoolExit`).
    function previewSettle(uint256 positionId) external view returns (Settlement memory result) {
        Position storage position = _maturedPosition(positionId);
        result = _settleQuote(position, CoverMode.IdleCarry);
        result.mstrKept = position.mstrAmount;
    }

    function earlyExit(uint256 positionId) external nonReentrant returns (EarlyExitResult memory) {
        return _earlyExit(positionId, CoverMode.IdleCarry);
    }

    /// @notice Fee-pool part of an early exit. A pooled position's pool share is split at close (see `PoolExit`).
    function previewEarlyExit(uint256 positionId) external view returns (EarlyExitResult memory result) {
        Position storage position = _inTermPosition(positionId);
        WaterfallSplit memory split = _positionSplit(position);
        _fillEarlyExitQuote(result, position, split, CoverMode.IdleCarry);
        result.mstrReturned = position.mstrAmount;
    }

    // ─── views ───────────────────────────────────────────────────────────────

    function positionState(uint256 positionId) public view returns (PositionState) {
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert BadPosition();
        if (position.settled) return PositionState.Closed;
        if (position.seniorPrincipal == 0) return PositionState.Idle;
        if (position.boosted) return PositionState.Boosted;
        return PositionState.Active;
    }

    function isMatched(uint256 positionId) public view returns (bool) {
        Position storage position = positions[positionId];
        return position.owner != address(0) && !position.settled && position.seniorPrincipal != 0;
    }

    function isFullyMatched(uint256 positionId) public view returns (bool) {
        Position storage position = positions[positionId];
        return isMatched(positionId) && position.seniorPrincipal >= position.targetSenior;
    }

    function freeSenior() public view returns (uint256) {
        return _idleUsdg();
    }

    /// @notice Free (non-queued) USDG value of lender shares.
    function freePrincipal(address senior) public view returns (uint256) {
        return CarryPool.convertToAssets(_freeShares(senior), totalShares, totalSeniorAssets);
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return CarryPool.convertToShares(assets, totalShares, totalSeniorAssets);
    }

    function convertToAssets(uint256 shares_) external view returns (uint256) {
        return CarryPool.convertToAssets(shares_, totalShares, totalSeniorAssets);
    }

    function claimableWithdraw(address user) external view returns (uint256) {
        return CarryPool.claimableQueued(wqRequested[user], wqClaimed[user], wqCursor[user], wqCumulativeFulfilled);
    }

    /// @notice USDG a market-0 (MSTR) junior of `mstrAmount` is matched against at the current price.
    function previewSeniorAssets(uint256 mstrAmount) public view returns (uint256) {
        return previewMarketSeniorAssets(0, mstrAmount);
    }

    /// @notice USDG a junior of `amount` stock tokens in `marketId` is matched against at the current price.
    function previewMarketSeniorAssets(uint256 marketId, uint256 amount) public view returns (uint256) {
        return CarryMath.seniorAssets(amount, _priceView(marketId), markets[marketId].decimals, usdgDecimals);
    }

    /// @notice Compatibility alias: senior principal ≈ share assets (incl. queued).
    function seniorPrincipal(address senior) external view returns (uint256) {
        return CarryPool.convertToAssets(shares[senior], totalShares, totalSeniorAssets);
    }

    // ─── internal settle / exit ──────────────────────────────────────────────

    function _settle(uint256 positionId, CoverMode mode) internal returns (Settlement memory result) {
        Position storage position = _maturedPosition(positionId);
        address junior = position.owner;
        uint256 gross = position.feeUsdg;
        result = _settleQuote(position, mode);

        // Healthy positions roll at term; only the junior closes them.
        if (msg.sender != junior && !_stoppedPastGrace(position)) revert NotJunior();
        result.mstrKept = position.mstrAmount;

        // Senior fee share compounds into the pool; matched principal returns to idle.
        _creditPoolUsdg(result.seniorPerf);
        backstop += result.treasury;
        reservedSenior -= position.seniorPrincipal;
        if (positionPoolShares[positionId] != 0) {
            // Pooled share: _exitPool books its treasury and senior parts itself.
            PoolExit memory x = _exitPool(positionId, position);
            result.treasury += x.treasury;
            result.seniorPerf += x.senior;
            result.juniorYield += x.juniorUsdg;
            result.mstrKept = result.mstrKept + x.juniorStock - x.stockIn;
            result.mstrSold = x.stockSold;
        }

        position.settled = true;
        position.feeUsdg = 0;
        _reduceUnsplitFees(gross);
        _closePosition(positionId, position);

        emit WaterfallApplied(positionId, gross, 0, 0, result.treasury, result.seniorPerf, result.juniorYield);
        emit Settled(positionId, junior, result.mstrKept, result.mstrSold, result.treasury, result.juniorYield);

        _fillWithdrawQueue();
        _refundAllGasCredit(junior);
        _deliverJuniorExit(junior, position.marketId, result.mstrKept, result.juniorYield);
        // Rematch only after withdrawal queue paid.
        if (autoCompound[junior]) {
            _matchOpenPositions(_effectiveMatchCap());
        }
    }

    function _earlyExit(uint256 positionId, CoverMode mode) internal returns (EarlyExitResult memory result) {
        Position storage position = _inTermPosition(positionId);
        if (position.owner != msg.sender) revert NotJunior();

        uint256 matchedPrincipal = position.seniorPrincipal;
        WaterfallSplit memory split = _splitAndClearFees(positionId);
        _fillEarlyExitQuote(result, position, split, mode);
        result.mstrReturned = position.mstrAmount;
        if (positionPoolShares[positionId] != 0) {
            PoolExit memory x = _exitPool(positionId, position);
            result.treasury += x.treasury;
            result.seniorPerf += x.senior;
            result.juniorLeftoverFees += x.juniorUsdg;
            result.mstrReturned = result.mstrReturned + x.juniorStock - x.stockIn;
            result.mstrSold = x.stockSold;
        }

        reservedSenior -= matchedPrincipal;
        position.settled = true;
        position.feeUsdg = 0;
        _closePosition(positionId, position);

        emit EarlyExit(
            positionId,
            msg.sender,
            result.accrual,
            result.seniorFloor,
            result.coverUsdg,
            result.mstrSold,
            result.mstrReturned,
            result.juniorLeftoverFees,
            mode
        );

        _fillWithdrawQueue();
        _refundAllGasCredit(msg.sender);
        _deliverJuniorExit(msg.sender, position.marketId, result.mstrReturned, result.juniorLeftoverFees);
    }

    /// @dev Fee split quote shared by `previewSettle` and `_settle`. There is no lender coupon, so
    ///      nothing is owed beyond fees: accrual, floor and cover fields stay zero (kept for the ABI).
    function _settleQuote(Position storage position, CoverMode mode) internal view returns (Settlement memory r) {
        WaterfallSplit memory split = _positionSplit(position);
        r.treasury = split.treasury;
        r.seniorPerf = split.seniorPerf;
        r.juniorYield = split.junior;
        r.coverMode = mode;
    }

    /// @dev Early-exit quote shared by `previewEarlyExit` and `_earlyExit`. Exiting costs nothing.
    function _fillEarlyExitQuote(
        EarlyExitResult memory r,
        Position storage position,
        WaterfallSplit memory split,
        CoverMode mode
    ) internal view {
        r.elapsed = _elapsedSinceSplit(position);
        r.coverMode = mode;
        r.treasury = split.treasury;
        r.seniorPerf = split.seniorPerf;
        r.juniorLeftoverFees = split.junior;
    }

    /// @dev Open and matched. Positions roll at term, so this holds past the term too.
    function _livePosition(uint256 positionId) internal view returns (Position storage position) {
        position = positions[positionId];
        if (position.owner == address(0) || position.settled) revert BadPosition();
        if (position.seniorPrincipal == 0) revert NotMatched();
    }

    /// @dev Open, matched, still inside its first term (early exit).
    function _inTermPosition(uint256 positionId) internal view returns (Position storage position) {
        position = _livePosition(positionId);
        if (block.timestamp >= uint256(position.openedAt) + term) revert TermElapsed();
    }

    /// @dev Past term, priced more than the market range below entry, and the 48h grace since the
    ///      last term boundary is over: the position has stopped rolling and anyone may settle it.
    function _stoppedPastGrace(Position storage position) internal view returns (bool) {
        uint256 start = position.openedAt;
        uint256 t = term;
        if (block.timestamp < start + t) return false;
        uint256 boundary = start + (block.timestamp - start) / t * t;
        if (block.timestamp < boundary + UNDERWATER_GRACE) return false;
        uint256 id = position.marketId;
        return _price(id) < position.entryPriceWad * (WAD - markets[id].rangeDropWad) / WAD;
    }

    /// @dev Open, matched, term elapsed.
    function _maturedPosition(uint256 positionId) internal view returns (Position storage position) {
        position = positions[positionId];
        if (position.owner == address(0)) revert BadPosition();
        if (position.settled) revert AlreadySettled();
        if (position.seniorPrincipal == 0) revert NotMatched();
        if (block.timestamp < uint256(position.openedAt) + term) revert TermNotElapsed();
    }

    /// @dev Fully matched: move the position's stock and senior USDG into its market's pool, if it has one.
    function _enterPool(uint256 positionId, Position storage position) internal {
        DualPoolKey memory key = marketPool[position.marketId];
        if (key.hooks == address(0)) return;
        uint256 amount = position.seniorPrincipal;
        _push(usdg, address(strategy), amount);
        _push(markets[position.marketId].token, address(strategy), position.mstrAmount);
        (uint256 lpShares, uint256 usdgUsed) = strategy.enterPool(positionId, key, position.mstrAmount, amount);
        positionPoolShares[positionId] = lpShares;
        poolDeployed += usdgUsed;
    }

    /// @dev Pool share out, split by the strategy (treasury, senior, junior). Books the treasury cut to the
    ///      backstop and the senior's yield and cut to the pool; a senior payout below what it put in is
    ///      covered by the backstop, and past that is a lender loss.
    function _exitPool(uint256 positionId, Position storage position) internal returns (PoolExit memory x) {
        uint256 id = position.marketId;
        x = strategy.exitPool(
            positionId, marketPool[id], _price(id), _cutWadForPosition(position), SENIOR_PERF_CUT_WAD, sellSharesRouter
        );
        positionPoolShares[positionId] = 0;
        poolDeployed -= x.usdgIn;
        backstop += x.treasury;
        if (x.senior >= x.usdgIn) {
            totalSeniorAssets += x.senior - x.usdgIn;
        } else {
            uint256 gap = x.usdgIn - x.senior;
            uint256 cover = gap < backstop ? gap : backstop;
            backstop -= cover;
            totalSeniorAssets -= gap - cover;
        }
    }

    function _closePosition(uint256 positionId, Position storage position) internal {
        // Fully matched positions already left the open queue; skip the O(n) walk for them.
        if (position.seniorPrincipal < position.targetSenior) _dequeueOpen(positionId);
        _releaseJuniorCap(position.owner, positionId);
    }

    function _positionSplit(Position storage position) internal view returns (WaterfallSplit memory) {
        return _waterfallFromGross(position.feeUsdg, 0, _cutWadForPosition(position));
    }

    function _reduceUnsplitFees(uint256 gross) internal {
        totalUnsplitFees = gross > totalUnsplitFees ? 0 : totalUnsplitFees - gross;
    }

    function _splitAndClearFees(uint256 positionId) internal returns (WaterfallSplit memory split) {
        Position storage position = positions[positionId];
        uint256 gross = position.feeUsdg;
        split = _positionSplit(position);
        position.feeUsdg = 0;
        _reduceUnsplitFees(gross);
        backstop += split.treasury;
        _creditPoolUsdg(split.seniorTotal);
        emit WaterfallApplied(
            positionId, gross, split.accrual, split.seniorFloor, split.treasury, split.seniorPerf, split.junior
        );
    }

    function _waterfallFromGross(uint256 gross, uint256 accrual, uint256 cutWad)
        internal
        pure
        returns (WaterfallSplit memory s)
    {
        CarryMath.WaterfallSplit memory w =
            CarryMath.waterfallFromGross(gross, accrual, cutWad, SENIOR_PERF_CUT_WAD);
        s.accrual = w.accrual;
        s.seniorFloor = w.seniorFloor;
        s.treasury = w.treasury;
        s.seniorPerf = w.seniorPerf;
        s.junior = w.junior;
        s.seniorTotal = w.seniorTotal;
    }

    // ─── pool / queue / match ────────────────────────────────────────────────

    function _idleUsdg() internal view returns (uint256) {
        uint256 locked = reservedSenior + queueClaimable;
        return totalSeniorAssets > locked ? totalSeniorAssets - locked : 0;
    }

    function _fillWithdrawQueue() internal {
        uint256 pending =
            wqCumulativeRequested > wqCumulativeFulfilled ? wqCumulativeRequested - wqCumulativeFulfilled : 0;
        if (pending == 0) return;
        uint256 idle = _idleUsdg();
        if (idle == 0) return;
        uint256 pay = idle < pending ? idle : pending;
        wqCumulativeFulfilled += pay;
        queueClaimable += pay;
    }

    function _matchOpenPositions(uint256 maxIters) internal returns (uint256 totalMatched) {
        // Queue paid before new matching.
        _fillWithdrawQueue();
        uint256 id = openHead;
        uint256 iters;
        while (id != 0 && iters < maxIters) {
            uint256 next = openNext[id];
            totalMatched += _tryMatch(id);
            id = next;
            unchecked {
                ++iters;
            }
            if (_idleUsdg() == 0) break;
        }
    }

    function _tryMatch(uint256 positionId) internal returns (uint256 delta) {
        Position storage position = positions[positionId];
        if (position.owner == address(0) || position.settled) return 0;
        if (position.seniorPrincipal >= position.targetSenior) return 0;
        if (position.openedAt != 0 && block.timestamp >= uint256(position.openedAt) + term) {
            // Partially matched and past term: never matchable again, so drop it from the open queue
            // instead of letting it use up match iterations ahead of live positions.
            _dequeueOpen(positionId);
            return 0;
        }

        uint256 idle = _idleUsdg();
        if (idle == 0) return 0;

        uint256 residual = position.targetSenior - position.seniorPrincipal;
        delta = idle < residual ? idle : residual;
        uint256 minDep = _minDeposit();
        bool starting = position.seniorPrincipal == 0;
        bool completing = position.seniorPrincipal > 0 && delta == residual;
        if (delta < minDep && (starting || !completing)) return 0;

        if (starting) {
            position.entryPriceWad = _price(position.marketId);
            position.openedAt = uint64(block.timestamp);
            position.lastFeeSplitAt = uint64(block.timestamp);
            position.treasuryCutLocked = _tierCutForUser(position.owner);
            position.boosted = treasuryCutIsSet && position.treasuryCutLocked < treasuryCutWad;
        }

        position.seniorPrincipal += delta;
        reservedSenior += delta;

        if (position.seniorPrincipal >= position.targetSenior) {
            _dequeueOpen(positionId);
            _enterPool(positionId, position);
        }
        emit PositionMatched(positionId, position.owner, position.seniorPrincipal, delta, position.openedAt);
    }

    function _creditPoolUsdg(uint256 amount) internal {
        if (amount == 0) return;
        totalSeniorAssets += amount;
    }

    function _freeShares(address user) internal view returns (uint256) {
        uint256 bal = shares[user];
        uint256 locked = wqSharesLocked[user];
        return bal > locked ? bal - locked : 0;
    }

    /// @dev Burn `burn` shares of `user` and take `assets` out of the pool NAV.
    function _redeem(address user, uint256 burn, uint256 assets) internal {
        if (burn != 0) {
            uint256 bal = shares[user];
            if (burn > bal) revert InsufficientFree();
            shares[user] = bal - burn;
            totalShares -= burn;
        }
        totalSeniorAssets -= assets;
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _withdrawBackstop(address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > backstop) revert InsufficientBackstop();
        backstop -= amount;
        // Floor: senior pool NAV + remaining backstop + unsplit position fees (+ queue is inside NAV).
        uint256 floor = totalSeniorAssets + backstop + totalUnsplitFees;
        if (usdg.balanceOf(address(this)) + strategyDeployed + poolDeployed < floor) revert InsufficientBackstop();
        _push(usdg, to, amount);
    }

    function _effectiveMatchCap() internal view returns (uint256) {
        return matchCap == 0 ? DEFAULT_MATCH_CAP : matchCap;
    }

    function _enqueueOpen(uint256 positionId) internal {
        if (openTail == 0) {
            openHead = positionId;
            openTail = positionId;
        } else {
            openNext[openTail] = positionId;
            openTail = positionId;
        }
    }

    function _dequeueOpen(uint256 positionId) internal {
        if (openHead == 0) return;
        if (openHead == positionId) {
            openHead = openNext[positionId];
            openNext[positionId] = 0;
            if (openHead == 0) openTail = 0;
            return;
        }
        uint256 prev = openHead;
        while (prev != 0 && openNext[prev] != positionId) {
            prev = openNext[prev];
        }
        if (prev == 0) return;
        openNext[prev] = openNext[positionId];
        openNext[positionId] = 0;
        if (openTail == positionId) openTail = prev;
    }

    function _elapsedSinceSplit(Position storage position) internal view returns (uint256) {
        uint256 start = position.lastFeeSplitAt != 0 ? uint256(position.lastFeeSplitAt) : uint256(position.openedAt);
        return block.timestamp > start ? block.timestamp - start : 0;
    }

    function _cutWadForPosition(Position storage position) internal view returns (uint256) {
        if (!treasuryCutIsSet) return 0;
        if (position.treasuryCutLocked != 0) return position.treasuryCutLocked;
        return _tierCutForUser(position.owner);
    }

    function _tierCutForUser(address user) internal view returns (uint256) {
        if (!treasuryCutIsSet) return 0;
        uint256 cut = treasuryCutWad;
        IBoostHook hook = boostHook;
        if (address(hook) == address(0)) return cut;
        uint256 boosted = hook.treasuryCutOf(user, cut);
        return boosted < cut ? boosted : cut;
    }

    function setBoostHook(IBoostHook hook) external onlyOwner {
        boostHook = hook;
        emit BoostHookUpdated(address(hook));
    }

    function _minDeposit() internal view returns (uint256) {
        return minDepositUsdg == 0 ? DEFAULT_MIN_DEPOSIT_DOLLARS * 10 ** usdgDecimals : minDepositUsdg;
    }

    function _refundAllGasCredit(address junior) internal {
        uint256 bal = gasCreditWei[junior];
        if (bal == 0) return;
        gasCreditWei[junior] = 0;
        (bool ok,) = junior.call{value: bal}("");
        if (!ok) {
            pendingEthCredit[junior] += bal;
            emit PendingEthCredited(junior, bal, pendingEthCredit[junior]);
        }
        emit GasCreditWithdrawn(junior, bal, 0);
    }

    function _deliverJuniorExit(address junior, uint256 marketId, uint256 stockAmt, uint256 usdgAmt) internal {
        // Auto-compound reopens the stock as a new position in the same market (or returns it if under the minimum).
        if (autoCompound[junior]) _openJuniorFromVaultBalance(junior, marketId, stockAmt, true);
        else if (stockAmt > 0) _push(markets[marketId].token, junior, stockAmt);
        _deliverJuniorUsdg(junior, usdgAmt);
    }

    function _deliverJuniorUsdg(address junior, uint256 amount) internal {
        if (amount == 0) return;
        if (autoCompound[junior]) {
            if (amount >= _minDeposit()) {
                _compoundUsdgAsSenior(junior, amount);
            } else {
                // Under $25 → wallet (no unmatchable clog).
                _push(usdg, junior, amount);
            }
        } else {
            _push(usdg, junior, amount);
        }
    }

    function _openJuniorFromVaultBalance(address junior, uint256 marketId, uint256 mstrAmount, bool fromExit)
        internal
        returns (uint256 positionId)
    {
        if (mstrAmount == 0) return 0;
        if (!fromExit && paused) revert Paused();
        Market storage m = markets[marketId];
        uint256 notional = previewMarketSeniorAssets(marketId, mstrAmount);
        if (!fromExit) {
            if (notional < _minDeposit()) revert BelowMinDeposit();
            _enforceJuniorCap(junior, notional);
            if (m.juniorCapUsdg != 0 && m.juniorUsdg + notional > m.juniorCapUsdg) revert CapExceeded();
        } else if (notional < _minDeposit() || !m.active) {
            _push(m.token, junior, mstrAmount);
            return 0;
        }

        _fillWithdrawQueue();

        positionId = nextPositionId++;
        positions[positionId] = Position({
            owner: junior,
            mstrAmount: mstrAmount,
            seniorPrincipal: 0,
            targetSenior: notional,
            entryPriceWad: 0,
            feeUsdg: 0,
            openedAt: 0,
            lastFeeSplitAt: 0,
            settled: false,
            boosted: false,
            unpaidSeniorAccrual: 0,
            rateIndexSnapshot: 0,
            treasuryCutLocked: 0,
            marketId: marketId
        });
        _enqueueOpen(positionId);
        m.juniorUsdg += notional;
        totalJuniorUsdg += notional;
        positionJuniorUsdg[positionId] = notional;

        bool matched = _tryMatch(positionId) > 0;
        emit JuniorDeposit(positionId, junior, mstrAmount, matched);
    }

    function _compoundUsdgAsSenior(address user, uint256 amount) internal {
        if (_mintSeniorShares(user, amount) == 0) return;
        _matchOpenPositions(_effectiveMatchCap());
    }

    function _mintSeniorShares(address user, uint256 amount) internal returns (uint256 minted) {
        minted = CarryPool.convertToShares(amount, totalShares, totalSeniorAssets);
        if (minted == 0) return 0;
        shares[user] += minted;
        totalShares += minted;
        totalSeniorAssets += amount;
    }

    /// @dev Gas refund only when deposit actually matches; scaled to matched amount.
    function _payGasRefundOnMatch(address senior, address sponsor, uint256 matched, uint256 deposited) internal {
        if (matched == 0 || deposited == 0 || gasRefundWei == 0 || sponsor == address(0)) return;
        uint256 refund = gasRefundWei * matched / deposited;
        if (refund == 0) return;
        uint256 bal = gasCreditWei[sponsor];
        if (bal == 0) return;
        uint256 pay = bal < refund ? bal : refund;
        gasCreditWei[sponsor] = bal - pay;
        (bool ok,) = senior.call{value: pay}("");
        if (!ok) {
            pendingEthCredit[senior] += pay;
            emit PendingEthCredited(senior, pay, pendingEthCredit[senior]);
        }
        emit GasCreditConsumed(sponsor, senior, pay);
    }

    function _gasSponsor() internal view returns (address) {
        uint256 id = openHead;
        if (id == 0) return address(0);
        Position storage position = positions[id];
        if (position.owner == address(0) || position.settled) return address(0);
        return position.owner;
    }

    function _price(uint256 marketId) internal view returns (uint256 price) {
        price = _priceView(marketId);
        if (maxPriceStale != 0) {
            try IPushablePriceOracle(address(markets[marketId].oracle)).lastUpdatedAt() returns (uint64 updated) {
                if (block.timestamp > uint256(updated) + maxPriceStale) revert StalePrice();
            } catch {
                // Non-pushable oracle (FixedPrice / Mock): no staleness data.
            }
        }
    }

    function _priceView(uint256 marketId) internal view returns (uint256 price) {
        IPriceOracle o = markets[marketId].oracle;
        if (address(o) == address(0)) revert BadMarket();
        price = o.mstrPriceWad();
        if (price == 0) revert BadPrice();
    }

    function _enforceSeniorCap(address, uint256 amount) internal view {
        if (maxTotalSeniorUsdg != 0 && totalSeniorAssets + amount > maxTotalSeniorUsdg) revert CapExceeded();
    }

    function _enforceJuniorCap(address, uint256 notional) internal view {
        if (maxTotalJuniorUsdg != 0 && totalJuniorUsdg + notional > maxTotalJuniorUsdg) revert CapExceeded();
    }

    function _releaseJuniorCap(address, uint256 positionId) internal {
        uint256 notional = positionJuniorUsdg[positionId];
        if (notional == 0) return;
        positionJuniorUsdg[positionId] = 0;
        Market storage m = markets[positions[positionId].marketId];
        m.juniorUsdg = notional > m.juniorUsdg ? 0 : m.juniorUsdg - notional;
        if (notional > totalJuniorUsdg) totalJuniorUsdg = 0;
        else totalJuniorUsdg -= notional;
    }

    function _pullExact(IERC20Minimal token, address from, uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        if (!token.transferFrom(from, address(this), amount)) revert TransferFailed();
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert FeeOnTransfer();
    }

    function _push(IERC20Minimal token, address to, uint256 amount) internal {
        if (token == usdg && strategyDeployed != 0) {
            uint256 bal = token.balanceOf(address(this));
            if (bal < amount) {
                uint256 need = amount - bal;
                strategyDeployed = need > strategyDeployed ? 0 : strategyDeployed - need;
                strategy.withdraw(need, address(this));
            }
        }
        if (!token.transfer(to, amount)) revert TransferFailed();
    }

    function _harvest() internal {
        if (strategyDeployed == 0) return;
        uint256 value = strategy.idleAssets();
        if (value > strategyDeployed) {
            totalSeniorAssets += value - strategyDeployed;
            strategyDeployed = value;
        }
    }
}
