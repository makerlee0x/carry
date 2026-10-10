// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title LeveredLpVault
/// @notice UUPS-upgradeable 2× junior MSTR / senior USDG book (Maker fee waterfall).
///
/// Product CA = PROXY address. Future logic upgrades keep the same proxy.
/// Owner-only `_authorizeUpgrade`. Deploys paused.
///
/// 1. Junior deposits MSTR → Idle or Active (partial match OK).
/// 2. Senior deposits → FIFO match min(available, residual); residual Idle; auto-match later.
/// 3. Fees accrue raw on fee-in. Waterfall ONLY at claimFees / earlyExit / settle:
///    seniorFloor → treasury (20% gross, or Boosted tier) → seniorPerf (20% gross) → junior.
///    accrual = seniorPrincipal × morphoRate × elapsed / 365.
/// 4. Early shortfall: Wallet → Idle Carry → SellShares; treasury +20% of that senior fee.
/// 5. Boosted = stake-before-open flag only (no fake STRATEGY yield).
contract LeveredLpVault is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    uint256 public constant WAD = 1e18;
    uint256 public constant YEAR = 365 days;
    /// @notice Owner-settable Morpho rate cap (docs: fixed ≤5%). Positions lock rate at first match.
    uint256 public constant MAX_MORPHO_RATE_WAD = 0.05e18;
    uint256 public constant MAX_TREASURY_CUT_WAD = 0.2e18;
    uint256 public constant SENIOR_PERF_CUT_WAD = 0.2e18;
    uint256 public constant DEFAULT_TREASURY_CUT_WAD = 0.2e18;
    uint256 public constant BOOSTED_TREASURY_CUT_WAD = 0.1e18;
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
        uint256 feeShortfallUsdg;
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

    uint256[40] private __gap;

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
    error ExternalLpForbidden();
    error TransferFailed();
    error FeeOnTransfer();
    error CapExceeded();
    error ZeroGross();

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
        mstrDecimals = mstr.decimals();
        usdgDecimals = usdg.decimals();
        nextPositionId = 1;
        paused = true;
        emit PausedDeposits(true);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function dualPoolAdapter() external pure returns (address) {
        return address(0);
    }

    function joinPool(bytes calldata) external pure {
        revert ExternalLpForbidden();
    }

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

    function setMorphoFloorApr(uint256 morphoFloorAprWad_) external onlyOwner {
        if (morphoFloorAprWad_ == 0 || morphoFloorAprWad_ > MAX_MORPHO_RATE_WAD) revert BadApr();
        morphoRateWad = morphoFloorAprWad_;
        emit MorphoRateUpdated(morphoFloorAprWad_);
    }

    function morphoFloorAprWad() external view returns (uint256) {
        return morphoRateWad;
    }

    function setTreasuryCuts(uint256 treasuryCutWad_, uint256 boostedTreasuryCutWad_) external onlyOwner {
        if (treasuryCutWad_ > MAX_TREASURY_CUT_WAD || boostedTreasuryCutWad_ > treasuryCutWad_) revert BadCut();
        treasuryCutWad = treasuryCutWad_;
        boostedTreasuryCutWad = boostedTreasuryCutWad_;
        emit TreasuryCutUpdated(treasuryCutWad_, boostedTreasuryCutWad_);
    }

    /// @notice Testnet stub: STRATEGY stake-before-open. No yield minted without funding path.
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

    function depositSenior(uint256 amount) external nonReentrant {
        if (paused) revert Paused();
        if (amount == 0) revert ZeroAmount();
        _enforceSeniorCap(msg.sender, amount);
        _checkpoint(msg.sender);
        seniorPrincipal[msg.sender] += amount;
        totalSeniorPrincipal += amount;
        walletSeniorUsdg[msg.sender] += amount;
        _syncDebt(msg.sender);
        _pullExact(usdg, msg.sender, amount);
        _matchOpenPositions();
        emit SeniorDeposit(msg.sender, amount);
    }

    function withdrawSenior(uint256 principalAmount) external nonReentrant {
        _checkpoint(msg.sender);
        uint256 free = freePrincipal(msg.sender);
        if (principalAmount > free) revert InsufficientFree();
        if (principalAmount > 0) {
            seniorPrincipal[msg.sender] -= principalAmount;
            totalSeniorPrincipal -= principalAmount;
            uint256 credited = walletSeniorUsdg[msg.sender];
            walletSeniorUsdg[msg.sender] = principalAmount > credited ? 0 : credited - principalAmount;
        }
        _syncDebt(msg.sender);

        uint256 yieldUsdg = seniorClaimableYield[msg.sender];
        uint256 mstrOut = seniorClaimableMstr[msg.sender];
        seniorClaimableYield[msg.sender] = 0;
        seniorClaimableMstr[msg.sender] = 0;

        emit SeniorWithdraw(msg.sender, principalAmount, yieldUsdg, mstrOut);

        if (principalAmount + yieldUsdg > 0) _push(usdg, msg.sender, principalAmount + yieldUsdg);
        if (mstrOut > 0) _push(mstr, msg.sender, mstrOut);
    }

    function depositJunior(uint256 mstrAmount) external nonReentrant returns (uint256 positionId) {
        if (paused) revert Paused();
        if (mstrAmount == 0) revert ZeroAmount();
        uint256 notional = previewSeniorAssets(mstrAmount);
        _enforceJuniorCap(msg.sender, notional);

        positionId = nextPositionId++;
        positions[positionId] = Position({
            owner: msg.sender,
            mstrAmount: mstrAmount,
            seniorPrincipal: 0,
            targetSenior: notional,
            entryPriceWad: 0,
            feeUsdg: 0,
            openedAt: 0,
            lastFeeSplitAt: 0,
            settled: false,
            boosted: boostStaked[msg.sender],
            unpaidSeniorAccrual: 0,
            morphoRateLocked: 0
        });
        _enqueueOpen(positionId);
        totalJuniorUsdg += notional;
        walletJuniorUsdg[msg.sender] += notional;
        positionJuniorUsdg[positionId] = notional;
        _pullExact(mstr, msg.sender, mstrAmount);

        bool matched = _tryMatch(positionId);
        emit JuniorDeposit(positionId, msg.sender, mstrAmount, matched);
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
        _push(mstr, msg.sender, amount);
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

    function settle(uint256 positionId) external nonReentrant returns (Settlement memory result) {
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

        // Maturity: never sell junior MSTR. Cover unpaid accrual from treasury/backstop only;
        // residual shortfall is recorded (seniors absorb via feeShortfallUsdg accounting).
        uint256 shortfall = split.accrual > split.seniorFloor ? split.accrual - split.seniorFloor : 0;
        uint256 fromBs = backstop < shortfall ? backstop : shortfall;
        result.fromBackstop = fromBs;
        result.coverUsdg = fromBs;
        shortfall -= fromBs;
        result.feeShortfallUsdg = shortfall;
        result.mstrSold = 0;
        result.mstrKept = position.mstrAmount;

        address junior = position.owner;
        uint256 matchedPrincipal = position.seniorPrincipal;

        position.settled = true;
        position.feeUsdg = 0;
        position.unpaidSeniorAccrual = 0;
        position.mstrAmount = result.mstrKept;
        backstop = backstop - fromBs + split.treasury;
        reservedSenior -= matchedPrincipal;
        _dequeueOpen(positionId);
        _releaseJuniorCap(junior, positionId);

        uint256 seniorUsdg = split.seniorTotal + fromBs;
        if (seniorUsdg > 0 && totalSeniorPrincipal > 0) {
            accYieldPerPrincipal += seniorUsdg * WAD / totalSeniorPrincipal;
        }

        emit WaterfallApplied(
            positionId, gross, split.accrual, split.seniorFloor, split.treasury, split.seniorPerf, split.junior
        );
        emit Settled(positionId, junior, result.mstrKept, result.mstrSold, split.treasury, result.juniorYield);

        if (result.mstrKept > 0) _push(mstr, junior, result.mstrKept);
        if (result.juniorYield > 0) _push(usdg, junior, result.juniorYield);
    }

    function earlyExit(uint256 positionId) external nonReentrant returns (EarlyExitResult memory) {
        return _earlyExit(positionId, CoverMode.SellShares);
    }

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
        return principal * morphoRateWad * elapsed / (WAD * YEAR);
    }

    function previewSeniorAccrual(uint256 principal, uint256 elapsed, uint256 rateWad) public pure returns (uint256) {
        return principal * rateWad * elapsed / (WAD * YEAR);
    }

    function previewEarlyExitCoupon(uint256 principal, uint256 elapsed) public view returns (uint256) {
        return previewSeniorAccrual(principal, elapsed);
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
        return mstrAmount * priceWad * _scale(usdgDecimals) / (WAD * _scale(mstrDecimals));
    }

    function previewMstrToCover(uint256 usdgShort) public view returns (uint256) {
        return previewMstrToCover(usdgShort, _price());
    }

    function previewMstrToCover(uint256 usdgShort, uint256 priceWad) public view returns (uint256) {
        if (usdgShort == 0) return 0;
        if (priceWad == 0) revert BadPrice();
        uint256 numer = usdgShort * WAD * _scale(mstrDecimals);
        uint256 denom = priceWad * _scale(usdgDecimals);
        return _ceilDiv(numer, denom);
    }

    function mark(uint256 positionId)
        external
        view
        returns (uint256 holdUsdg, uint256 leveredEquityUsdg, uint256 unleveredEquityUsdg)
    {
        Position storage position = positions[positionId];
        if (position.owner == address(0) || position.settled) revert BadPosition();
        if (position.seniorPrincipal == 0) revert NotMatched();
        uint256 price = _price();
        holdUsdg = _usdgValue(position.mstrAmount, price);
        leveredEquityUsdg = holdUsdg;
        uint256 entry = position.entryPriceWad;
        uint256 s = position.seniorPrincipal;
        if (entry == 0 || s == 0) return (holdUsdg, leveredEquityUsdg, 0);
        uint256 sqrtR = _sqrt(price * WAD / entry * WAD);
        if (sqrtR * 2 <= WAD) return (holdUsdg, leveredEquityUsdg, 0);
        unleveredEquityUsdg = s * (sqrtR * 2 - WAD) / WAD;
    }

    // ─── internal ────────────────────────────────────────────────────────────

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

        // Waterfall on fees credits seniorTotal (USDG) + treasury; returns junior share.
        WaterfallSplit memory split = _splitAndClearFees(positionId);

        uint256 shortfall = result.accrual > split.seniorFloor ? result.accrual - split.seniorFloor : 0;
        uint256 treasuryOnCover = shortfall * _treasuryCut(position.boosted) / WAD;
        uint256 coverTotal = shortfall + treasuryOnCover;

        uint256 mstrSold;
        uint256 juniorFees = split.junior;

        if (coverTotal > 0) {
            if (mode == CoverMode.Wallet) {
                _pullExact(usdg, msg.sender, coverTotal);
                if (shortfall > 0 && totalSeniorPrincipal > 0) {
                    accYieldPerPrincipal += shortfall * WAD / totalSeniorPrincipal;
                }
                backstop += treasuryOnCover;
            } else if (mode == CoverMode.IdleCarry) {
                // Credit seniors against pre-consume principal base, then burn idle cover.
                if (shortfall > 0 && totalSeniorPrincipal > 0) {
                    accYieldPerPrincipal += shortfall * WAD / totalSeniorPrincipal;
                }
                _consumeIdleCover(msg.sender, coverTotal);
                backstop += treasuryOnCover;
            } else {
                // SellShares: MSTR → seniors for unpaid accrual. Treasury-on-cover taken from
                // junior leftover fees into backstop; any remainder sold as extra MSTR to seniors
                // (no AMM on testnet — documented residual).
                uint256 tNeed = treasuryOnCover;
                if (tNeed > 0) {
                    if (juniorFees >= tNeed) {
                        juniorFees -= tNeed;
                        backstop += tNeed;
                        tNeed = 0;
                    } else {
                        backstop += juniorFees;
                        tNeed -= juniorFees;
                        juniorFees = 0;
                    }
                }
                uint256 usdgNeed = shortfall + tNeed;
                if (usdgNeed > 0) {
                    mstrSold = previewMstrToCover(usdgNeed, price);
                    if (mstrSold > position.mstrAmount) {
                        mstrSold = position.mstrAmount;
                        uint256 got = _usdgValue(mstrSold, price);
                        if (got < shortfall) result.feeShortfallUsdg = shortfall - got;
                    }
                    position.mstrAmount -= mstrSold;
                    if (mstrSold > 0 && totalSeniorPrincipal > 0) {
                        accMstrPerPrincipal += mstrSold * WAD / totalSeniorPrincipal;
                    }
                }
            }
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

        if (mstrReturned > 0) _push(mstr, junior, mstrReturned);
        if (juniorFees > 0) _push(usdg, junior, juniorFees);
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
        if (split.seniorTotal > 0 && totalSeniorPrincipal > 0) {
            accYieldPerPrincipal += split.seniorTotal * WAD / totalSeniorPrincipal;
        }
        emit WaterfallApplied(
            positionId, gross, split.accrual, split.seniorFloor, split.treasury, split.seniorPerf, split.junior
        );
    }

    function _waterfallFromGross(uint256 gross, uint256 accrual, bool boosted)
        internal
        view
        returns (WaterfallSplit memory s)
    {
        s.accrual = accrual;
        s.seniorFloor = gross < accrual ? gross : accrual;
        uint256 left = gross - s.seniorFloor;
        uint256 cut = _treasuryCut(boosted);
        uint256 treasuryCap = gross * cut / WAD;
        s.treasury = left < treasuryCap ? left : treasuryCap;
        left -= s.treasury;
        uint256 perfCap = gross * SENIOR_PERF_CUT_WAD / WAD;
        s.seniorPerf = left < perfCap ? left : perfCap;
        s.junior = left - s.seniorPerf;
        s.seniorTotal = s.seniorFloor + s.seniorPerf;
    }

    function _rateFor(Position storage position) internal view returns (uint256) {
        return position.morphoRateLocked != 0 ? position.morphoRateLocked : morphoRateWad;
    }

    /// @dev unpaid gap + principal × locked rate × elapsed since last split.
    function _accrualFor(Position storage position) internal view returns (uint256) {
        uint256 elapsed = _elapsedSinceSplit(position);
        return position.unpaidSeniorAccrual
            + position.seniorPrincipal * _rateFor(position) * elapsed / (WAD * YEAR);
    }

    /// @dev On incremental match, bank accrual for currently matched principal so new capital is not backdated.
    function _checkpointMatchAccrual(Position storage position) internal {
        uint256 elapsed = _elapsedSinceSplit(position);
        if (elapsed == 0 || position.seniorPrincipal == 0) return;
        position.unpaidSeniorAccrual +=
            position.seniorPrincipal * _rateFor(position) * elapsed / (WAD * YEAR);
        position.lastFeeSplitAt = uint64(block.timestamp);
    }

    /// @dev Burn caller's senior principal against global idle USDG to fund early-exit cover.
    ///      Cap = min(caller principal, freeSenior) so the junior who posted idle can spend it
    ///      without pro-rata freePrincipal dilution blocking the Maker cover path.
    function _consumeIdleCover(address junior, uint256 amount) internal {
        _checkpoint(junior);
        uint256 maxCover = seniorPrincipal[junior] < freeSenior() ? seniorPrincipal[junior] : freeSenior();
        if (amount > maxCover) revert InsufficientIdleCover();
        seniorPrincipal[junior] -= amount;
        totalSeniorPrincipal -= amount;
        uint256 credited = walletSeniorUsdg[junior];
        walletSeniorUsdg[junior] = amount > credited ? 0 : credited - amount;
        _syncDebt(junior);
        // USDG stays in vault; reclassify from senior idle → fee cover / treasury.
    }

    function _matchOpenPositions() internal {
        uint256 id = openHead;
        while (id != 0) {
            uint256 next = openNext[id];
            _tryMatch(id);
            id = next;
            // Stop only when no free senior left (partial may leave head in queue).
            if (freeSenior() == 0) break;
        }
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

    function _treasuryCut(bool boosted) internal view returns (uint256) {
        return boosted ? boostedTreasuryCutWad : treasuryCutWad;
    }

    function _price() internal view returns (uint256 price) {
        price = oracle.mstrPriceWad();
        if (price == 0) revert BadPrice();
    }

    function _usdgValue(uint256 mstrAmount, uint256 priceWad) internal view returns (uint256) {
        return mstrAmount * priceWad * _scale(usdgDecimals) / (WAD * _scale(mstrDecimals));
    }

    function _scale(uint8 decimals_) internal pure returns (uint256) {
        return 10 ** decimals_;
    }

    function _checkpoint(address senior) internal {
        uint256 principal = seniorPrincipal[senior];
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
    }

    function _syncDebt(address senior) internal {
        uint256 principal = seniorPrincipal[senior];
        seniorYieldDebt[senior] = principal * accYieldPerPrincipal / WAD;
        seniorMstrDebt[senior] = principal * accMstrPerPrincipal / WAD;
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

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        return (a - 1) / b + 1;
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
