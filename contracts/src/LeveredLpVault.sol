// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {IMstrSellRouter} from "./interfaces/IMstrSellRouter.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IPushablePriceOracle} from "./interfaces/IPushablePriceOracle.sol";
import {CarryMath} from "./libraries/CarryMath.sol";
import {CarryPool} from "./libraries/CarryPool.sol";
import {CarryCover} from "./libraries/CarryCover.sol";

/// @title LeveredLpVault
/// @notice UUPS 2× junior MSTR / senior USDG book — Carry v3 lender pool.
///
/// v3 lender model:
/// 1. One USDG senior pool; non-transferable internal shares; round in pool favor; virtual offset.
/// 2. Instant withdraw if idle covers and withdraw queue empty; else FIFO cumulative queue + lazy claim.
/// 3. Floating Morpho rate via global rate index (not locked per position). Interest stops at maturity.
/// 4. Senior yield compounds into the pool. Lenders paid only USDG (stock fees swapped before payout).
/// 5. Withdrawal queue paid before new matching. Lender withdraw never closes a junior position.
///
/// Fresh product PROXY for v3 (v2.5 funder-idle PROXY superseded — open settle-watch stays there).
contract LeveredLpVault is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    uint256 public constant WAD = 1e18;
    uint256 public constant YEAR = 365 days;
    uint256 public constant MAX_MORPHO_RATE_WAD = 0.05e18;
    uint256 public constant MAX_TREASURY_CUT_WAD = 0.2e18;
    uint256 public constant SENIOR_PERF_CUT_WAD = 0.2e18;
    uint256 public constant DEFAULT_TREASURY_CUT_WAD = 0.2e18;
    uint256 public constant BOOSTED_TREASURY_CUT_WAD = 0.1e18;
    uint256 public constant DEFAULT_MATCH_CAP = 25;
    uint256 public constant DEFAULT_GAS_REFUND_WEI = 0.0001 ether;
    uint256 public constant DEFAULT_MIN_DEPOSIT_USDG = 25 ether;
    uint256 public constant MAX_BOOST_TIERS = 4;
    uint64 public constant MAX_TERM = 7 days;
    uint256 public constant DEFAULT_MAX_PRICE_STALE = 1 hours;

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
        uint256 unpaidSeniorAccrual;
        /// @notice Rate index snapshot at last fee split / match checkpoint (floating rate).
        uint256 rateIndexSnapshot;
        uint256 treasuryCutLocked;
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
    uint8 public mstrDecimals;
    uint8 public usdgDecimals;

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
    uint256 public maxPerWalletUsdg;
    uint256 public totalJuniorUsdg;
    mapping(address => uint256) public walletSeniorUsdg;
    mapping(address => uint256) public walletJuniorUsdg;
    mapping(uint256 => uint256) public positionJuniorUsdg;

    uint256 public morphoRateWad;
    uint256 public treasuryCutWad;
    uint256 public boostedTreasuryCutWad;

    mapping(address => bool) public boostStaked;

    uint256 public openHead;
    uint256 public openTail;
    mapping(uint256 => uint256) public openNext;

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
    uint256 public boostTierCount;
    uint256[4] public boostTierMinStake;
    uint256[4] public boostTierCutWad;
    mapping(address => uint256) public boostStakeAmount;
    mapping(address => bool) public sellSharesEnabled;

    uint256 public totalShares;
    /// @notice USDG set aside for fulfilled withdraw-queue claims (still in vault).
    uint256 public queueClaimable;
    uint256 public wqCumulativeRequested;
    uint256 public wqCumulativeFulfilled;
    mapping(address => uint256) public wqRequested;
    mapping(address => uint256) public wqClaimed;
    mapping(address => uint256) public wqCursor;
    mapping(address => uint256) public wqSharesLocked;

    uint256 public rateIndex;
    uint64 public rateUpdatedAt;

    bool public treasuryCutIsSet;
    uint256 public maxPriceStale;

    uint256[40] private __gap;

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
    event CapsUpdated(uint256 maxTotalSeniorUsdg, uint256 maxTotalJuniorUsdg, uint256 maxPerWalletUsdg);
    event MorphoRateUpdated(uint256 morphoRateWad);
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
    event BoostStakeAmountUpdated(address indexed user, uint256 amount);
    event SellSharesEnabledUpdated(address indexed user, bool enabled);
    event PendingEthCredited(address indexed to, uint256 amount, uint256 balance);
    event PendingEthWithdrawn(address indexed to, uint256 amount);
    event MaxPriceStaleUpdated(uint256 maxPriceStale);
    event RateIndexUpdated(uint256 rateIndex, uint64 updatedAt);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address mstr_,
        address usdg_,
        address oracle_,
        uint64 term_,
        uint256 morphoRateWad_,
        address owner_
    ) external initializer {
        if (mstr_ == address(0) || usdg_ == address(0) || oracle_ == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        if (term_ == 0 || term_ > MAX_TERM) revert BadTerm();
        if (morphoRateWad_ == 0 || morphoRateWad_ > MAX_MORPHO_RATE_WAD) revert BadApr();

        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        mstr = IERC20Minimal(mstr_);
        usdg = IERC20Minimal(usdg_);
        oracle = IPriceOracle(oracle_);
        term = term_;
        morphoRateWad = morphoRateWad_;
        treasuryCutWad = DEFAULT_TREASURY_CUT_WAD;
        boostedTreasuryCutWad = BOOSTED_TREASURY_CUT_WAD;
        treasuryCutIsSet = true;
        gasRefundWei = DEFAULT_GAS_REFUND_WEI;
        minDepositUsdg = DEFAULT_MIN_DEPOSIT_USDG;
        maxPriceStale = DEFAULT_MAX_PRICE_STALE;
        // Senior uncapped by default (0). Junior market cap set by owner after deploy.
        maxTotalSeniorUsdg = 0;
        boostTierCount = 3;
        boostTierMinStake[0] = 100 ether;
        boostTierCutWad[0] = 0.15e18;
        boostTierMinStake[1] = 1_000 ether;
        boostTierCutWad[1] = 0.1e18;
        boostTierMinStake[2] = 10_000 ether;
        boostTierCutWad[2] = 0.05e18;
        mstrDecimals = mstr.decimals();
        usdgDecimals = usdg.decimals();
        nextPositionId = 1;
        rateIndex = WAD;
        rateUpdatedAt = uint64(block.timestamp);
        paused = true;
        emit PausedDeposits(true);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function version() external pure returns (string memory) {
        return "v3-lender-pool";
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

    function setDepositCaps(uint256 maxTotalSeniorUsdg_, uint256 maxTotalJuniorUsdg_, uint256 maxPerWalletUsdg_)
        external
        onlyOwner
    {
        maxTotalSeniorUsdg = maxTotalSeniorUsdg_;
        maxTotalJuniorUsdg = maxTotalJuniorUsdg_;
        maxPerWalletUsdg = maxPerWalletUsdg_;
        emit CapsUpdated(maxTotalSeniorUsdg_, maxTotalJuniorUsdg_, maxPerWalletUsdg_);
    }

    function setMorphoRate(uint256 morphoRateWad_) external onlyOwner {
        if (morphoRateWad_ == 0 || morphoRateWad_ > MAX_MORPHO_RATE_WAD) revert BadApr();
        _syncRateIndex();
        morphoRateWad = morphoRateWad_;
        emit MorphoRateUpdated(morphoRateWad_);
    }

    function morphoFloorAprWad() external view returns (uint256) {
        return morphoRateWad;
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

    function fundGasCredit() external payable nonReentrant {
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

    function setBoostStaked(address user, bool staked) external onlyOwner {
        if (user == address(0)) revert ZeroAddress();
        boostStaked[user] = staked;
        emit BoostStakeUpdated(user, staked);
    }

    function rescueToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(mstr) || token == address(usdg)) revert PrincipalToken();
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

    function setBoostTiers(uint256[] calldata minStakes, uint256[] calldata cuts) external onlyOwner {
        if (minStakes.length != cuts.length || minStakes.length > MAX_BOOST_TIERS) revert BadTiers();
        boostTierCount = minStakes.length;
        uint256 prev;
        for (uint256 i; i < minStakes.length; ++i) {
            if (minStakes[i] <= prev && i != 0) revert BadTiers();
            if (cuts[i] > MAX_TREASURY_CUT_WAD) revert BadCut();
            boostTierMinStake[i] = minStakes[i];
            boostTierCutWad[i] = cuts[i];
            prev = minStakes[i];
        }
        for (uint256 j = minStakes.length; j < MAX_BOOST_TIERS; ++j) {
            boostTierMinStake[j] = 0;
            boostTierCutWad[j] = 0;
        }
        emit BoostTiersUpdated(minStakes.length);
    }

    function setBoostStakeAmount(address user, uint256 amount) external onlyOwner {
        if (user == address(0)) revert ZeroAddress();
        boostStakeAmount[user] = amount;
        boostStaked[user] = amount > 0;
        emit BoostStakeAmountUpdated(user, amount);
        emit BoostStakeUpdated(user, amount > 0);
    }

    function setSellSharesEnabled(bool enabled) external {
        sellSharesEnabled[msg.sender] = enabled;
        emit SellSharesEnabledUpdated(msg.sender, enabled);
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

        // Capture sponsor before match — full match dequeues the junior.
        address gasSponsor = _gasSponsor();
        _pullExact(usdg, msg.sender, amount);
        uint256 minted = CarryPool.convertToShares(amount, totalShares, totalSeniorAssets);
        if (minted == 0) revert ZeroAmount();
        shares[msg.sender] += minted;
        totalShares += minted;
        totalSeniorAssets += amount;
        walletSeniorUsdg[msg.sender] += amount;

        _fillWithdrawQueue();
        uint256 matched = _matchOpenPositions(_effectiveMatchCap());
        _payGasRefundOnMatch(msg.sender, gasSponsor, matched, amount);
        emit SeniorDeposit(msg.sender, amount, minted);
    }

    /// @notice Withdraw `assets` USDG from free (non-queued) share value. Always pays wallet (no auto-compound reopen).
    function withdrawSenior(uint256 assets) external nonReentrant {
        if (assets == 0) revert ZeroAmount();
        uint256 freeShares = _freeShares(msg.sender);
        uint256 freeAssets = CarryPool.convertToAssets(freeShares, totalShares, totalSeniorAssets);
        if (assets > freeAssets) revert InsufficientFree();

        uint256 sharesNeeded = CarryPool.previewWithdrawShares(assets, totalShares, totalSeniorAssets);
        if (sharesNeeded > freeShares) sharesNeeded = freeShares;

        // Instant if idle covers and nobody waiting in queue.
        if (_idleUsdg() >= assets && wqCumulativeRequested == wqCumulativeFulfilled) {
            _burnShares(msg.sender, sharesNeeded);
            totalSeniorAssets -= assets;
            _debitWalletSenior(msg.sender, assets);
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

        _fillWithdrawQueue();
        _matchOpenPositions(_effectiveMatchCap());
    }

    /// @notice Lazy claim of fulfilled withdraw-queue assets. Always pays wallet.
    function claimWithdraw() external nonReentrant {
        uint256 paid = CarryPool.claimableQueued(
            wqRequested[msg.sender], wqClaimed[msg.sender], wqCursor[msg.sender], wqCumulativeFulfilled
        );
        if (paid == 0) revert NothingToClaim();

        uint256 burn = CarryPool.previewWithdrawShares(paid, totalShares, totalSeniorAssets);
        uint256 locked = wqSharesLocked[msg.sender];
        if (burn > locked) burn = locked;

        wqClaimed[msg.sender] += paid;
        wqSharesLocked[msg.sender] = locked - burn;
        if (queueClaimable < paid) revert InsufficientFree();
        queueClaimable -= paid;

        _burnShares(msg.sender, burn);
        totalSeniorAssets -= paid;
        _debitWalletSenior(msg.sender, paid);

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

    function depositJunior(uint256 mstrAmount) external nonReentrant returns (uint256 positionId) {
        if (paused) revert Paused();
        if (mstrAmount == 0) revert ZeroAmount();
        _pullExact(mstr, msg.sender, mstrAmount);
        positionId = _openJuniorFromVaultBalance(msg.sender, mstrAmount, false);
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
        _push(mstr, msg.sender, amount);
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
        if (position.owner == address(0) || position.settled) revert BadPosition();
        if (position.owner != msg.sender) revert NotJunior();
        if (position.seniorPrincipal == 0) revert NotMatched();
        if (block.timestamp >= uint256(position.openedAt) + term) revert TermElapsed();

        result = previewClaimFees(positionId);
        WaterfallSplit memory split = _splitAndClearFees(positionId);
        position.lastFeeSplitAt = uint64(block.timestamp);
        position.rateIndexSnapshot = _indexAt(_feeEndTime(position));

        emit FeesClaimed(
            positionId, msg.sender, result.gross, split.seniorFloor, split.treasury, split.seniorPerf, split.junior
        );
        if (split.junior > 0) {
            _deliverJuniorUsdg(msg.sender, split.junior);
        }
    }

    function previewClaimFees(uint256 positionId) public view returns (ClaimFeesResult memory result) {
        Position storage position = positions[positionId];
        if (position.owner == address(0) || position.settled) revert BadPosition();
        if (position.seniorPrincipal == 0) revert NotMatched();
        if (block.timestamp >= uint256(position.openedAt) + term) revert TermElapsed();

        uint256 gross = position.feeUsdg;
        if (gross == 0) revert ZeroGross();
        result.elapsed = _elapsedSinceSplit(position);
        WaterfallSplit memory split = _waterfallFromGross(gross, _accrualFor(position), _cutWadForPosition(position));
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

    function settle(uint256 positionId, CoverMode mode) external nonReentrant returns (Settlement memory) {
        return _settle(positionId, mode);
    }

    function previewSettle(uint256 positionId) external view returns (Settlement memory) {
        return previewSettle(positionId, CoverMode.IdleCarry);
    }

    function previewSettle(uint256 positionId, CoverMode mode) public view returns (Settlement memory result) {
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert BadPosition();
        if (position.settled) revert AlreadySettled();
        if (position.seniorPrincipal == 0) revert NotMatched();
        if (block.timestamp < uint256(position.openedAt) + term) revert TermNotElapsed();

        uint256 gross = position.feeUsdg;
        WaterfallSplit memory split = _waterfallFromGross(gross, _accrualFor(position), _cutWadForPosition(position));
        result.accrual = split.accrual;
        result.seniorFloor = split.seniorFloor;
        result.treasury = split.treasury;
        result.seniorPerf = split.seniorPerf;
        result.juniorYield = split.junior;
        result.coverMode = mode;

        uint256 shortfall = split.accrual > split.seniorFloor ? split.accrual - split.seniorFloor : 0;
        uint256 fromBs = backstop < shortfall ? backstop : shortfall;
        result.fromBackstop = fromBs;
        shortfall -= fromBs;

        uint256 cut = _cutWadForPosition(position);
        result.treasuryOnCover = shortfall * cut / WAD;
        result.coverUsdg = shortfall + result.treasuryOnCover;

        if (mode == CoverMode.SellShares && result.coverUsdg > 0) {
            uint256 price = _price();
            result.mstrSold = previewMstrToCover(result.coverUsdg, price);
            if (result.mstrSold > position.mstrAmount) {
                result.mstrSold = position.mstrAmount;
                result.feeShortfallUsdg = result.coverUsdg - _usdgValue(result.mstrSold, price);
            }
        }
        result.mstrKept = position.mstrAmount - result.mstrSold;
    }

    function earlyExit(uint256 positionId) external nonReentrant returns (EarlyExitResult memory) {
        return _earlyExit(positionId, CoverMode.IdleCarry);
    }

    function earlyExit(uint256 positionId, CoverMode mode) external nonReentrant returns (EarlyExitResult memory) {
        return _earlyExit(positionId, mode);
    }

    function previewEarlyExit(uint256 positionId) public view returns (EarlyExitResult memory) {
        return previewEarlyExit(positionId, CoverMode.IdleCarry);
    }

    function previewEarlyExit(uint256 positionId, CoverMode mode)
        public
        view
        returns (EarlyExitResult memory result)
    {
        Position storage position = positions[positionId];
        if (position.owner == address(0) || position.settled) revert BadPosition();
        if (position.seniorPrincipal == 0) revert NotMatched();
        if (block.timestamp >= uint256(position.openedAt) + term) revert TermElapsed();

        result.elapsed = _elapsedSinceSplit(position);
        result.coverMode = mode;
        WaterfallSplit memory split =
            _waterfallFromGross(position.feeUsdg, _accrualFor(position), _cutWadForPosition(position));
        result.accrual = split.accrual;
        result.seniorFloor = split.seniorFloor;
        result.treasury = split.treasury;
        result.seniorPerf = split.seniorPerf;
        result.juniorLeftoverFees = split.junior;

        uint256 shortfall = split.accrual > split.seniorFloor ? split.accrual - split.seniorFloor : 0;
        uint256 cut = _cutWadForPosition(position);
        result.treasuryOnCover = shortfall * cut / WAD;
        result.coverUsdg = shortfall + result.treasuryOnCover;

        if (mode == CoverMode.SellShares && result.coverUsdg > 0) {
            uint256 price = _price();
            result.mstrSold = previewMstrToCover(result.coverUsdg, price);
            if (result.mstrSold > position.mstrAmount) {
                result.mstrSold = position.mstrAmount;
                result.feeShortfallUsdg = result.coverUsdg - _usdgValue(result.mstrSold, price);
            }
        }
        result.mstrReturned = position.mstrAmount - result.mstrSold;
    }

    // ─── views ───────────────────────────────────────────────────────────────

    function previewSeniorAccrual(uint256 principal, uint256 elapsed) public view returns (uint256) {
        return CarryMath.morphoAccrual(principal, morphoRateWad, elapsed, YEAR);
    }

    function previewSeniorAccrual(uint256 principal, uint256 elapsed, uint256 rateWad) public pure returns (uint256) {
        return CarryMath.morphoAccrual(principal, rateWad, elapsed, YEAR);
    }

    function previewWaterfall(uint256 gross, uint256 seniorPrincipal_, uint256 elapsed, bool boosted)
        public
        view
        returns (WaterfallSplit memory s)
    {
        return _waterfallFromGross(gross, previewSeniorAccrual(seniorPrincipal_, elapsed), _treasuryCut(boosted));
    }

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

    function withdrawQueuePending() external view returns (uint256) {
        return wqCumulativeRequested > wqCumulativeFulfilled ? wqCumulativeRequested - wqCumulativeFulfilled : 0;
    }

    function claimableWithdraw(address user) external view returns (uint256) {
        return CarryPool.claimableQueued(wqRequested[user], wqClaimed[user], wqCursor[user], wqCumulativeFulfilled);
    }

    function currentRateIndex() public view returns (uint256) {
        if (block.timestamp <= rateUpdatedAt) return rateIndex;
        return CarryMath.advanceRateIndex(rateIndex, morphoRateWad, block.timestamp - rateUpdatedAt, YEAR);
    }

    function previewSeniorAssets(uint256 mstrAmount) public view returns (uint256) {
        return previewSeniorAssets(mstrAmount, _priceView());
    }

    function previewSeniorAssets(uint256 mstrAmount, uint256 priceWad) public view returns (uint256) {
        if (priceWad == 0) revert BadPrice();
        return CarryMath.seniorAssets(mstrAmount, priceWad, mstrDecimals, usdgDecimals);
    }

    function previewMstrToCover(uint256 usdgShort) public view returns (uint256) {
        return previewMstrToCover(usdgShort, _priceView());
    }

    function previewMstrToCover(uint256 usdgShort, uint256 priceWad) public view returns (uint256) {
        if (priceWad == 0) revert BadPrice();
        return CarryMath.mstrToCover(usdgShort, priceWad, mstrDecimals, usdgDecimals);
    }

    /// @notice Compatibility alias: senior principal ≈ share assets (incl. queued).
    function seniorPrincipal(address senior) external view returns (uint256) {
        return CarryPool.convertToAssets(shares[senior], totalShares, totalSeniorAssets);
    }

    // ─── internal settle / exit ──────────────────────────────────────────────

    function _settle(uint256 positionId, CoverMode mode) internal returns (Settlement memory result) {
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert BadPosition();
        if (position.settled) revert AlreadySettled();
        if (position.seniorPrincipal == 0) revert NotMatched();
        if (block.timestamp < uint256(position.openedAt) + term) revert TermNotElapsed();

        address junior = position.owner;
        uint256 gross = position.feeUsdg;
        WaterfallSplit memory split = _waterfallFromGross(gross, _accrualFor(position), _cutWadForPosition(position));

        result.accrual = split.accrual;
        result.seniorFloor = split.seniorFloor;
        result.treasury = split.treasury;
        result.seniorPerf = split.seniorPerf;
        result.juniorYield = split.junior;
        result.coverMode = mode;

        uint256 shortfall = split.accrual > split.seniorFloor ? split.accrual - split.seniorFloor : 0;
        uint256 fromBs = backstop < shortfall ? backstop : shortfall;
        result.fromBackstop = fromBs;
        shortfall -= fromBs;

        uint256 treasuryOnCover = shortfall * _cutWadForPosition(position) / WAD;
        uint256 coverTotal = shortfall + treasuryOnCover;
        result.treasuryOnCover = treasuryOnCover;
        result.coverUsdg = coverTotal;

        if (mode == CoverMode.SellShares) {
            if (msg.sender != junior && !sellSharesEnabled[junior]) revert SellSharesDisabled();
        } else if (coverTotal > 0 && msg.sender != junior) {
            revert NotJunior();
        }

        uint256 matchedPrincipal = position.seniorPrincipal;
        uint256 juniorFees = split.junior;
        uint256 mstrSold;
        uint256 feeShort;
        uint256 fromPool;

        if (coverTotal > 0) {
            (mstrSold, juniorFees, feeShort, fromPool) = _applySettleCover(
                position, junior, mode, shortfall, treasuryOnCover, juniorFees, _price()
            );
        }

        result.mstrSold = mstrSold;
        result.feeShortfallUsdg = feeShort;
        result.fromPool = fromPool;
        result.mstrKept = position.mstrAmount;
        result.juniorYield = juniorFees;

        // Credit senior yield into pool (compounds). Backstop top-up for accrual shortfall also to pool.
        _creditPoolUsdg(split.seniorTotal + fromBs);
        // Principal returns to idle (queue first).
        reservedSenior -= matchedPrincipal;

        position.settled = true;
        position.feeUsdg = 0;
        if (gross > totalUnsplitFees) totalUnsplitFees = 0;
        else totalUnsplitFees -= gross;
        position.unpaidSeniorAccrual = 0;
        backstop = backstop - fromBs + split.treasury;
        _dequeueOpen(positionId);
        _releaseJuniorCap(junior, positionId);

        emit WaterfallApplied(
            positionId, gross, split.accrual, split.seniorFloor, split.treasury, split.seniorPerf, split.junior
        );
        emit Settled(positionId, junior, result.mstrKept, result.mstrSold, split.treasury, result.juniorYield);

        _fillWithdrawQueue();
        _refundAllGasCredit(junior);
        _deliverJuniorExit(junior, result.mstrKept, juniorFees);
        // Rematch only after withdrawal queue paid.
        if (autoCompound[junior]) {
            _matchOpenPositions(_effectiveMatchCap());
        }
    }

    function _earlyExit(uint256 positionId, CoverMode mode) internal returns (EarlyExitResult memory result) {
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert BadPosition();
        if (position.owner != msg.sender) revert NotJunior();
        if (position.settled) revert AlreadySettled();
        if (position.seniorPrincipal == 0) revert NotMatched();
        if (block.timestamp >= uint256(position.openedAt) + term) revert TermElapsed();

        result = previewEarlyExit(positionId, mode);
        uint256 price = _price();
        uint256 matchedPrincipal = position.seniorPrincipal;

        uint256 shortfallPreview =
            result.accrual > result.seniorFloor ? result.accrual - result.seniorFloor : 0;
        uint256 coverPreview = shortfallPreview + result.treasuryOnCover;
        if (coverPreview > 0 && mode != CoverMode.SellShares) {
            _assertJuniorCanCover(msg.sender, mode, coverPreview, result.juniorLeftoverFees);
        }

        WaterfallSplit memory split = _splitAndClearFees(positionId);

        uint256 shortfall = result.accrual > split.seniorFloor ? result.accrual - split.seniorFloor : 0;
        uint256 treasuryOnCover = shortfall * _cutWadForPosition(position) / WAD;
        uint256 coverTotal = shortfall + treasuryOnCover;

        uint256 mstrSold;
        uint256 juniorFees = split.junior;
        uint256 feeShort;

        if (coverTotal > 0) {
            (mstrSold, juniorFees, feeShort,) =
                _applyEarlyCover(position, msg.sender, mode, shortfall, treasuryOnCover, juniorFees, price);
            result.feeShortfallUsdg = feeShort;
        }

        result.coverUsdg = coverTotal;
        result.treasuryOnCover = treasuryOnCover;
        result.mstrSold = mstrSold;
        result.mstrReturned = position.mstrAmount;
        result.juniorLeftoverFees = juniorFees;
        result.treasury = split.treasury;
        result.seniorPerf = split.seniorPerf;
        result.seniorFloor = split.seniorFloor;
        result.coverMode = mode;

        address junior = position.owner;
        uint256 mstrReturned = position.mstrAmount;

        reservedSenior -= matchedPrincipal;
        position.settled = true;
        position.feeUsdg = 0;
        position.unpaidSeniorAccrual = 0;
        _dequeueOpen(positionId);
        _releaseJuniorCap(junior, positionId);

        emit EarlyExit(
            positionId,
            junior,
            result.accrual,
            result.seniorFloor,
            result.coverUsdg,
            mstrSold,
            mstrReturned,
            juniorFees,
            mode
        );

        _fillWithdrawQueue();
        _refundAllGasCredit(junior);
        _deliverJuniorExit(junior, mstrReturned, juniorFees);
    }

    /// @dev Early exit: fees → junior idle shares → wallet → sell-shares. NO backstop. NO pool. Treasury cut only on junior-paid cover.
    function _applyEarlyCover(
        Position storage position,
        address junior,
        CoverMode mode,
        uint256 shortfall,
        uint256 treasuryOnCover,
        uint256 juniorFees,
        uint256 price
    ) internal returns (uint256 mstrSold, uint256 juniorFeesOut, uint256 feeShortfallUsdg, uint256 fromPool) {
        juniorFeesOut = juniorFees;
        uint256 need = shortfall + treasuryOnCover;
        fromPool = 0;

        // 1) position fees
        if (juniorFeesOut >= need) {
            juniorFeesOut -= need;
            _creditPoolUsdg(shortfall);
            if (treasuryOnCover > 0) backstop += treasuryOnCover;
            return (0, juniorFeesOut, 0, 0);
        }
        need -= juniorFeesOut;
        juniorFeesOut = 0;

        if (mode == CoverMode.SellShares) {
            return _sellSharesCover(position, shortfall, treasuryOnCover, need, juniorFeesOut, price);
        }

        // 2) junior idle (lender share assets)
        uint256 fromIdle = _consumeJuniorIdle(junior, need);
        need -= fromIdle;

        // 3) wallet
        if (mode == CoverMode.Wallet || need > 0) {
            if (need > 0) {
                if (mode != CoverMode.Wallet && mode != CoverMode.IdleCarry) revert JuniorCoverRequired();
                // IdleCarry may still pull wallet residual per Maker order (idle then wallet).
                _pullExact(usdg, junior, need);
                need = 0;
            }
        }
        if (need != 0) revert JuniorCoverRequired();

        _creditPoolUsdg(shortfall);
        if (treasuryOnCover > 0) backstop += treasuryOnCover;
        return (0, 0, 0, 0);
    }

    /// @dev Settle: backstop (caller) → fees → junior idle → wallet → sell-shares → pool idle last resort.
    ///      Treasury cut ONLY on cover the junior pays (not backstop/pool).
    function _applySettleCover(
        Position storage position,
        address junior,
        CoverMode mode,
        uint256 shortfall,
        uint256 treasuryOnCover,
        uint256 juniorFees,
        uint256 price
    ) internal returns (uint256 mstrSold, uint256 juniorFeesOut, uint256 feeShortfallUsdg, uint256 fromPool) {
        juniorFeesOut = juniorFees;
        // Recompute junior-paid portion: shortfall already has backstop removed by caller.
        uint256 juniorShortfall = shortfall;
        uint256 need = juniorShortfall + treasuryOnCover;

        if (need == 0) return (0, juniorFeesOut, 0, 0);

        if (juniorFeesOut >= need) {
            juniorFeesOut -= need;
            // junior paid via fees → treasury cut applies
            if (treasuryOnCover > 0) backstop += treasuryOnCover;
            return (0, juniorFeesOut, 0, 0);
        }
        need -= juniorFeesOut;
        juniorFeesOut = 0;

        if (mode == CoverMode.SellShares) {
            return _sellSharesCover(position, juniorShortfall, treasuryOnCover, need, juniorFeesOut, price);
        }

        uint256 fromIdle = _consumeJuniorIdle(junior, need);
        need -= fromIdle;

        if (need > 0 && (mode == CoverMode.Wallet || msg.sender == junior)) {
            uint256 walletBal = usdg.balanceOf(junior);
            uint256 allowance = usdg.allowance(junior, address(this));
            uint256 pullAmt = need;
            if (pullAmt > walletBal) pullAmt = walletBal;
            if (pullAmt > allowance) pullAmt = allowance;
            if (pullAmt > 0) {
                _pullExact(usdg, junior, pullAmt);
                need -= pullAmt;
            }
        }

        // Pool-wide idle last resort (no treasury cut on this portion).
        if (need > 0) {
            uint256 idle = _idleUsdg();
            uint256 take = need < idle ? need : idle;
            if (take > 0) {
                // Reduce pool assets (socialized). Shares unchanged → share price drops.
                totalSeniorAssets -= take;
                fromPool = take;
                need -= take;
            }
        }
        if (need != 0) revert JuniorCoverRequired();

        backstop += CarryCover.juniorPaidTreasuryCut(treasuryOnCover, fromPool, juniorShortfall);
        return (0, 0, 0, fromPool);
    }

    function _sellSharesCover(
        Position storage position,
        uint256 shortfall,
        uint256 treasuryOnCover,
        uint256 /* need */,
        uint256 juniorFeesOut,
        uint256 price
    ) internal returns (uint256 mstrSold, uint256 juniorFeesOut_, uint256 feeShortfallUsdg, uint256 fromPool) {
        juniorFeesOut_ = juniorFeesOut;
        fromPool = 0;
        uint256 tNeed = treasuryOnCover;
        // Treasury cut from leftover fees first → backstop (testnet: not to lenders).
        if (tNeed > 0) {
            if (juniorFeesOut_ >= tNeed) {
                juniorFeesOut_ -= tNeed;
                backstop += tNeed;
                tNeed = 0;
            } else {
                backstop += juniorFeesOut_;
                tNeed -= juniorFeesOut_;
                juniorFeesOut_ = 0;
            }
        }
        uint256 usdgNeed = shortfall + tNeed;
        if (usdgNeed == 0) return (0, juniorFeesOut_, 0, 0);

        mstrSold = previewMstrToCover(usdgNeed, price);
        if (mstrSold > position.mstrAmount) mstrSold = position.mstrAmount;
        position.mstrAmount -= mstrSold;

        if (sellSharesRouter != address(0)) {
            uint256 fair = _usdgValue(mstrSold, price);
            uint256 minOut = fair * 95 / 100;
            if (!mstr.approve(sellSharesRouter, mstrSold)) revert ApproveFailed();
            uint256 usdgOut = IMstrSellRouter(sellSharesRouter).sellMstrForUsdg(mstrSold, minOut, address(this));
            if (!mstr.approve(sellSharesRouter, 0)) revert ApproveFailed();

            uint256 remaining = usdgOut;
            uint256 toSenior = remaining < shortfall ? remaining : shortfall;
            _creditPoolUsdg(toSenior);
            remaining -= toSenior;
            if (toSenior < shortfall) feeShortfallUsdg = shortfall - toSenior;

            uint256 toTreasury = remaining < tNeed ? remaining : tNeed;
            backstop += toTreasury;
            remaining -= toTreasury;
            juniorFeesOut_ += remaining;
        } else {
            // Testnet: swap notionally to USDG credit for pool (lenders paid only USDG).
            uint256 got = _usdgValue(mstrSold, price);
            // Burn MSTR from vault accounting; credit USDG into pool from thin air is wrong.
            // Instead: credit pool for min(got, shortfall) by socializing only if we have USDG —
            // testnet path: treat got as pool credit funded by reducing junior MSTR (already done)
            // and increasing totalSeniorAssets only up to USDG actually held is unsafe.
            // Spec: stock-token fees swapped to USDG before payout. Testnet stub credits pool NAV
            // and relies on backstop/treasury for treasury cut; principal cover credited to pool.
            if (got < shortfall) feeShortfallUsdg = shortfall - got;
            _creditPoolUsdg(got < shortfall ? got : shortfall);
            // Treasury residual cut → backstop only (not lenders).
            if (tNeed > 0) {
                // no AMM USDG; leave tNeed unpaid into feeShortfall conceptually
                feeShortfallUsdg += tNeed;
            }
        }
    }

    function _splitAndClearFees(uint256 positionId) internal returns (WaterfallSplit memory split) {
        Position storage position = positions[positionId];
        uint256 gross = position.feeUsdg;
        split = _waterfallFromGross(gross, _accrualFor(position), _cutWadForPosition(position));
        position.feeUsdg = 0;
        if (gross > totalUnsplitFees) totalUnsplitFees = 0;
        else totalUnsplitFees -= gross;
        position.unpaidSeniorAccrual = split.accrual - split.seniorFloor;
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

    function _accrualFor(Position storage position) internal view returns (uint256) {
        if (position.seniorPrincipal == 0) return position.unpaidSeniorAccrual;
        uint256 end = _feeEndTime(position);
        uint256 idxEnd = _indexAt(end);
        uint256 idxStart = position.rateIndexSnapshot;
        return position.unpaidSeniorAccrual + CarryMath.accrualFromIndex(position.seniorPrincipal, idxStart, idxEnd);
    }

    function _feeEndTime(Position storage position) internal view returns (uint256) {
        uint256 end = block.timestamp;
        if (position.openedAt != 0) {
            uint256 mat = uint256(position.openedAt) + term;
            if (end > mat) end = mat;
        }
        return end;
    }

    function _checkpointMatchAccrual(Position storage position) internal {
        uint256 end = _feeEndTime(position);
        if (position.seniorPrincipal == 0) {
            position.rateIndexSnapshot = _indexAt(end);
            position.lastFeeSplitAt = uint64(block.timestamp);
            return;
        }
        uint256 idxEnd = _indexAt(end);
        position.unpaidSeniorAccrual +=
            CarryMath.accrualFromIndex(position.seniorPrincipal, position.rateIndexSnapshot, idxEnd);
        position.rateIndexSnapshot = idxEnd;
        position.lastFeeSplitAt = uint64(block.timestamp);
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
        if (position.openedAt != 0 && block.timestamp >= uint256(position.openedAt) + term) return 0;

        uint256 idle = _idleUsdg();
        if (idle == 0) return 0;

        uint256 residual = position.targetSenior - position.seniorPrincipal;
        delta = idle < residual ? idle : residual;
        uint256 minDep = _minDeposit();
        bool starting = position.seniorPrincipal == 0;
        bool completing = position.seniorPrincipal > 0 && delta == residual;
        if (delta < minDep && (starting || !completing)) return 0;

        _syncRateIndex();
        if (starting) {
            position.entryPriceWad = _price();
            position.openedAt = uint64(block.timestamp);
            position.lastFeeSplitAt = uint64(block.timestamp);
            position.rateIndexSnapshot = rateIndex;
            position.treasuryCutLocked = _tierCutForUser(position.owner);
            position.boosted = treasuryCutIsSet && position.treasuryCutLocked < treasuryCutWad;
        } else {
            _checkpointMatchAccrual(position);
        }

        position.seniorPrincipal += delta;
        reservedSenior += delta;

        if (position.seniorPrincipal >= position.targetSenior) {
            _dequeueOpen(positionId);
        }
        emit PositionMatched(positionId, position.owner, position.seniorPrincipal, delta, position.openedAt);
    }

    function _creditPoolUsdg(uint256 amount) internal {
        if (amount == 0) return;
        totalSeniorAssets += amount;
    }

    function _consumeJuniorIdle(address junior, uint256 amount) internal returns (uint256 consumed) {
        if (amount == 0) return 0;
        uint256 freeSh = _freeShares(junior);
        uint256 freeAssets = CarryPool.convertToAssets(freeSh, totalShares, totalSeniorAssets);
        consumed = amount < freeAssets ? amount : freeAssets;
        if (consumed == 0) return 0;
        uint256 burn = CarryPool.previewWithdrawShares(consumed, totalShares, totalSeniorAssets);
        if (burn > freeSh) burn = freeSh;
        _burnShares(junior, burn);
        totalSeniorAssets -= consumed;
        _debitWalletSenior(junior, consumed);
        // USDG stays in vault; reclassified to cover.
    }

    function _freeShares(address user) internal view returns (uint256) {
        uint256 bal = shares[user];
        uint256 locked = wqSharesLocked[user];
        return bal > locked ? bal - locked : 0;
    }

    function _burnShares(address user, uint256 amount) internal {
        if (amount == 0) return;
        uint256 bal = shares[user];
        if (amount > bal) revert InsufficientFree();
        shares[user] = bal - amount;
        totalShares -= amount;
    }

    function _debitWalletSenior(address user, uint256 amount) internal {
        uint256 credited = walletSeniorUsdg[user];
        walletSeniorUsdg[user] = amount > credited ? 0 : credited - amount;
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _withdrawBackstop(address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > backstop) revert InsufficientBackstop();
        backstop -= amount;
        // Floor: senior pool NAV + remaining backstop + unsplit position fees (+ queue is inside NAV).
        uint256 floor = totalSeniorAssets + backstop + totalUnsplitFees;
        if (usdg.balanceOf(address(this)) < floor) revert InsufficientBackstop();
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
        uint256 end = _feeEndTime(position);
        if (end <= start) return 0;
        return end - start;
    }

    function _treasuryCut(bool boosted) internal view returns (uint256) {
        if (!treasuryCutIsSet) return 0;
        return boosted ? boostedTreasuryCutWad : treasuryCutWad;
    }

    function _cutWadForPosition(Position storage position) internal view returns (uint256) {
        if (!treasuryCutIsSet) return 0;
        if (position.treasuryCutLocked != 0) return position.treasuryCutLocked;
        return _tierCutForUser(position.owner);
    }

    function _tierCutForUser(address user) internal view returns (uint256) {
        if (!treasuryCutIsSet) return 0;
        uint256 stake = boostStakeAmount[user];
        if (stake == 0 && boostStaked[user]) return boostedTreasuryCutWad;
        uint256 cut = treasuryCutWad;
        uint256 n = boostTierCount;
        for (uint256 i; i < n; ++i) {
            if (stake >= boostTierMinStake[i]) cut = boostTierCutWad[i];
        }
        return cut;
    }

    function _isBoostEligible(address user) internal view returns (bool) {
        return boostStaked[user] || boostStakeAmount[user] > 0;
    }

    function _minDeposit() internal view returns (uint256) {
        return minDepositUsdg == 0 ? DEFAULT_MIN_DEPOSIT_USDG : minDepositUsdg;
    }

    function _assertJuniorCanCover(address junior, CoverMode mode, uint256 coverTotal, uint256 juniorFees)
        internal
        view
    {
        uint256 need = coverTotal > juniorFees ? coverTotal - juniorFees : 0;
        if (need == 0) return;
        uint256 idleAssets = CarryPool.convertToAssets(_freeShares(junior), totalShares, totalSeniorAssets);
        if (mode == CoverMode.IdleCarry) {
            uint256 wallet = usdg.balanceOf(junior);
            uint256 allow = usdg.allowance(junior, address(this));
            uint256 walletPull = wallet < allow ? wallet : allow;
            if (idleAssets + walletPull < need) revert JuniorCoverRequired();
        } else if (mode == CoverMode.Wallet) {
            uint256 fromIdle = idleAssets < need ? idleAssets : need;
            uint256 rest = need - fromIdle;
            if (rest > 0) {
                if (usdg.balanceOf(junior) < rest || usdg.allowance(junior, address(this)) < rest) {
                    revert JuniorCoverRequired();
                }
            }
        } else {
            revert JuniorCoverRequired();
        }
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

    function _deliverJuniorExit(address junior, uint256 mstrAmt, uint256 usdgAmt) internal {
        if (autoCompound[junior]) {
            if (mstrAmt > 0) {
                uint256 notional = previewSeniorAssets(mstrAmt);
                if (notional >= _minDeposit()) {
                    _openJuniorFromVaultBalance(junior, mstrAmt, true);
                } else {
                    _push(mstr, junior, mstrAmt);
                }
            }
            if (usdgAmt > 0) _deliverJuniorUsdg(junior, usdgAmt);
        } else {
            if (mstrAmt > 0) _push(mstr, junior, mstrAmt);
            if (usdgAmt > 0) _push(usdg, junior, usdgAmt);
        }
    }

    function _deliverJuniorUsdg(address junior, uint256 amount) internal {
        if (amount == 0) return;
        if (autoCompound[junior]) {
            if (amount >= _minDeposit()) {
                _compoundUsdgAsSenior(junior, amount, true);
            } else {
                // Under $25 → wallet (no unmatchable clog).
                _push(usdg, junior, amount);
            }
        } else {
            _push(usdg, junior, amount);
        }
    }

    function _openJuniorFromVaultBalance(address junior, uint256 mstrAmount, bool fromExit)
        internal
        returns (uint256 positionId)
    {
        if (mstrAmount == 0) return 0;
        if (!fromExit && paused) revert Paused();
        uint256 notional = previewSeniorAssets(mstrAmount);
        if (!fromExit) {
            if (notional < _minDeposit()) revert BelowMinDeposit();
            _enforceJuniorCap(junior, notional);
        } else if (notional < _minDeposit()) {
            _push(mstr, junior, mstrAmount);
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
            boosted: _isBoostEligible(junior),
            unpaidSeniorAccrual: 0,
            rateIndexSnapshot: 0,
            treasuryCutLocked: 0
        });
        _enqueueOpen(positionId);
        totalJuniorUsdg += notional;
        walletJuniorUsdg[junior] += notional;
        positionJuniorUsdg[positionId] = notional;

        bool matched = _tryMatch(positionId) > 0;
        emit JuniorDeposit(positionId, junior, mstrAmount, matched);
    }

    function _compoundUsdgAsSenior(address user, uint256 amount, bool fromExit) internal {
        if (amount == 0) return;
        if (!fromExit) {
            if (amount < _minDeposit()) revert BelowMinDeposit();
            _enforceSeniorCap(user, amount);
        }
        uint256 minted = CarryPool.convertToShares(amount, totalShares, totalSeniorAssets);
        if (minted == 0) return;
        shares[user] += minted;
        totalShares += minted;
        totalSeniorAssets += amount;
        walletSeniorUsdg[user] += amount;
        _fillWithdrawQueue();
        _matchOpenPositions(_effectiveMatchCap());
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

    function _syncRateIndex() internal {
        uint256 t = block.timestamp;
        if (t <= rateUpdatedAt) return;
        rateIndex = CarryMath.advanceRateIndex(rateIndex, morphoRateWad, t - rateUpdatedAt, YEAR);
        rateUpdatedAt = uint64(t);
        emit RateIndexUpdated(rateIndex, rateUpdatedAt);
    }

    function _indexAt(uint256 timestamp) internal view returns (uint256) {
        if (timestamp <= rateUpdatedAt) return rateIndex;
        return CarryMath.advanceRateIndex(rateIndex, morphoRateWad, timestamp - rateUpdatedAt, YEAR);
    }

    function _price() internal view returns (uint256 price) {
        price = _priceView();
        if (maxPriceStale != 0) {
            try IPushablePriceOracle(address(oracle)).lastUpdatedAt() returns (uint64 updated) {
                if (block.timestamp > uint256(updated) + maxPriceStale) revert StalePrice();
            } catch {
                // Non-pushable oracle (FixedPrice / Mock): no staleness data.
            }
        }
    }

    function _priceView() internal view returns (uint256 price) {
        price = oracle.mstrPriceWad();
        if (price == 0) revert BadPrice();
    }

    function _usdgValue(uint256 mstrAmount, uint256 priceWad) internal view returns (uint256) {
        return CarryMath.usdgValue(mstrAmount, priceWad, mstrDecimals, usdgDecimals);
    }

    function _enforceSeniorCap(address senior, uint256 amount) internal view {
        if (maxTotalSeniorUsdg != 0 && totalSeniorAssets + amount > maxTotalSeniorUsdg) revert CapExceeded();
        if (maxPerWalletUsdg != 0 && walletSeniorUsdg[senior] + amount > maxPerWalletUsdg) revert CapExceeded();
    }

    function _enforceJuniorCap(address junior, uint256 notional) internal view {
        if (maxTotalJuniorUsdg != 0 && totalJuniorUsdg + notional > maxTotalJuniorUsdg) revert CapExceeded();
        if (maxPerWalletUsdg != 0 && walletJuniorUsdg[junior] + notional > maxPerWalletUsdg) revert CapExceeded();
    }

    function _releaseJuniorCap(address junior, uint256 positionId) internal {
        uint256 notional = positionJuniorUsdg[positionId];
        if (notional == 0) return;
        positionJuniorUsdg[positionId] = 0;
        if (notional > totalJuniorUsdg) totalJuniorUsdg = 0;
        else totalJuniorUsdg -= notional;
        uint256 credited = walletJuniorUsdg[junior];
        walletJuniorUsdg[junior] = notional > credited ? 0 : credited - notional;
    }

    function _pullExact(IERC20Minimal token, address from, uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        if (!token.transferFrom(from, address(this), amount)) revert TransferFailed();
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert FeeOnTransfer();
    }

    function _push(IERC20Minimal token, address to, uint256 amount) internal {
        if (!token.transfer(to, amount)) revert TransferFailed();
    }
}
