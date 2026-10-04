// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title LeveredLpVault
/// @notice 2× junior MSTR / senior USDG book. Not upgradeable. Deploys paused.
///
/// Carry-aligned flow (testnet / grant bar):
/// 1. Junior deposits MSTR → Open (unmatched) if no idle USDG, else Active.
/// 2. Senior deposits USDG → matches open juniors FIFO; 7-day active window starts on match.
/// 3. Early exit (junior, while active, before term): coupon = principal · 4% · elapsed / year
///    from position fees first; gap covered by selling junior MSTR from the position (no spare
///    wallet USDG). Returns remaining shares. V1 closes the whole position.
/// 3b. claimFees (junior, while active): once fees ≥ that 4% pace, skim surplus without closing;
///    claimFeeWad of surplus → backstop; coupon stays reserved on the position.
/// 4. Settle (after term): maturity borrow fee (borrowAprWad · term / year); may sell shares
///    if fees + backstop cannot cover. Separate path from early exit.
/// 5. Lender exit: withdraw idle/free principal anytime; matched size needs replacement USDG
///    (more senior deposits) or position close (early exit / settle).
///
/// Mock DualPool: fees are pushed in via `accrueLpFee`. No Yieldz / Morpho / STRATEGY wiring.
/// Owner can pause/unpause deposits and rescue non-principal tokens only.
contract LeveredLpVault {
    uint256 public constant WAD = 1e18;
    uint256 public constant YEAR = 365 days;
    uint256 public constant MAX_BORROW_APR_WAD = 0.05e18;
    uint256 public constant MAX_PROTOCOL_CUT_WAD = 0.2e18;
    /// @notice Early-exit coupon pace / pool-floor APR in product copy (4%).
    uint256 public constant EARLY_EXIT_APR_WAD = 0.04e18;
    /// @notice Max claim-fee cut when skimming fees without closing (10%).
    uint256 public constant MAX_CLAIM_FEE_WAD = 0.1e18;
    uint64 public constant MAX_TERM = 7 days;

    /// @dev Documented target. This vault does not approve it and holds no position there.
    address public constant ROBINHOOD_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    struct Position {
        address owner;
        uint256 mstrAmount;
        uint256 seniorPrincipal; // 0 while Open / unmatched
        uint256 entryPriceWad; // set at match (active)
        uint256 feeUsdg;
        uint64 openedAt; // match timestamp; 0 while Open
        bool settled;
    }

    struct Settlement {
        uint256 mstrKept;
        uint256 mstrSold;
        uint256 borrowFeeOwed;
        uint256 fromPositionFees;
        uint256 fromBackstop;
        uint256 juniorYield;
        uint256 feeShortfallUsdg;
    }

    struct EarlyExitResult {
        uint256 elapsed;
        uint256 couponOwed;
        uint256 fromPositionFees;
        uint256 usdgGap;
        uint256 mstrSold;
        uint256 mstrReturned;
        uint256 juniorLeftoverFees;
        uint256 feeShortfallUsdg;
    }

    struct ClaimFeesResult {
        uint256 elapsed;
        uint256 couponReserved;
        uint256 claimedGross;
        uint256 claimFee;
        uint256 toJunior;
    }

    IERC20Minimal public immutable mstr;
    IERC20Minimal public immutable usdg;
    IPriceOracle public immutable oracle;
    uint64 public immutable term;
    uint256 public immutable borrowAprWad;
    uint256 public immutable protocolCutWad;
    address public immutable owner;
    uint8 public immutable mstrDecimals;
    uint8 public immutable usdgDecimals;

    bool public paused;
    uint256 public backstop;
    uint256 public totalSeniorPrincipal;
    uint256 public reservedSenior;
    uint256 public nextPositionId = 1;
    uint256 public accYieldPerPrincipal;
    uint256 public accMstrPerPrincipal;

    /// @notice Owner-set TVL caps in USDG units. Zero means uncapped (default for legacy deploys).
    uint256 public maxTotalSeniorUsdg;
    uint256 public maxTotalJuniorUsdg;
    uint256 public maxPerWalletUsdg;
    uint256 public totalJuniorUsdg;
    mapping(address => uint256) public walletSeniorUsdg;
    mapping(address => uint256) public walletJuniorUsdg;
    mapping(uint256 => uint256) public positionJuniorUsdg;

    /// @notice Product Morpho-rate floor for seniors (display / Vault v2 placeholder). Settlement still uses immutable `borrowAprWad`.
    uint256 public morphoFloorAprWad;
    /// @notice Cut of claimed fee surplus paid to backstop (default 0.5%).
    uint256 public claimFeeWad;

    /// @dev FIFO queue of Open (unmatched) position ids.
    uint256 public openHead;
    uint256 public openTail;
    mapping(uint256 => uint256) public openNext;

    mapping(uint256 => Position) public positions;
    mapping(address => uint256) public seniorPrincipal;
    mapping(address => uint256) public seniorClaimableYield;
    mapping(address => uint256) public seniorClaimableMstr;
    mapping(address => uint256) public seniorYieldDebt;
    mapping(address => uint256) public seniorMstrDebt;

    uint256 private _locked = 1;

    error Paused();
    error NotOwner();
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
    error PrincipalToken();
    error ExternalLpForbidden();
    error TransferFailed();
    error FeeOnTransfer();
    error Reentered();
    error CapExceeded();
    error ClaimThreshold();
    error BadClaimFee();

    event PausedDeposits(bool paused);
    event SeniorDeposit(address indexed senior, uint256 amount);
    event SeniorWithdraw(address indexed senior, uint256 principal, uint256 yieldUsdg, uint256 mstrAmount);
    event JuniorDeposit(uint256 indexed positionId, address indexed junior, uint256 mstrAmount, bool matched);
    event PositionMatched(
        uint256 indexed positionId, address indexed junior, uint256 seniorPrincipal, uint64 openedAt
    );
    event UnmatchedWithdraw(uint256 indexed positionId, address indexed junior, uint256 mstrAmount);
    event LpFeeAccrued(uint256 indexed positionId, uint256 gross, uint256 toBackstop, uint256 toPosition);
    event BackstopFunded(address indexed from, uint256 amount);
    event Settled(
        uint256 indexed positionId,
        address indexed junior,
        uint256 mstrKept,
        uint256 mstrSold,
        uint256 fromBackstop,
        uint256 juniorYield
    );
    event EarlyExit(
        uint256 indexed positionId,
        address indexed junior,
        uint256 couponOwed,
        uint256 fromPositionFees,
        uint256 usdgGap,
        uint256 mstrSold,
        uint256 mstrReturned,
        uint256 juniorLeftoverFees
    );
    event CapsUpdated(uint256 maxTotalSeniorUsdg, uint256 maxTotalJuniorUsdg, uint256 maxPerWalletUsdg);
    event MorphoFloorAprUpdated(uint256 morphoFloorAprWad);
    event ClaimFeeUpdated(uint256 claimFeeWad);
    event FeesClaimed(
        uint256 indexed positionId,
        address indexed junior,
        uint256 claimedGross,
        uint256 claimFee,
        uint256 toJunior,
        uint256 couponReserved
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentered();
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier whenDepositsOpen() {
        if (paused) revert Paused();
        _;
    }

    constructor(
        address mstr_,
        address usdg_,
        address oracle_,
        uint64 term_,
        uint256 borrowAprWad_,
        uint256 protocolCutWad_,
        address owner_
    ) {
        if (mstr_ == address(0) || usdg_ == address(0) || oracle_ == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        if (term_ == 0 || term_ > MAX_TERM) revert BadTerm();
        if (borrowAprWad_ > MAX_BORROW_APR_WAD) revert BadApr();
        if (protocolCutWad_ > MAX_PROTOCOL_CUT_WAD) revert BadCut();

        mstr = IERC20Minimal(mstr_);
        usdg = IERC20Minimal(usdg_);
        oracle = IPriceOracle(oracle_);
        term = term_;
        borrowAprWad = borrowAprWad_;
        protocolCutWad = protocolCutWad_;
        owner = owner_;
        mstrDecimals = mstr.decimals();
        usdgDecimals = usdg.decimals();
        paused = true;
        // Default product floor ~3.9% Morpho; owner may refresh within borrow APR bound.
        morphoFloorAprWad = 0.039e18;
        claimFeeWad = 0.005e18; // 0.5% of claimed surplus
        emit PausedDeposits(true);
    }

    /// @notice No adapter is connected. Inventory cannot be pulled into a pool.
    function dualPoolAdapter() external pure returns (address) {
        return address(0);
    }

    /// @dev External LPs are rejected. The only book is this vault's custody.
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

    /// @notice Owner-set deposit caps (USDG units / junior notional). Zero = uncapped.
    function setDepositCaps(uint256 maxTotalSeniorUsdg_, uint256 maxTotalJuniorUsdg_, uint256 maxPerWalletUsdg_)
        external
        onlyOwner
    {
        maxTotalSeniorUsdg = maxTotalSeniorUsdg_;
        maxTotalJuniorUsdg = maxTotalJuniorUsdg_;
        maxPerWalletUsdg = maxPerWalletUsdg_;
        emit CapsUpdated(maxTotalSeniorUsdg_, maxTotalJuniorUsdg_, maxPerWalletUsdg_);
    }

    /// @notice Owner-bounded Morpho floor APR placeholder (≤ MAX_BORROW_APR_WAD). Does not change settle math.
    function setMorphoFloorApr(uint256 morphoFloorAprWad_) external onlyOwner {
        if (morphoFloorAprWad_ > MAX_BORROW_APR_WAD) revert BadApr();
        morphoFloorAprWad = morphoFloorAprWad_;
        emit MorphoFloorAprUpdated(morphoFloorAprWad_);
    }

    /// @notice Owner-bounded fee on claimFees surplus (≤ 10%).
    function setClaimFee(uint256 claimFeeWad_) external onlyOwner {
        if (claimFeeWad_ > MAX_CLAIM_FEE_WAD) revert BadClaimFee();
        claimFeeWad = claimFeeWad_;
        emit ClaimFeeUpdated(claimFeeWad_);
    }

    /// @notice Rescue a token that is not MSTR and not USDG. Principal stays put.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(mstr) || token == address(usdg)) revert PrincipalToken();
        if (to == address(0)) revert ZeroAddress();
        _push(IERC20Minimal(token), to, amount);
    }

    /// @notice Lend USDG. Idle USDG then FIFO-matches Open junior positions (Carry: lender matches).
    function depositSenior(uint256 amount) external whenDepositsOpen nonReentrant {
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

    /// @notice Free principal is the caller's pro-rata share of unmatched USDG.
    ///         Matched USDG stays until juniors exit/settle or more seniors replace idle capacity.
    ///         Yield and MSTR claims pay out even when principalAmount is zero.
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
        uint256 mstrAmount = seniorClaimableMstr[msg.sender];
        seniorClaimableYield[msg.sender] = 0;
        seniorClaimableMstr[msg.sender] = 0;

        emit SeniorWithdraw(msg.sender, principalAmount, yieldUsdg, mstrAmount);

        if (principalAmount + yieldUsdg > 0) _push(usdg, msg.sender, principalAmount + yieldUsdg);
        if (mstrAmount > 0) _push(mstr, msg.sender, mstrAmount);
    }

    /// @notice Deposit stock. Matches immediately if idle USDG exists; else stays Open (unmatched).
    function depositJunior(uint256 mstrAmount) external whenDepositsOpen nonReentrant returns (uint256 positionId) {
        if (mstrAmount == 0) revert ZeroAmount();
        uint256 notional = previewSeniorAssets(mstrAmount);
        _enforceJuniorCap(msg.sender, notional);

        positionId = nextPositionId++;
        positions[positionId] = Position({
            owner: msg.sender,
            mstrAmount: mstrAmount,
            seniorPrincipal: 0,
            entryPriceWad: 0,
            feeUsdg: 0,
            openedAt: 0,
            settled: false
        });
        _enqueueOpen(positionId);
        totalJuniorUsdg += notional;
        walletJuniorUsdg[msg.sender] += notional;
        positionJuniorUsdg[positionId] = notional;
        _pullExact(mstr, msg.sender, mstrAmount);

        bool matched = _tryMatch(positionId);
        emit JuniorDeposit(positionId, msg.sender, mstrAmount, matched);
    }

    /// @notice Cancel an Open (unmatched) position and return all MSTR. No coupon.
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

    /// @notice Anyone may donate USDG fees. Tokens only move in. Protocol cut fills the backstop.
    ///         Rejects fee-on-transfer tokens (credited amount must equal `amount`).
    function accrueLpFee(uint256 positionId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage position = positions[positionId];
        if (position.owner == address(0) || position.settled) revert BadPosition();
        if (position.seniorPrincipal == 0) revert NotMatched();

        _pullExact(usdg, msg.sender, amount);

        uint256 cut = amount * protocolCutWad / WAD;
        uint256 toPosition = amount - cut;
        backstop += cut;
        position.feeUsdg += toPosition;
        emit LpFeeAccrued(positionId, amount, cut, toPosition);
    }

    function fundBackstop(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _pullExact(usdg, msg.sender, amount);
        backstop += amount;
        emit BackstopFunded(msg.sender, amount);
    }

    /// @notice After active `term`, pay the senior borrow fee and return leftover MSTR to the junior.
    ///         Callable by anyone. Proceeds go to the position owner and to seniors, never to the caller.
    function settle(uint256 positionId) external nonReentrant returns (Settlement memory result) {
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert BadPosition();
        if (position.settled) revert AlreadySettled();
        if (position.seniorPrincipal == 0) revert NotMatched();
        if (block.timestamp < uint256(position.openedAt) + term) revert TermNotElapsed();

        uint256 price = _price();
        result.borrowFeeOwed = previewBorrowFee(position.seniorPrincipal);
        result.fromPositionFees = position.feeUsdg < result.borrowFeeOwed ? position.feeUsdg : result.borrowFeeOwed;
        uint256 gap = result.borrowFeeOwed - result.fromPositionFees;
        result.fromBackstop = backstop < gap ? backstop : gap;
        gap -= result.fromBackstop;
        result.juniorYield = position.feeUsdg - result.fromPositionFees;

        if (gap > 0) {
            result.mstrSold = previewMstrToCover(gap, price);
            if (result.mstrSold > position.mstrAmount) {
                result.mstrSold = position.mstrAmount;
                result.feeShortfallUsdg = gap - _usdgValue(result.mstrSold, price);
            }
        }
        result.mstrKept = position.mstrAmount - result.mstrSold;

        address junior = position.owner;
        position.settled = true;
        position.feeUsdg = 0;
        backstop -= result.fromBackstop;
        reservedSenior -= position.seniorPrincipal;
        _releaseJuniorCap(junior, positionId);

        uint256 seniorPaid = result.fromPositionFees + result.fromBackstop;
        if (seniorPaid > 0 && totalSeniorPrincipal > 0) {
            accYieldPerPrincipal += seniorPaid * WAD / totalSeniorPrincipal;
        }
        if (result.mstrSold > 0 && totalSeniorPrincipal > 0) {
            accMstrPerPrincipal += result.mstrSold * WAD / totalSeniorPrincipal;
        }

        emit Settled(positionId, junior, result.mstrKept, result.mstrSold, result.fromBackstop, result.juniorYield);

        if (result.mstrKept > 0) _push(mstr, junior, result.mstrKept);
        if (result.juniorYield > 0) _push(usdg, junior, result.juniorYield);
    }

    /// @notice Claim fee surplus without closing. Requires accrued fees ≥ 4% pace for elapsed time.
    ///         Reserves the current early-exit coupon in the position; surplus pays claimFeeWad to backstop,
    ///         remainder to the junior. Intent matches Maker claim-at-4% (math sign-off still welcome).
    function claimFees(uint256 positionId) external nonReentrant returns (ClaimFeesResult memory result) {
        result = previewClaimFees(positionId);
        Position storage position = positions[positionId];
        if (position.owner != msg.sender) revert NotJunior();

        position.feeUsdg = result.couponReserved;
        backstop += result.claimFee;

        emit FeesClaimed(
            positionId, msg.sender, result.claimedGross, result.claimFee, result.toJunior, result.couponReserved
        );

        if (result.toJunior > 0) _push(usdg, msg.sender, result.toJunior);
    }

    /// @notice Preview claimFees. Reverts if unmatched, settled, after term, or below 4% pace threshold.
    function previewClaimFees(uint256 positionId) public view returns (ClaimFeesResult memory result) {
        Position storage position = positions[positionId];
        if (position.owner == address(0) || position.settled) revert BadPosition();
        if (position.seniorPrincipal == 0) revert NotMatched();
        if (block.timestamp >= uint256(position.openedAt) + term) revert TermElapsed();

        result.elapsed = block.timestamp - uint256(position.openedAt);
        result.couponReserved = previewEarlyExitCoupon(position.seniorPrincipal, result.elapsed);
        if (position.feeUsdg < result.couponReserved) revert ClaimThreshold();

        result.claimedGross = position.feeUsdg - result.couponReserved;
        if (result.claimedGross == 0) revert ZeroAmount();
        result.claimFee = result.claimedGross * claimFeeWad / WAD;
        result.toJunior = result.claimedGross - result.claimFee;
    }

    /// @notice Close a matched position before `term`. Coupon from position fees; gap via MSTR from
    ///         this position only (no external spare-wallet USDG). After term, use `settle`.
    function earlyExit(uint256 positionId) external nonReentrant returns (EarlyExitResult memory result) {
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert BadPosition();
        if (position.owner != msg.sender) revert NotJunior();
        if (position.settled) revert AlreadySettled();
        if (position.seniorPrincipal == 0) revert NotMatched();
        if (block.timestamp >= uint256(position.openedAt) + term) revert TermElapsed();

        result = previewEarlyExit(positionId);

        address junior = position.owner;
        position.settled = true;
        position.feeUsdg = 0;
        reservedSenior -= position.seniorPrincipal;
        _releaseJuniorCap(junior, positionId);

        uint256 seniorPaid = result.fromPositionFees;
        if (seniorPaid > 0 && totalSeniorPrincipal > 0) {
            accYieldPerPrincipal += seniorPaid * WAD / totalSeniorPrincipal;
        }
        if (result.mstrSold > 0 && totalSeniorPrincipal > 0) {
            accMstrPerPrincipal += result.mstrSold * WAD / totalSeniorPrincipal;
        }

        emit EarlyExit(
            positionId,
            junior,
            result.couponOwed,
            result.fromPositionFees,
            result.usdgGap,
            result.mstrSold,
            result.mstrReturned,
            result.juniorLeftoverFees
        );

        if (result.mstrReturned > 0) _push(mstr, junior, result.mstrReturned);
        if (result.juniorLeftoverFees > 0) _push(usdg, junior, result.juniorLeftoverFees);
    }

    /// @notice Early-exit coupon and share waterfall for an active position. Reverts after term.
    function previewEarlyExit(uint256 positionId) public view returns (EarlyExitResult memory result) {
        Position storage position = positions[positionId];
        if (position.owner == address(0) || position.settled) revert BadPosition();
        if (position.seniorPrincipal == 0) revert NotMatched();
        if (block.timestamp >= uint256(position.openedAt) + term) revert TermElapsed();

        result.elapsed = block.timestamp - uint256(position.openedAt);
        result.couponOwed = previewEarlyExitCoupon(position.seniorPrincipal, result.elapsed);
        result.fromPositionFees = position.feeUsdg < result.couponOwed ? position.feeUsdg : result.couponOwed;
        result.usdgGap = result.couponOwed - result.fromPositionFees;
        result.juniorLeftoverFees = position.feeUsdg - result.fromPositionFees;

        if (result.usdgGap > 0) {
            uint256 price = _price();
            result.mstrSold = previewMstrToCover(result.usdgGap, price);
            if (result.mstrSold > position.mstrAmount) {
                result.mstrSold = position.mstrAmount;
                result.feeShortfallUsdg = result.usdgGap - _usdgValue(result.mstrSold, price);
            }
        }
        result.mstrReturned = position.mstrAmount - result.mstrSold;
    }

    /// @notice Lender coupon for early exit: principal · 4% · elapsed / 365 days.
    function previewEarlyExitCoupon(uint256 principal, uint256 elapsed) public pure returns (uint256) {
        return principal * EARLY_EXIT_APR_WAD * elapsed / (WAD * YEAR);
    }

    function isMatched(uint256 positionId) public view returns (bool) {
        Position storage position = positions[positionId];
        return position.owner != address(0) && !position.settled && position.seniorPrincipal != 0;
    }

    /// @notice Idle USDG a senior can withdraw now without breaking matched inventory.
    function freeSenior() public view returns (uint256) {
        return totalSeniorPrincipal - reservedSenior;
    }

    function freePrincipal(address senior) public view returns (uint256) {
        if (totalSeniorPrincipal == 0) return 0;
        return seniorPrincipal[senior] * freeSenior() / totalSeniorPrincipal;
    }

    function previewBorrowFee(uint256 principal) public view returns (uint256) {
        return principal * borrowAprWad * term / (WAD * YEAR);
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

    /// @notice 2× equity equals holding the junior MSTR. Unlevered 50/50 is S·(2√r − 1).
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

    function _matchOpenPositions() internal {
        while (openHead != 0) {
            uint256 id = openHead;
            if (!_tryMatch(id)) break;
        }
    }

    /// @dev Match one Open position if idle USDG covers oracle notional. Starts the 7-day window.
    function _tryMatch(uint256 positionId) internal returns (bool matched) {
        Position storage position = positions[positionId];
        if (position.owner == address(0) || position.settled || position.seniorPrincipal != 0) {
            return false;
        }

        uint256 price = _price();
        uint256 seniorNeed = previewSeniorAssets(position.mstrAmount, price);
        if (seniorNeed == 0) revert BadPrice();
        if (freeSenior() < seniorNeed) return false;

        position.seniorPrincipal = seniorNeed;
        position.entryPriceWad = price;
        position.openedAt = uint64(block.timestamp);
        reservedSenior += seniorNeed;
        _dequeueOpen(positionId);

        emit PositionMatched(positionId, position.owner, seniorNeed, position.openedAt);
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

    /// @dev Pull exact `amount`. Reverts on failure or fee-on-transfer (balance delta != amount).
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

    /// @dev Babylonian sqrt. Used only for the unlevered comparison view.
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
