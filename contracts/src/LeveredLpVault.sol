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
import {CarryMath} from "./libraries/CarryMath.sol";

/// @title LeveredLpVault
/// @notice UUPS-upgradeable 2× junior MSTR / senior USDG book (Maker fee waterfall).
///
/// Product CA = PROXY address. Future logic upgrades keep the same proxy.
/// Owner-only `_authorizeUpgrade`. Deploys paused.
///
/// 1. Junior deposits MSTR → Idle or Active (partial match OK).
/// 2. Senior deposits → FIFO match (bounded by matchCap per tx); residual Idle; auto-match later.
///    Junior may prefund `gasCreditWei` so `depositSenior` can refund ETH gas to the senior
///    (even when the deposit leaves the junior unmatched). Unused credit auto-refunds on
///    withdraw Idle / settle / early exit (position close).
/// 3. Fees accrue raw on fee-in. Waterfall ONLY at claimFees / earlyExit / settle:
///    seniorFloor → treasury (base 20% of gross; Boosted MSTR uses reduced cut, default 10%)
///    → seniorPerf (20% gross) → junior.
///    accrual = seniorPrincipal × morphoRate × elapsed / 365.
/// 4. Shortfall cover:
///    - settle (maturity): backstop FIRST, then junior chooses Wallet / IdleCarry / SellShares;
///    - earlyExit: junior ONLY (Wallet / IdleCarry / SellShares). NO backstop.
///      If junior cannot cover with USDG/fees and does not choose SellShares → REVERT, position stays open.
///    Treasury-on-cover uses the same base/Boosted cut as the waterfall.
/// 5. SellShares: testnet (router=0) credits extra MSTR to seniors. Mainnet sets `sellSharesRouter`
///    (Uniswap AMM stub/interface) — swap MSTR→USDG, cover seniors/treasury, remainder to junior.
/// 6. Senior USDG/MSTR credits are time-weighted by deposit time (late seniors do not take a full
///    share of pre-arrival accrual). Legacy equal `accYieldPerPrincipal` still settles old debt.
/// 7. Boosted (MSTR market only for now): stake STRATEGY before open via owner `setBoostStaked`
///    stub (live STRATEGY token wire later). Activates reduced treasury cut. Creator fee later.
/// 8. `autoCompound`: on junior exit / senior withdraw, capital+fees can reopen as Idle
///    (MSTR→new junior Idle; USDG→senior idle waiting match) instead of wallet payout.
contract LeveredLpVault is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    uint256 public constant WAD = 1e18;
    uint256 public constant YEAR = 365 days;
    /// @notice Owner-settable Morpho rate cap (docs: fixed ≤5%). Positions lock rate at first match.
    uint256 public constant MAX_MORPHO_RATE_WAD = 0.05e18;
    uint256 public constant MAX_TREASURY_CUT_WAD = 0.2e18;
    uint256 public constant SENIOR_PERF_CUT_WAD = 0.2e18;
    uint256 public constant DEFAULT_TREASURY_CUT_WAD = 0.2e18;
    /// @notice Default Boosted MSTR treasury cut of gross / cover (10%). Creator fee share is separate/later.
    uint256 public constant BOOSTED_TREASURY_CUT_WAD = 0.1e18;
    /// @notice Default max open-queue match attempts per depositSenior when matchCap is 0.
    uint256 public constant DEFAULT_MATCH_CAP = 25;
    /// @notice Default ETH refund per depositSenior when junior gas credit exists (testnet-scale).
    uint256 public constant DEFAULT_GAS_REFUND_WEI = 0.0001 ether;
    uint64 public constant MAX_TERM = 7 days;

    address public constant ROBINHOOD_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

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
        /// @notice Unpaid senior Morpho accrual when a claim/split paid less than accrual (carries forward).
        uint256 unpaidSeniorAccrual;
        /// @notice Morpho rate WAD locked at first match; 0 = legacy / use live morphoRateWad.
        uint256 morphoRateLocked;
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
    uint256 public totalSeniorPrincipal;
    uint256 public reservedSenior;
    uint256 public nextPositionId;
    uint256 public accYieldPerPrincipal;
    uint256 public accMstrPerPrincipal;

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
    mapping(address => uint256) public seniorPrincipal;
    mapping(address => uint256) public seniorClaimableYield;
    mapping(address => uint256) public seniorClaimableMstr;
    mapping(address => uint256) public seniorYieldDebt;
    mapping(address => uint256) public seniorMstrDebt;

    /// @dev Time-weighted USDG yield: claimable += p*accYieldWeightT/WAD - p*joinedAt*accYieldWeight/WAD - debt.
    uint256 public accYieldWeightT;
    uint256 public accYieldWeight;
    /// @dev Time-weighted MSTR credits (SellShares cover), same weight basis as USDG yield.
    uint256 public accMstrWeightT;
    uint256 public accMstrWeight;
    /// @dev Σ principal_i × joinedAt_i for weight denominator P*T − sumPJ.
    uint256 public sumPrincipalJoinedAt;
    /// @notice Max open-queue match attempts per depositSenior; 0 → DEFAULT_MATCH_CAP.
    uint256 public matchCap;
    mapping(address => uint256) public seniorJoinedAt;
    /// @dev Legacy equal-share debt still used alongside time-weighted indices after upgrade.
    mapping(address => uint256) public seniorTwYieldDebt;
    mapping(address => uint256) public seniorTwMstrDebt;

    /// @notice ETH wei paid to senior on each `depositSenior` when an open-queue junior has credit.
    ///         0 disables refunds. Owner-settable; new inits default to `DEFAULT_GAS_REFUND_WEI`.
    uint256 public gasRefundWei;
    /// @notice Junior-funded ETH escrow drawn by `depositSenior` gas refunds (on-chain only).
    mapping(address => uint256) public gasCreditWei;

    /// @notice Mainnet SellShares AMM router. `address(0)` = testnet MSTR→senior credit path.
    address public sellSharesRouter;
    /// @notice When true, exit/withdraw compounds capital+fees into new Idle (not wallet).
    mapping(address => bool) public autoCompound;

    uint256[27] private __gap;

    error Paused();
    error ZeroAmount();
    error ZeroAddress();
    error BadTerm();
    error BadApr();
    error BadCut();
    error BadPrice();
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

    event PausedDeposits(bool paused);
    event SeniorDeposit(address indexed senior, uint256 amount);
    event SeniorWithdraw(address indexed senior, uint256 principal, uint256 yieldUsdg, uint256 mstrAmount);
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
    event TreasuryCutUpdated(uint256 treasuryCutWad, uint256 boostedTreasuryCutWad);
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
        // Boosted MSTR (STRATEGY stake): reduced treasury cut (default 10%). Base stays 20%.
        boostedTreasuryCutWad = BOOSTED_TREASURY_CUT_WAD;
        gasRefundWei = DEFAULT_GAS_REFUND_WEI;
        mstrDecimals = mstr.decimals();
        usdgDecimals = usdg.decimals();
        nextPositionId = 1;
        paused = true;
        emit PausedDeposits(true);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

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
        morphoRateWad = morphoRateWad_;
        emit MorphoRateUpdated(morphoRateWad_);
    }

    function morphoFloorAprWad() external view returns (uint256) {
        return morphoRateWad;
    }

    /// @notice Set base and Boosted treasury cuts of gross / junior-cover residual.
    ///         Base default 20%. Boosted MSTR (STRATEGY stake) default 10%. Creator fee is NOT this cut.
    function setTreasuryCuts(uint256 treasuryCutWad_, uint256 boostedTreasuryCutWad_) external onlyOwner {
        if (treasuryCutWad_ > MAX_TREASURY_CUT_WAD || boostedTreasuryCutWad_ > MAX_TREASURY_CUT_WAD) {
            revert BadCut();
        }
        treasuryCutWad = treasuryCutWad_;
        boostedTreasuryCutWad = boostedTreasuryCutWad_;
        emit TreasuryCutUpdated(treasuryCutWad_, boostedTreasuryCutWad_);
    }

    /// @notice Mainnet Uniswap (or equiv) SellShares router. Zero keeps testnet MSTR→senior credit.
    function setSellSharesRouter(address router) external onlyOwner {
        sellSharesRouter = router;
        emit SellSharesRouterUpdated(router);
    }

    /// @notice Opt in/out of compounding capital+fees into new Idle on exit/withdraw.
    function setAutoCompound(bool enabled) external {
        autoCompound[msg.sender] = enabled;
        emit AutoCompoundUpdated(msg.sender, enabled);
    }

    /// @notice ETH wei refunded to senior on each `depositSenior` when open-queue junior has credit.
    function setGasRefundWei(uint256 gasRefundWei_) external onlyOwner {
        gasRefundWei = gasRefundWei_;
        emit GasRefundWeiUpdated(gasRefundWei_);
    }

    /// @notice Junior prefunds ETH escrow so seniors can be refunded gas on `depositSenior`.
    ///         UX: call before/while Idle so lenders are not stuck paying match-queue gas alone.
    function fundGasCredit() external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        gasCreditWei[msg.sender] += msg.value;
        emit GasCreditFunded(msg.sender, msg.value, gasCreditWei[msg.sender]);
    }

    /// @notice Junior withdraws unused ETH gas credit.
    function withdrawGasCredit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = gasCreditWei[msg.sender];
        if (amount > bal) revert InsufficientGasCredit();
        gasCreditWei[msg.sender] = bal - amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert GasTransferFailed();
        emit GasCreditWithdrawn(msg.sender, amount, gasCreditWei[msg.sender]);
    }

    /// @notice STRATEGY stake-before-open stub (MSTR market). Owner marks staked; live token wire later.
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

    /// @notice Owner withdraw from backstop surplus only. Cannot pull reserved senior USDG or MSTR.
    function withdrawFromBackstop(address to, uint256 amount) external onlyOwner nonReentrant {
        _withdrawBackstop(to, amount);
        emit BackstopWithdrawn(to, amount);
    }

    /// @notice Alias for treasury fee withdraw (treasury cuts accrue in `backstop`).
    function withdrawTreasuryFees(address to, uint256 amount) external onlyOwner nonReentrant {
        _withdrawBackstop(to, amount);
        emit TreasuryFeesWithdrawn(to, amount);
    }

    function setMatchCap(uint256 matchCap_) external onlyOwner {
        // 0 restores DEFAULT_MATCH_CAP at match time; cap itself may be set explicitly.
        matchCap = matchCap_;
        emit MatchCapUpdated(matchCap_);
    }

    function depositSenior(uint256 amount) external nonReentrant {
        if (paused) revert Paused();
        if (amount == 0) revert ZeroAmount();
        // Capture open-queue sponsor BEFORE match so a full match still refunds that junior's credit
        // (Maker: junior fronts gas even when this deposit leaves them unmatched, and also when it matches).
        address gasSponsor = _gasSponsor();
        _enforceSeniorCap(msg.sender, amount);
        _checkpoint(msg.sender);
        _addSeniorPrincipal(msg.sender, amount);
        walletSeniorUsdg[msg.sender] += amount;
        _syncDebt(msg.sender);
        _pullExact(usdg, msg.sender, amount);
        _matchOpenPositions(_effectiveMatchCap());
        _payGasRefund(msg.sender, gasSponsor);
        emit SeniorDeposit(msg.sender, amount);
    }

    function withdrawSenior(uint256 principalAmount) external nonReentrant {
        _checkpoint(msg.sender);
        uint256 free = freePrincipal(msg.sender);
        if (principalAmount > free) revert InsufficientFree();
        if (principalAmount > 0) {
            _removeSeniorPrincipal(msg.sender, principalAmount);
            uint256 credited = walletSeniorUsdg[msg.sender];
            walletSeniorUsdg[msg.sender] = principalAmount > credited ? 0 : credited - principalAmount;
        }
        _syncDebt(msg.sender);

        uint256 yieldUsdg = seniorClaimableYield[msg.sender];
        uint256 mstrOut = seniorClaimableMstr[msg.sender];
        seniorClaimableYield[msg.sender] = 0;
        seniorClaimableMstr[msg.sender] = 0;

        emit SeniorWithdraw(msg.sender, principalAmount, yieldUsdg, mstrOut);

        if (autoCompound[msg.sender]) {
            // Compound: USDG capital+fees → senior Idle waiting match; MSTR → new junior Idle.
            uint256 usdgCompound = principalAmount + yieldUsdg;
            if (usdgCompound > 0) _compoundUsdgAsSeniorIdle(msg.sender, usdgCompound);
            if (mstrOut > 0) _openJuniorFromVaultBalance(msg.sender, mstrOut);
        } else {
            if (principalAmount + yieldUsdg > 0) _push(usdg, msg.sender, principalAmount + yieldUsdg);
            if (mstrOut > 0) _push(mstr, msg.sender, mstrOut);
        }
    }

    function depositJunior(uint256 mstrAmount) external nonReentrant returns (uint256 positionId) {
        if (paused) revert Paused();
        if (mstrAmount == 0) revert ZeroAmount();
        _pullExact(mstr, msg.sender, mstrAmount);
        positionId = _openJuniorFromVaultBalance(msg.sender, mstrAmount);
    }

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
        if (autoCompound[msg.sender] && amount > 0) {
            _openJuniorFromVaultBalance(msg.sender, amount);
        } else {
            _push(mstr, msg.sender, amount);
        }
    }

    /// @notice Accrue raw LP fees — no cut on fee-in.
    function accrueLpFee(uint256 positionId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage position = positions[positionId];
        if (position.owner == address(0) || position.settled) revert BadPosition();
        if (position.seniorPrincipal == 0) revert NotMatched();

        _pullExact(usdg, msg.sender, amount);
        position.feeUsdg += amount;
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

        emit FeesClaimed(
            positionId, msg.sender, result.gross, split.seniorFloor, split.treasury, split.seniorPerf, split.junior
        );
        if (split.junior > 0) _push(usdg, msg.sender, split.junior);
    }

    function previewClaimFees(uint256 positionId) public view returns (ClaimFeesResult memory result) {
        Position storage position = positions[positionId];
        if (position.owner == address(0) || position.settled) revert BadPosition();
        if (position.seniorPrincipal == 0) revert NotMatched();
        if (block.timestamp >= uint256(position.openedAt) + term) revert TermElapsed();

        uint256 gross = position.feeUsdg;
        if (gross == 0) revert ZeroGross();
        result.elapsed = _elapsedSinceSplit(position);
        WaterfallSplit memory split = _waterfallFromGross(gross, _accrualFor(position), position.boosted);
        result.accrual = split.accrual;
        result.seniorFloor = split.seniorFloor;
        result.treasury = split.treasury;
        result.seniorPerf = split.seniorPerf;
        result.toJunior = split.junior;
        result.gross = gross;
    }

    /// @notice Maturity settle. Default residual cover after backstop = SellShares (permissionless).
    function settle(uint256 positionId) external nonReentrant returns (Settlement memory) {
        return _settle(positionId, CoverMode.SellShares);
    }

    /// @notice Maturity settle with explicit junior cover mode for residual shortfall after backstop.
    ///         Wallet / IdleCarry require msg.sender == junior; SellShares may be called by anyone.
    function settle(uint256 positionId, CoverMode mode) external nonReentrant returns (Settlement memory) {
        return _settle(positionId, mode);
    }

    function previewSettle(uint256 positionId) external view returns (Settlement memory) {
        return previewSettle(positionId, CoverMode.SellShares);
    }

    function previewSettle(uint256 positionId, CoverMode mode) public view returns (Settlement memory result) {
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert BadPosition();
        if (position.settled) revert AlreadySettled();
        if (position.seniorPrincipal == 0) revert NotMatched();
        if (block.timestamp < uint256(position.openedAt) + term) revert TermNotElapsed();

        uint256 gross = position.feeUsdg;
        WaterfallSplit memory split = _waterfallFromGross(gross, _accrualFor(position), position.boosted);
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

        uint256 cut = _treasuryCut(position.boosted);
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

    /// @notice Early exit before term. Shortfall cover is junior-only (NO backstop).
    ///         Wallet/Idle without enough cover REVERTS (position stays open); use SellShares to force close.
    function earlyExit(uint256 positionId) external nonReentrant returns (EarlyExitResult memory) {
        return _earlyExit(positionId, CoverMode.SellShares);
    }

    /// @notice Early exit with cover mode: Wallet / IdleCarry / SellShares. NO backstop draw.
    function earlyExit(uint256 positionId, CoverMode mode) external nonReentrant returns (EarlyExitResult memory) {
        return _earlyExit(positionId, mode);
    }

    function previewEarlyExit(uint256 positionId) public view returns (EarlyExitResult memory) {
        return previewEarlyExit(positionId, CoverMode.SellShares);
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
            _waterfallFromGross(position.feeUsdg, _accrualFor(position), position.boosted);
        result.accrual = split.accrual;
        result.seniorFloor = split.seniorFloor;
        result.treasury = split.treasury;
        result.seniorPerf = split.seniorPerf;
        result.juniorLeftoverFees = split.junior;

        // Early exit: junior covers full accrual shortfall. NO backstop.
        uint256 shortfall = split.accrual > split.seniorFloor ? split.accrual - split.seniorFloor : 0;
        uint256 cut = _treasuryCut(position.boosted);
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
        return _waterfallFromGross(gross, previewSeniorAccrual(seniorPrincipal_, elapsed), boosted);
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
        return totalSeniorPrincipal - reservedSenior;
    }

    function freePrincipal(address senior) public view returns (uint256) {
        if (totalSeniorPrincipal == 0) return 0;
        return seniorPrincipal[senior] * freeSenior() / totalSeniorPrincipal;
    }

    function previewSeniorAssets(uint256 mstrAmount) public view returns (uint256) {
        return previewSeniorAssets(mstrAmount, _price());
    }

    function previewSeniorAssets(uint256 mstrAmount, uint256 priceWad) public view returns (uint256) {
        if (priceWad == 0) revert BadPrice();
        return CarryMath.seniorAssets(mstrAmount, priceWad, mstrDecimals, usdgDecimals);
    }

    function previewMstrToCover(uint256 usdgShort) public view returns (uint256) {
        return previewMstrToCover(usdgShort, _price());
    }

    function previewMstrToCover(uint256 usdgShort, uint256 priceWad) public view returns (uint256) {
        if (priceWad == 0) revert BadPrice();
        return CarryMath.mstrToCover(usdgShort, priceWad, mstrDecimals, usdgDecimals);
    }


    // ─── internal ────────────────────────────────────────────────────────────

    function _settle(uint256 positionId, CoverMode mode) internal returns (Settlement memory result) {
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert BadPosition();
        if (position.settled) revert AlreadySettled();
        if (position.seniorPrincipal == 0) revert NotMatched();
        if (block.timestamp < uint256(position.openedAt) + term) revert TermNotElapsed();

        address junior = position.owner;
        if (mode != CoverMode.SellShares && msg.sender != junior) revert NotJunior();

        uint256 gross = position.feeUsdg;
        WaterfallSplit memory split = _waterfallFromGross(gross, _accrualFor(position), position.boosted);

        result.accrual = split.accrual;
        result.seniorFloor = split.seniorFloor;
        result.treasury = split.treasury;
        result.seniorPerf = split.seniorPerf;
        result.juniorYield = split.junior;
        result.coverMode = mode;

        // Settle shortfall: backstop FIRST, then junior Wallet / IdleCarry / SellShares + treasury-on-cover.
        uint256 shortfall = split.accrual > split.seniorFloor ? split.accrual - split.seniorFloor : 0;
        uint256 fromBs = backstop < shortfall ? backstop : shortfall;
        result.fromBackstop = fromBs;
        shortfall -= fromBs;

        uint256 treasuryOnCover = shortfall * _treasuryCut(position.boosted) / WAD;
        uint256 coverTotal = shortfall + treasuryOnCover;
        result.treasuryOnCover = treasuryOnCover;
        result.coverUsdg = coverTotal;

        uint256 matchedPrincipal = position.seniorPrincipal;
        uint256 juniorFees = split.junior;
        uint256 mstrSold;
        uint256 feeShort;

        if (coverTotal > 0) {
            // Credits residual shortfall to seniors (USDG or MSTR) inside cover helper — do not re-credit.
            (mstrSold, juniorFees, feeShort) =
                _applyJuniorCover(position, junior, mode, shortfall, treasuryOnCover, juniorFees, _price());
        }

        result.mstrSold = mstrSold;
        result.feeShortfallUsdg = feeShort;
        result.mstrKept = position.mstrAmount; // already reduced by SellShares cover
        result.juniorYield = juniorFees;

        position.settled = true;
        position.feeUsdg = 0;
        position.unpaidSeniorAccrual = 0;
        backstop = backstop - fromBs + split.treasury;
        reservedSenior -= matchedPrincipal;
        _dequeueOpen(positionId);
        _releaseJuniorCap(junior, positionId);

        // Waterfall senior slice + backstop top-up only (junior cover credits separately).
        _creditSeniorYield(split.seniorTotal + fromBs);

        emit WaterfallApplied(
            positionId, gross, split.accrual, split.seniorFloor, split.treasury, split.seniorPerf, split.junior
        );
        emit Settled(positionId, junior, result.mstrKept, result.mstrSold, split.treasury, result.juniorYield);

        _refundAllGasCredit(junior);
        _deliverJuniorExit(junior, result.mstrKept, juniorFees);
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

        // Pre-check: Wallet/Idle without enough USDG/fees REVERTS — position stays open (Maker).
        // SellShares may proceed (testnet MSTR credit / mainnet AMM).
        uint256 shortfallPreview =
            result.accrual > result.seniorFloor ? result.accrual - result.seniorFloor : 0;
        uint256 coverPreview = shortfallPreview + result.treasuryOnCover;
        if (coverPreview > 0 && mode != CoverMode.SellShares) {
            _assertJuniorCanCover(msg.sender, mode, coverPreview, result.juniorLeftoverFees);
        }

        // Waterfall on fees credits seniorTotal (USDG) + treasury; returns junior share.
        WaterfallSplit memory split = _splitAndClearFees(positionId);

        // Junior-only shortfall cover (Maker): NO backstop draw on early exit.
        uint256 shortfall = result.accrual > split.seniorFloor ? result.accrual - split.seniorFloor : 0;
        uint256 treasuryOnCover = shortfall * _treasuryCut(position.boosted) / WAD;
        uint256 coverTotal = shortfall + treasuryOnCover;

        uint256 mstrSold;
        uint256 juniorFees = split.junior;
        uint256 feeShort;

        if (coverTotal > 0) {
            (mstrSold, juniorFees, feeShort) =
                _applyJuniorCover(position, msg.sender, mode, shortfall, treasuryOnCover, juniorFees, price);
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

        position.settled = true;
        position.feeUsdg = 0;
        position.unpaidSeniorAccrual = 0;
        reservedSenior -= matchedPrincipal;
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

        _refundAllGasCredit(junior);
        _deliverJuniorExit(junior, mstrReturned, juniorFees);
    }

    /// @dev Junior covers residual shortfall after backstop (settle) or full shortfall (early exit).
    ///      Credits seniors for `shortfall` USDG (or MSTR notional); treasury-on-cover → backstop.
    ///      Fees apply to cover first. Wallet/Idle pull/burn the remainder.
    ///      SellShares: router set → AMM USDG path; else testnet MSTR→senior credit.
    function _applyJuniorCover(
        Position storage position,
        address junior,
        CoverMode mode,
        uint256 shortfall,
        uint256 treasuryOnCover,
        uint256 juniorFees,
        uint256 price
    ) internal returns (uint256 mstrSold, uint256 juniorFeesOut, uint256 feeShortfallUsdg) {
        juniorFeesOut = juniorFees;
        uint256 coverTotal = shortfall + treasuryOnCover;

        if (mode == CoverMode.Wallet) {
            uint256 need = coverTotal;
            if (juniorFeesOut >= need) {
                juniorFeesOut -= need;
                need = 0;
            } else {
                need -= juniorFeesOut;
                juniorFeesOut = 0;
            }
            if (need > 0) _pullExact(usdg, junior, need);
            _creditSeniorYield(shortfall);
            backstop += treasuryOnCover;
        } else if (mode == CoverMode.IdleCarry) {
            uint256 need = coverTotal;
            if (juniorFeesOut >= need) {
                juniorFeesOut -= need;
                need = 0;
            } else {
                need -= juniorFeesOut;
                juniorFeesOut = 0;
            }
            _creditSeniorYield(shortfall);
            if (need > 0) _consumeIdleCover(junior, need);
            backstop += treasuryOnCover;
        } else {
            // SellShares: treasury-on-cover from junior leftover fees first.
            uint256 tNeed = treasuryOnCover;
            if (tNeed > 0) {
                if (juniorFeesOut >= tNeed) {
                    juniorFeesOut -= tNeed;
                    backstop += tNeed;
                    tNeed = 0;
                } else {
                    backstop += juniorFeesOut;
                    tNeed -= juniorFeesOut;
                    juniorFeesOut = 0;
                }
            }
            uint256 usdgNeed = shortfall + tNeed;
            if (usdgNeed > 0) {
                mstrSold = previewMstrToCover(usdgNeed, price);
                if (mstrSold > position.mstrAmount) {
                    mstrSold = position.mstrAmount;
                }
                position.mstrAmount -= mstrSold;

                if (sellSharesRouter != address(0)) {
                    // Mainnet path: Uniswap (or equiv) AMM → USDG to vault → cover → remainder to junior.
                    uint256 fair = _usdgValue(mstrSold, price);
                    uint256 minOut = fair * 95 / 100;
                    if (!mstr.approve(sellSharesRouter, mstrSold)) revert ApproveFailed();
                    uint256 usdgOut =
                        IMstrSellRouter(sellSharesRouter).sellMstrForUsdg(mstrSold, minOut, address(this));
                    if (!mstr.approve(sellSharesRouter, 0)) revert ApproveFailed();

                    uint256 remaining = usdgOut;
                    uint256 toSenior = remaining < shortfall ? remaining : shortfall;
                    _creditSeniorYield(toSenior);
                    remaining -= toSenior;
                    if (toSenior < shortfall) feeShortfallUsdg = shortfall - toSenior;

                    uint256 toTreasury = remaining < tNeed ? remaining : tNeed;
                    backstop += toTreasury;
                    remaining -= toTreasury;
                    juniorFeesOut += remaining;
                } else {
                    // Testnet: credit MSTR to seniors (no AMM).
                    uint256 got = _usdgValue(mstrSold, price);
                    if (got < shortfall) feeShortfallUsdg = shortfall - got;
                    _creditSeniorMstr(mstrSold);
                }
            }
        }
    }

    /// @dev Split position fees via Maker waterfall; credit seniors + treasury; clear feeUsdg.
    ///      Unpaid accrual (accrual − seniorFloor) is stored on the position for the next claim/exit/settle.
    function _splitAndClearFees(uint256 positionId) internal returns (WaterfallSplit memory split) {
        Position storage position = positions[positionId];
        uint256 gross = position.feeUsdg;
        split = _waterfallFromGross(gross, _accrualFor(position), position.boosted);
        position.feeUsdg = 0;
        position.unpaidSeniorAccrual = split.accrual - split.seniorFloor;
        backstop += split.treasury;
        _creditSeniorYield(split.seniorTotal);
        emit WaterfallApplied(
            positionId, gross, split.accrual, split.seniorFloor, split.treasury, split.seniorPerf, split.junior
        );
    }

    function _waterfallFromGross(uint256 gross, uint256 accrual, bool boosted)
        internal
        view
        returns (WaterfallSplit memory s)
    {
        CarryMath.WaterfallSplit memory w =
            CarryMath.waterfallFromGross(gross, accrual, _treasuryCut(boosted), SENIOR_PERF_CUT_WAD);
        s.accrual = w.accrual;
        s.seniorFloor = w.seniorFloor;
        s.treasury = w.treasury;
        s.seniorPerf = w.seniorPerf;
        s.junior = w.junior;
        s.seniorTotal = w.seniorTotal;
    }

    function _rateFor(Position storage position) internal view returns (uint256) {
        return position.morphoRateLocked != 0 ? position.morphoRateLocked : morphoRateWad;
    }

    /// @dev unpaid gap + principal × locked rate × elapsed since last split.
    function _accrualFor(Position storage position) internal view returns (uint256) {
        uint256 elapsed = _elapsedSinceSplit(position);
        return position.unpaidSeniorAccrual
            + CarryMath.morphoAccrual(position.seniorPrincipal, _rateFor(position), elapsed, YEAR);
    }

    /// @dev On incremental match, bank accrual for currently matched principal so new capital is not backdated.
    function _checkpointMatchAccrual(Position storage position) internal {
        uint256 elapsed = _elapsedSinceSplit(position);
        if (elapsed == 0 || position.seniorPrincipal == 0) return;
        position.unpaidSeniorAccrual +=
            CarryMath.morphoAccrual(position.seniorPrincipal, _rateFor(position), elapsed, YEAR);
        position.lastFeeSplitAt = uint64(block.timestamp);
    }

    /// @dev Burn caller's senior principal against global idle USDG to fund early-exit cover.
    ///      Cap = min(caller principal, freeSenior) so the junior who posted idle can spend it
    ///      without pro-rata freePrincipal dilution blocking the Maker cover path.
    function _consumeIdleCover(address junior, uint256 amount) internal {
        _checkpoint(junior);
        uint256 maxCover = seniorPrincipal[junior] < freeSenior() ? seniorPrincipal[junior] : freeSenior();
        if (amount > maxCover) revert InsufficientIdleCover();
        _removeSeniorPrincipal(junior, amount);
        uint256 credited = walletSeniorUsdg[junior];
        walletSeniorUsdg[junior] = amount > credited ? 0 : credited - amount;
        _syncDebt(junior);
        // USDG stays in vault; reclassify from senior idle → fee cover / treasury.
    }

    function _effectiveMatchCap() internal view returns (uint256) {
        return matchCap == 0 ? DEFAULT_MATCH_CAP : matchCap;
    }

    function _matchOpenPositions(uint256 maxIters) internal {
        uint256 id = openHead;
        uint256 iters;
        while (id != 0 && iters < maxIters) {
            uint256 next = openNext[id];
            _tryMatch(id);
            id = next;
            unchecked {
                ++iters;
            }
            // Stop only when no free senior left (partial may leave head in queue).
            if (freeSenior() == 0) break;
        }
    }

    function _withdrawBackstop(address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > backstop) revert InsufficientBackstop();
        backstop -= amount;
        // Keep senior principal USDG intact; MSTR untouched. Position fees remain in balance above this floor.
        if (usdg.balanceOf(address(this)) < totalSeniorPrincipal + backstop) revert InsufficientBackstop();
        _push(usdg, to, amount);
    }

    function _addSeniorPrincipal(address senior, uint256 amount) internal {
        uint256 oldP = seniorPrincipal[senior];
        uint256 oldJ = seniorJoinedAt[senior];
        if (oldP > 0) {
            sumPrincipalJoinedAt -= oldP * oldJ;
        }
        uint256 newP = oldP + amount;
        uint256 newJ = oldP == 0 ? block.timestamp : (oldP * oldJ + amount * block.timestamp) / newP;
        seniorPrincipal[senior] = newP;
        seniorJoinedAt[senior] = newJ;
        totalSeniorPrincipal += amount;
        sumPrincipalJoinedAt += newP * newJ;
    }

    function _removeSeniorPrincipal(address senior, uint256 amount) internal {
        uint256 oldP = seniorPrincipal[senior];
        uint256 oldJ = seniorJoinedAt[senior];
        sumPrincipalJoinedAt -= oldP * oldJ;
        uint256 newP = oldP - amount;
        seniorPrincipal[senior] = newP;
        totalSeniorPrincipal -= amount;
        if (newP == 0) {
            seniorJoinedAt[senior] = 0;
        } else {
            // Keep joinedAt; re-add weight for remaining principal.
            sumPrincipalJoinedAt += newP * oldJ;
        }
    }

    /// @dev Time-weighted USDG credit: share_i ∝ principal_i × (T − joinedAt_i).
    ///      Uses dual index (T-weighted + joinedAt-weighted) so late depositors do not take full
    ///      pre-arrival accrual. Falls back to equal-share legacy index if weights are zero.
    ///      `accT` is derived as `inv * T` (not a separate div) so Σ user shares cannot exceed `amount`.
    function _creditSeniorYield(uint256 amount) internal {
        if (amount == 0 || totalSeniorPrincipal == 0) return;
        uint256 t = block.timestamp;
        uint256 totalW = totalSeniorPrincipal * t - sumPrincipalJoinedAt;
        if (totalW == 0) {
            accYieldPerPrincipal += amount * WAD / totalSeniorPrincipal;
            return;
        }
        uint256 inv = amount * WAD / totalW;
        accYieldWeight += inv;
        accYieldWeightT += inv * t;
    }

    function _creditSeniorMstr(uint256 amount) internal {
        if (amount == 0 || totalSeniorPrincipal == 0) return;
        uint256 t = block.timestamp;
        uint256 totalW = totalSeniorPrincipal * t - sumPrincipalJoinedAt;
        if (totalW == 0) {
            accMstrPerPrincipal += amount * WAD / totalSeniorPrincipal;
            return;
        }
        uint256 inv = amount * WAD / totalW;
        accMstrWeight += inv;
        accMstrWeightT += inv * t;
    }

    function _twYieldRaw(address senior) internal view returns (uint256) {
        uint256 p = seniorPrincipal[senior];
        if (p == 0) return 0;
        uint256 j = seniorJoinedAt[senior];
        uint256 rawT = p * accYieldWeightT / WAD;
        uint256 rawJ = p * j * accYieldWeight / WAD;
        return rawT > rawJ ? rawT - rawJ : 0;
    }

    function _twMstrRaw(address senior) internal view returns (uint256) {
        uint256 p = seniorPrincipal[senior];
        if (p == 0) return 0;
        uint256 j = seniorJoinedAt[senior];
        uint256 rawT = p * accMstrWeightT / WAD;
        uint256 rawJ = p * j * accMstrWeight / WAD;
        return rawT > rawJ ? rawT - rawJ : 0;
    }

    /// @dev Match min(freeSenior, residual). Keeps position in open queue if still short.
    ///      Does not match after term once the clock has started (openedAt set).
    function _tryMatch(uint256 positionId) internal returns (bool matched) {
        Position storage position = positions[positionId];
        if (position.owner == address(0) || position.settled) return false;
        if (position.seniorPrincipal >= position.targetSenior) return false;
        if (position.openedAt != 0 && block.timestamp >= uint256(position.openedAt) + term) return false;

        uint256 free = freeSenior();
        if (free == 0) return false;

        uint256 residual = position.targetSenior - position.seniorPrincipal;
        uint256 delta = free < residual ? free : residual;
        if (delta == 0) return false;

        uint256 price = _price();
        if (position.seniorPrincipal == 0) {
            position.entryPriceWad = price;
            position.openedAt = uint64(block.timestamp);
            position.lastFeeSplitAt = uint64(block.timestamp);
            position.morphoRateLocked = morphoRateWad;
        } else {
            _checkpointMatchAccrual(position);
        }

        position.seniorPrincipal += delta;
        reservedSenior += delta;

        if (position.seniorPrincipal >= position.targetSenior) {
            _dequeueOpen(positionId);
        }

        emit PositionMatched(positionId, position.owner, position.seniorPrincipal, delta, position.openedAt);
        return true;
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
        if (block.timestamp <= start) return 0;
        return block.timestamp - start;
    }

    /// @dev Base cut `treasuryCutWad` (default 20%). Boosted MSTR uses `boostedTreasuryCutWad` (default 10%).
    function _treasuryCut(bool boosted) internal view returns (uint256) {
        return boosted ? boostedTreasuryCutWad : treasuryCutWad;
    }

    function _isBoostEligible(address user) internal view returns (bool) {
        return boostStaked[user];
    }

    /// @dev Maker: early exit with Wallet/Idle must fully cover (fees first, then external). Else revert.
    function _assertJuniorCanCover(address junior, CoverMode mode, uint256 coverTotal, uint256 juniorFees)
        internal
        view
    {
        uint256 need = coverTotal > juniorFees ? coverTotal - juniorFees : 0;
        if (need == 0) return;
        if (mode == CoverMode.Wallet) {
            if (usdg.balanceOf(junior) < need || usdg.allowance(junior, address(this)) < need) {
                revert JuniorCoverRequired();
            }
        } else if (mode == CoverMode.IdleCarry) {
            uint256 maxCover =
                seniorPrincipal[junior] < freeSenior() ? seniorPrincipal[junior] : freeSenior();
            if (need > maxCover) revert JuniorCoverRequired();
        } else {
            revert JuniorCoverRequired();
        }
    }

    /// @dev Auto-refund remaining gas credit when Idle withdraw / settle / early exit closes a position.
    function _refundAllGasCredit(address junior) internal {
        uint256 bal = gasCreditWei[junior];
        if (bal == 0) return;
        gasCreditWei[junior] = 0;
        (bool ok,) = junior.call{value: bal}("");
        if (!ok) revert GasTransferFailed();
        emit GasCreditWithdrawn(junior, bal, 0);
    }

    /// @dev Deliver junior exit proceeds to wallet or compound into new Idle positions.
    function _deliverJuniorExit(address junior, uint256 mstrAmt, uint256 usdgAmt) internal {
        if (autoCompound[junior]) {
            if (mstrAmt > 0) _openJuniorFromVaultBalance(junior, mstrAmt);
            if (usdgAmt > 0) _compoundUsdgAsSeniorIdle(junior, usdgAmt);
        } else {
            if (mstrAmt > 0) _push(mstr, junior, mstrAmt);
            if (usdgAmt > 0) _push(usdg, junior, usdgAmt);
        }
    }

    /// @dev Open a new junior Idle from MSTR already held by the vault (compound / no pull).
    function _openJuniorFromVaultBalance(address junior, uint256 mstrAmount) internal returns (uint256 positionId) {
        if (mstrAmount == 0) return 0;
        if (paused) revert Paused();
        uint256 notional = previewSeniorAssets(mstrAmount);
        _enforceJuniorCap(junior, notional);

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
            morphoRateLocked: 0
        });
        _enqueueOpen(positionId);
        totalJuniorUsdg += notional;
        walletJuniorUsdg[junior] += notional;
        positionJuniorUsdg[positionId] = notional;

        bool matched = _tryMatch(positionId);
        emit JuniorDeposit(positionId, junior, mstrAmount, matched);
    }

    /// @dev Compound USDG into senior idle (waiting match). Tokens stay in vault.
    function _compoundUsdgAsSeniorIdle(address user, uint256 amount) internal {
        if (amount == 0) return;
        _enforceSeniorCap(user, amount);
        _checkpoint(user);
        _addSeniorPrincipal(user, amount);
        walletSeniorUsdg[user] += amount;
        _syncDebt(user);
        _matchOpenPositions(_effectiveMatchCap());
    }

    /// @dev Open-queue head junior sponsors gas for the next senior deposit (even if unmatched).
    function _gasSponsor() internal view returns (address) {
        uint256 id = openHead;
        if (id == 0) return address(0);
        Position storage position = positions[id];
        if (position.owner == address(0) || position.settled) return address(0);
        return position.owner;
    }

    /// @dev Pay ETH gas refund from junior escrow to senior. State updated before external call.
    function _payGasRefund(address senior, address sponsor) internal {
        uint256 refund = gasRefundWei;
        if (refund == 0 || sponsor == address(0) || senior == address(0)) return;
        uint256 bal = gasCreditWei[sponsor];
        if (bal == 0) return;
        uint256 pay = bal < refund ? bal : refund;
        gasCreditWei[sponsor] = bal - pay;
        (bool ok,) = senior.call{value: pay}("");
        if (!ok) revert GasTransferFailed();
        emit GasCreditConsumed(sponsor, senior, pay);
    }

    function _price() internal view returns (uint256 price) {
        price = oracle.mstrPriceWad();
        if (price == 0) revert BadPrice();
    }

    function _usdgValue(uint256 mstrAmount, uint256 priceWad) internal view returns (uint256) {
        return CarryMath.usdgValue(mstrAmount, priceWad, mstrDecimals, usdgDecimals);
    }

    function _checkpoint(address senior) internal {
        uint256 principal = seniorPrincipal[senior];

        // Legacy equal-share index (pre-upgrade credits + zero-weight fallback).
        uint256 yieldAccrued = principal * accYieldPerPrincipal / WAD;
        if (yieldAccrued > seniorYieldDebt[senior]) {
            seniorClaimableYield[senior] += yieldAccrued - seniorYieldDebt[senior];
        }
        seniorYieldDebt[senior] = yieldAccrued;

        uint256 mstrAccrued = principal * accMstrPerPrincipal / WAD;
        if (mstrAccrued > seniorMstrDebt[senior]) {
            seniorClaimableMstr[senior] += mstrAccrued - seniorMstrDebt[senior];
        }
        seniorMstrDebt[senior] = mstrAccrued;

        // Time-weighted indices (deposit-time pro-rata).
        uint256 twY = _twYieldRaw(senior);
        if (twY > seniorTwYieldDebt[senior]) {
            seniorClaimableYield[senior] += twY - seniorTwYieldDebt[senior];
        }
        seniorTwYieldDebt[senior] = twY;

        uint256 twM = _twMstrRaw(senior);
        if (twM > seniorTwMstrDebt[senior]) {
            seniorClaimableMstr[senior] += twM - seniorTwMstrDebt[senior];
        }
        seniorTwMstrDebt[senior] = twM;
    }

    function _syncDebt(address senior) internal {
        uint256 principal = seniorPrincipal[senior];
        seniorYieldDebt[senior] = principal * accYieldPerPrincipal / WAD;
        seniorMstrDebt[senior] = principal * accMstrPerPrincipal / WAD;
        seniorTwYieldDebt[senior] = _twYieldRaw(senior);
        seniorTwMstrDebt[senior] = _twMstrRaw(senior);
    }

    function _enforceSeniorCap(address senior, uint256 amount) internal view {
        if (maxTotalSeniorUsdg != 0 && totalSeniorPrincipal + amount > maxTotalSeniorUsdg) revert CapExceeded();
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
