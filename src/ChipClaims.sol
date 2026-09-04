// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IChipRewardsClaimable} from "./interfaces/IChipRewardsClaimable.sol";
import {IStockRegistry} from "./interfaces/IStockRegistry.sol";

/// @title ChipClaims
/// @notice The ledger. Every token a holder is owed lives here, and this is the only
///         contract that can pay one out.
///
/// @dev SPLIT FROM ChipRounds ON PURPOSE, AND THIS IS THE SMALLER HALF.
///
///      Chipworks used to be one contract. It grew past the EIP-170 code size limit, and
///      rather than shave bytes it was split along the line that matters: the machinery
///      that SPENDS money (opening rounds, pricing swaps, buying stock) is in
///      {ChipRounds}; the ledger that OWES money is here.
///
///      That boundary was chosen so this file can stay small enough to hold in your head.
///      It has no swap logic, no router, no price bounds, no venue handling — none of the
///      moving parts that make the engine complicated. What it does is arithmetic on
///      recorded weights, a time gate, and transfers out. An auditor reading only this
///      file can decide whether holders can be paid what they are owed and nothing more.
///
///      NO PROXY, NO DELEGATECALL. Two plain contracts wired at deploy. `rounds` is a
///      single trusted caller set by the multisig; everything it can do is enumerated in
///      the four `onlyRounds` functions below, and none of them can move a token out.
///
///      THE CREDIT MODEL, unchanged by the split: per-round weight shares, converted to
///      token amounts lazily at claim time.
///
///          claimable = acquired[round][stock] * weightOf[round][stock][you]
///                                             / totalWeight[round][stock]
contract ChipClaims is IChipRewardsClaimable, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Minimum full claim windows a round must offer before it can expire.
    uint256 public constant MIN_WINDOWS_BEFORE_EXPIRY = 3;

    uint32 public constant MIN_WINDOW_LENGTH = 1 days;
    uint32 public constant MAX_WINDOW_LENGTH = 30 days;
    uint32 public constant MIN_OPEN_DURATION = 1 hours;
    uint32 public constant MAX_CREDIT_EXPIRY = 365 days;

    /// @notice Gas cap on calls into foreign contracts. See ASSUMPTIONS.md A-17.
    uint256 public constant PROBE_GAS = 100_000;

    /// @notice A round's claim schedule, frozen when the round finalizes.
    struct Schedule {
        uint64 finalizedAt;
        uint64 expiresAt;
        uint32 windowLengthAt;
        uint32 openDurationAt;
    }

    /* ----------------------------- wiring ----------------------------- */

    IStockRegistry public immutable registry;
    address public immutable quoteToken;

    /// @notice Timestamp all claim windows are counted from. Set at deploy, never changeable.
    /// @dev Immutable on purpose: if governance could move the anchor it could slide the
    ///      windows forward indefinitely and block claims without changing a duration.
    uint64 public immutable windowAnchor;

    /// @notice The round engine. The only contract allowed to write credits.
    address public rounds;

    /// @notice Where expired credits and auto-compounded claims are sent.
    address public polTreasury;

    /// @notice Notice period on a retarget of `rounds` or `polTreasury`. Same 48h shape as
    ///         every other economic parameter in this repo.
    uint64 public constant CONFIG_TIMELOCK = 48 hours;

    struct PendingAddress {
        bool queued;
        uint64 executableAt;
        address target;
    }

    PendingAddress internal _pendingRounds;
    PendingAddress internal _pendingPol;

    /* --------------------------- tunables ----------------------------- */

    uint32 public windowLength;
    uint32 public windowOpenDuration;
    uint64 public creditExpiry;

    /* ----------------------------- ledger ----------------------------- */

    mapping(uint256 roundId => Schedule) internal _schedules;

    mapping(uint256 roundId => mapping(address stock => uint256)) public totalWeight;
    mapping(uint256 roundId => mapping(address stock => mapping(address owner => uint256))) public weightOf;
    mapping(uint256 roundId => mapping(address stock => uint256)) public acquired;
    mapping(uint256 roundId => mapping(address stock => uint256)) public claimedTotal;
    mapping(uint256 roundId => mapping(address stock => uint256)) public sweptTotal;
    mapping(uint256 roundId => mapping(address stock => bool)) public stockSwept;
    mapping(uint256 roundId => mapping(address stock => uint256)) public sweepCursor;
    mapping(uint256 roundId => mapping(address stock => mapping(address owner => bool))) public hasClaimed;

    /// @notice Everyone credited in a (round, stock), in credit order.
    mapping(uint256 roundId => mapping(address stock => address[])) internal _holders;

    mapping(address owner => bool) public autoCompound;
    mapping(address owner => uint256) public polCreditUsd;

    /// @notice Token units owed to claimants across every unexpired round.
    /// @dev The rescue can never touch this.
    mapping(address token => uint256) public totalOwed;

    /* ----------------------------- events ----------------------------- */

    event Claimed(uint256 indexed roundId, address indexed stock, address indexed owner, uint256 amount);
    event Compounded(uint256 indexed roundId, address indexed stock, address indexed owner, uint256 amount);
    event Swept(uint256 indexed roundId, address indexed stock, uint256 amount, bool complete);
    event CreditExpired(uint256 indexed roundId, address indexed stock, address indexed owner, uint256 amount);
    event WeightCredited(uint256 indexed roundId, address indexed stock, address indexed owner, uint256 weight);
    event AcquiredRecorded(uint256 indexed roundId, address indexed stock, uint256 amount);
    event ScheduleFrozen(uint256 indexed roundId, uint64 expiresAt, uint32 windowLength, uint32 openDuration);
    event ClaimScheduleUpdated(uint32 windowLength, uint32 openDuration, uint64 creditExpiry);
    event AutoCompoundSet(address indexed owner, bool enabled);
    event ExcessRecovered(address indexed token, address indexed to, uint256 amount);
    event RoundsUpdated(address indexed previous, address indexed current);
    event RoundsQueued(address indexed target, uint64 executableAt);
    event PolTreasuryQueued(address indexed target, uint64 executableAt);
    event RetargetCancelled();
    event PolTreasuryUpdated(address indexed previous, address indexed current);

    /* ----------------------------- errors ----------------------------- */

    error ZeroAddress();
    error NotRounds(address caller);
    error AlreadyWired();
    error NothingQueued();
    error TimelockNotElapsed(uint64 nowTs, uint64 executableAt);
    error RoundNotFinalized(uint256 roundId);
    error AlreadyFinalized(uint256 roundId);
    error AlreadyClaimed(uint256 roundId, address stock, address owner);
    error NothingToClaim();
    error CreditsExpired(uint256 roundId, uint64 expiredAt);
    /// @dev Carries the next opening so a caller knows exactly when to return.
    error ClaimsClosed(uint64 nowTs, uint64 nextOpenAt);
    error NotExpiredYet(uint256 roundId, uint64 expiresAt);
    error AlreadySwept(uint256 roundId, address stock);
    error InsufficientExcess(address token, uint256 requested, uint256 available);
    error Insolvent(address token);
    error BadConfig();
    error LengthMismatch();
    error Underfunded(address stock, uint256 held, uint256 needed);

    modifier onlyRounds() {
        if (msg.sender != rounds) revert NotRounds(msg.sender);
        _;
    }

    /// @param multisig  Owner.
    /// @param registry_ StockRegistry, used only to mark compounded claims in USD.
    constructor(address multisig, address registry_) Ownable(multisig) {
        if (multisig == address(0) || registry_ == address(0)) revert ZeroAddress();
        registry = IStockRegistry(registry_);
        quoteToken = IStockRegistry(registry_).quoteToken();

        windowAnchor = uint64(block.timestamp);
        windowLength = 7 days;
        windowOpenDuration = 48 hours;
        creditExpiry = 30 days;
    }

    /* ------------------------------------------------------------------ */
    /*                     WRITES, ENGINE ONLY (4 of them)                  */
    /* ------------------------------------------------------------------ */

    /// @notice Record that `owner` is entitled to a share of a (round, stock).
    /// @dev Called during accumulation. Cannot move tokens, cannot pay anyone.
    function creditWeight(uint256 roundId, address stock, address owner, uint256 weight) external onlyRounds {
        if (_schedules[roundId].finalizedAt != 0) revert AlreadyFinalized(roundId);
        if (weight == 0) return;

        // First credit for this holder here: remember them so the expiry sweep can
        // report exactly what each person lost.
        if (weightOf[roundId][stock][owner] == 0) _holders[roundId][stock].push(owner);
        weightOf[roundId][stock][owner] += weight;
        totalWeight[roundId][stock] += weight;
        emit WeightCredited(roundId, stock, owner, weight);
    }

    /// @notice Record tokens the engine has already transferred in.
    /// @dev Checks the tokens are actually here before believing the number. The engine is
    ///      trusted to be the engine, not trusted to be correct: if it reports more than
    ///      this contract holds, the call reverts rather than booking a debt it cannot pay.
    function recordAcquired(uint256 roundId, address stock, uint256 amount) external onlyRounds {
        if (_schedules[roundId].finalizedAt != 0) revert AlreadyFinalized(roundId);
        if (amount == 0) return;

        uint256 held = IERC20(stock).balanceOf(address(this));
        uint256 needed = totalOwed[stock] + amount;
        if (held < needed) revert Underfunded(stock, held, needed);

        acquired[roundId][stock] += amount;
        totalOwed[stock] += amount;
        emit AcquiredRecorded(roundId, stock, amount);
    }

    /// @notice Freeze a round's claim schedule. Called once, when the round finalizes.
    /// @dev Snapshotting means a later governance change can never narrow or shorten a
    ///      round that already exists.
    function freezeSchedule(uint256 roundId) external onlyRounds returns (uint64 roundExpiresAt) {
        Schedule storage s = _schedules[roundId];
        if (s.finalizedAt != 0) revert AlreadyFinalized(roundId);

        s.finalizedAt = uint64(block.timestamp);
        roundExpiresAt = uint64(block.timestamp + creditExpiry);
        s.expiresAt = roundExpiresAt;
        s.windowLengthAt = windowLength;
        s.openDurationAt = windowOpenDuration;

        emit ScheduleFrozen(roundId, roundExpiresAt, windowLength, windowOpenDuration);
    }

    /* ------------------------------------------------------------------ */
    /*                              CLAIMS                                  */
    /* ------------------------------------------------------------------ */

    /// @notice What `owner` can still claim from one round for one stock.
    function claimable(uint256 roundId, address stock, address owner) public view returns (uint256) {
        if (hasClaimed[roundId][stock][owner]) return 0;
        uint256 tw = totalWeight[roundId][stock];
        if (tw == 0) return 0;
        uint256 got = acquired[roundId][stock];
        if (got == 0) return 0;
        return (got * weightOf[roundId][stock][owner]) / tw;
    }

    /// @notice Claim one stock from one round.
    /// @dev One stock per call: a frozen stock blocks only its own claim, never anyone
    ///      else's and never another stock in the same round.
    function claim(uint256 roundId, address stock) external nonReentrant returns (uint256 amount) {
        amount = _claim(roundId, stock, msg.sender);
    }

    /// @notice Claim on someone else's behalf. Proceeds always go to `owner`.
    /// @dev Safe to leave permissionless: a stranger calling it can only deliver the
    ///      owner's own credit to the owner, and protect them from expiry.
    function claimFor(address owner, uint256 roundId, address stock) external nonReentrant returns (uint256 amount) {
        if (owner == address(0)) revert ZeroAddress();
        amount = _claim(roundId, stock, owner);
    }

    /// @notice Claim many (round, stock) pairs in one transaction.
    /// @dev Pairs yielding nothing are skipped rather than reverting. A pair whose TOKEN is
    ///      frozen still reverts the batch: fall back to single `claim` calls.
    function claimMany(uint256[] calldata roundIds, address[] calldata stocks)
        external
        nonReentrant
        returns (uint256 total)
    {
        if (roundIds.length != stocks.length) revert LengthMismatch();
        for (uint256 i; i < roundIds.length; ++i) {
            if (claimable(roundIds[i], stocks[i], msg.sender) == 0) continue;
            total += _claim(roundIds[i], stocks[i], msg.sender);
        }
        if (total == 0) revert NothingToClaim();
    }

    function _claim(uint256 roundId, address stock, address owner) internal returns (uint256 amount) {
        Schedule storage s = _schedules[roundId];
        if (s.finalizedAt == 0) revert RoundNotFinalized(roundId);
        if (block.timestamp > s.expiresAt) revert CreditsExpired(roundId, s.expiresAt);

        // Credits accrue continuously and are always visible via `claimable`, but they can
        // only be taken while a window is open. The round's own frozen cadence is used, so
        // a later governance change can never narrow a round that already exists.
        if (!_isOpenAt(uint64(block.timestamp), s.windowLengthAt, s.openDurationAt)) {
            (, uint64 opensAt,) = _windowStateAt(uint64(block.timestamp), s.windowLengthAt, s.openDurationAt);
            revert ClaimsClosed(uint64(block.timestamp), opensAt);
        }

        if (hasClaimed[roundId][stock][owner]) revert AlreadyClaimed(roundId, stock, owner);

        amount = claimable(roundId, stock, owner);
        if (amount == 0) revert NothingToClaim();

        hasClaimed[roundId][stock][owner] = true;
        claimedTotal[roundId][stock] += amount;
        totalOwed[stock] -= amount;

        if (autoCompound[owner] && polTreasury != address(0)) {
            IERC20(stock).safeTransfer(polTreasury, amount);
            uint256 usd = _usdValue(stock, amount);
            polCreditUsd[owner] += usd;
            // Best effort: the POL-side ledger is a mirror and must never block a claim.
            (bool noted,) = polTreasury.call{gas: PROBE_GAS}(
                abi.encodeWithSignature("notifyCompound(address,address,uint256,uint256)", owner, stock, amount, usd)
            );
            noted; // intentionally ignored
            emit Compounded(roundId, stock, owner, amount);
        } else {
            IERC20(stock).safeTransfer(owner, amount);
            emit Claimed(roundId, stock, owner, amount);
        }
    }

    function setAutoCompound(bool enabled) external {
        autoCompound[msg.sender] = enabled;
        emit AutoCompoundSet(msg.sender, enabled);
    }

    /* ------------------------------------------------------------------ */
    /*                              EXPIRY                                  */
    /* ------------------------------------------------------------------ */

    /// @notice After a round's credits expire, send what nobody claimed to the POL treasury.
    ///         Permissionless, one stock at a time, batched over holders.
    ///
    /// @param maxHolders How many holders to process this call. Zero means all remaining.
    /// @return moved     Tokens moved to POL by THIS call.
    /// @return complete  Whether the (round, stock) is now fully swept.
    ///
    /// @dev Emits a {CreditExpired} per holder so the site can show what each person lost.
    ///      NO LEDGER ENTRY IS MADE: an expired credit is forfeited, not compounded. The
    ///      opt-in `setAutoCompound` ledger is untouched and remains voluntary.
    function sweepExpired(uint256 roundId, address stock, uint256 maxHolders)
        public
        nonReentrant
        returns (uint256 moved, bool complete)
    {
        Schedule storage s = _schedules[roundId];
        if (s.finalizedAt == 0) revert RoundNotFinalized(roundId);
        if (block.timestamp <= s.expiresAt) revert NotExpiredYet(roundId, s.expiresAt);
        if (stockSwept[roundId][stock]) revert AlreadySwept(roundId, stock);
        if (polTreasury == address(0)) revert ZeroAddress();

        address[] storage list = _holders[roundId][stock];
        uint256 cursor = sweepCursor[roundId][stock];
        uint256 end = (maxHolders == 0 || cursor + maxHolders > list.length) ? list.length : cursor + maxHolders;

        for (uint256 i = cursor; i < end; ++i) {
            address owner = list[i];
            uint256 amount = claimable(roundId, stock, owner);
            if (amount == 0) continue; // already claimed, or nothing owed

            // Mark it taken so a holder can never be counted twice, even if the sweep is
            // re-run or interleaved with another batch.
            hasClaimed[roundId][stock][owner] = true;
            moved += amount;
            emit CreditExpired(roundId, stock, owner, amount);
        }

        sweepCursor[roundId][stock] = end;
        complete = end == list.length;

        if (complete) {
            // Settle rounding dust: per-holder shares are floored, so the sum can fall a
            // few units short of what the round actually still holds.
            uint256 accounted = sweptTotal[roundId][stock] + moved + claimedTotal[roundId][stock];
            uint256 total = acquired[roundId][stock];
            if (total > accounted) moved += total - accounted;
            stockSwept[roundId][stock] = true;
        }

        if (moved != 0) {
            sweptTotal[roundId][stock] += moved;
            totalOwed[stock] -= moved;
            IERC20(stock).safeTransfer(polTreasury, moved);
        }
        emit Swept(roundId, stock, moved, complete);
    }

    /// @notice Sweep every holder of a (round, stock) in one call.
    function sweepExpired(uint256 roundId, address stock) external returns (uint256 moved) {
        (moved,) = sweepExpired(roundId, stock, 0);
    }

    /* ------------------------------------------------------------------ */
    /*                          WINDOW SCHEDULE                             */
    /* ------------------------------------------------------------------ */

    function scheduleOf(uint256 roundId) external view returns (Schedule memory) {
        return _schedules[roundId];
    }

    function expiresAt(uint256 roundId) external view returns (uint64) {
        return _schedules[roundId].expiresAt;
    }

    function isFinalized(uint256 roundId) external view returns (bool) {
        return _schedules[roundId].finalizedAt != 0;
    }

    /// @notice Whether claims are open right now, under the CURRENT configuration.
    function isClaimOpen() public view returns (bool) {
        return _isOpenAt(uint64(block.timestamp), windowLength, windowOpenDuration);
    }

    /// @notice Whether claims are open for a specific round, under ITS frozen schedule.
    function isClaimOpenFor(uint256 roundId) external view returns (bool) {
        Schedule storage s = _schedules[roundId];
        if (s.finalizedAt == 0) return false;
        return _isOpenAt(uint64(block.timestamp), s.windowLengthAt, s.openDurationAt);
    }

    /// @notice When the current or next claim window opens and closes.
    function claimWindowState() public view returns (bool open, uint64 opensAt, uint64 closesAt) {
        return _windowStateAt(uint64(block.timestamp), windowLength, windowOpenDuration);
    }

    /// @notice The next moment claims open. Equals now if a window is already open.
    function nextWindowOpensAt() external view returns (uint64) {
        (bool open, uint64 opensAt,) = claimWindowState();
        return open ? uint64(block.timestamp) : opensAt;
    }

    /// @notice How many full claim windows a finalized round still has before it expires.
    function windowsRemaining(uint256 roundId) external view returns (uint256) {
        Schedule storage s = _schedules[roundId];
        if (s.finalizedAt == 0 || s.windowLengthAt == 0) return 0;
        if (block.timestamp >= s.expiresAt) return 0;
        return _openingsIn(uint64(block.timestamp), s.expiresAt, s.windowLengthAt);
    }

    /// @notice Full window openings a round was guaranteed when it was finalized.
    /// @dev Must always be at least {MIN_WINDOWS_BEFORE_EXPIRY}.
    function guaranteedWindows(uint256 roundId) public view returns (uint256) {
        Schedule storage s = _schedules[roundId];
        if (s.finalizedAt == 0 || s.windowLengthAt == 0) return 0;
        return _openingsIn(s.finalizedAt, s.expiresAt, s.windowLengthAt);
    }

    /// @notice Window openings strictly after `from` and at or before `to`, for cadence `w`.
    function openingsInFor(uint64 from, uint64 to, uint32 w) external view returns (uint256) {
        return _openingsIn(from, to, w);
    }

    function holders(uint256 roundId, address stock) external view returns (address[] memory) {
        return _holders[roundId][stock];
    }

    function holderCount(uint256 roundId, address stock) external view returns (uint256) {
        return _holders[roundId][stock].length;
    }

    /// @dev Number of window openings strictly after `from` and at or before `to`.
    function _openingsIn(uint64 from, uint64 to, uint32 w) internal view returns (uint256) {
        if (to <= from || w == 0) return 0;
        uint64 anchor = windowAnchor;
        uint256 toIdx = to <= anchor ? 0 : (uint256(to - anchor) / w) + 1;
        uint256 fromIdx = from <= anchor ? 0 : (uint256(from - anchor) / w) + 1;
        return toIdx > fromIdx ? toIdx - fromIdx : 0;
    }

    function _isOpenAt(uint64 ts, uint32 w, uint32 d) internal view returns (bool) {
        if (w == 0 || d == 0) return false;
        if (ts < windowAnchor) return false;
        if (d >= w) return true; // permanently open, a legal configuration
        return (uint256(ts - windowAnchor) % w) < d;
    }

    function _windowStateAt(uint64 ts, uint32 w, uint32 d)
        internal
        view
        returns (bool open, uint64 opensAt, uint64 closesAt)
    {
        if (w == 0 || d == 0) return (false, 0, 0);
        if (ts < windowAnchor) return (false, windowAnchor, windowAnchor + d);

        uint256 elapsed = uint256(ts - windowAnchor);
        uint256 into = elapsed % w;
        uint64 thisOpen = uint64(uint256(windowAnchor) + (elapsed - into));

        if (into < d || d >= w) return (true, thisOpen, uint64(uint256(thisOpen) + d));
        uint64 next = uint64(uint256(thisOpen) + w);
        return (false, next, uint64(uint256(next) + d));
    }

    /* ------------------------------------------------------------------ */
    /*                            GOVERNANCE                                */
    /* ------------------------------------------------------------------ */

    /// @notice Point at the round engine. Multisig only.
    /// @notice Wire the engine. Allowed ONCE, immediately, while `rounds` is unset.
    /// @dev The first wiring is not timelocked because at deploy there is nothing to protect
    ///      and a 48-hour gap would only leave a half-wired ledger exposed for longer. Every
    ///      later change goes through {queueRounds} / {executeRounds}.
    function setRounds(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        if (rounds != address(0)) revert AlreadyWired();
        emit RoundsUpdated(rounds, v);
        rounds = v;
    }

    /// @notice Queue a change of engine. Multisig only, 48h notice.
    ///
    /// @dev TIMELOCKED BECAUSE `rounds` IS THE MOST POWERFUL ADDRESS THIS LEDGER KNOWS.
    ///      Whatever sits here may write weights, and weight is the numerator of every claim:
    ///      `claimable = acquired * weightOf / totalWeight`. A hostile engine cannot conjure
    ///      stock — `recordAcquired` verifies against this contract's own balance — and it
    ///      cannot touch a finalized round, because both write paths refuse one. But against
    ///      a round that is still open it could mint itself weight and dilute the holders who
    ///      earned it.
    ///
    ///      48 hours is longer than a round lives, so any round a retarget could have
    ///      attacked has finalized and become claimable before the change binds. Raised by
    ///      external review as EXT-C-H-1; see `test/ChipClaimsGovernance.t.sol`.
    function queueRounds(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        _pendingRounds =
            PendingAddress({queued: true, executableAt: uint64(block.timestamp) + CONFIG_TIMELOCK, target: v});
        emit RoundsQueued(v, uint64(block.timestamp) + CONFIG_TIMELOCK);
    }

    function executeRounds() external onlyOwner {
        PendingAddress memory p = _pendingRounds;
        if (!p.queued) revert NothingQueued();
        if (block.timestamp < p.executableAt) revert TimelockNotElapsed(uint64(block.timestamp), p.executableAt);
        emit RoundsUpdated(rounds, p.target);
        rounds = p.target;
        delete _pendingRounds;
    }

    function cancelRounds() external onlyOwner {
        if (!_pendingRounds.queued) revert NothingQueued();
        delete _pendingRounds;
        emit RetargetCancelled();
    }

    function pendingRounds() external view returns (PendingAddress memory) {
        return _pendingRounds;
    }

    /// @notice Wire the POL treasury. Allowed ONCE, immediately, while it is unset.
    function setPolTreasury(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        if (polTreasury != address(0)) revert AlreadyWired();
        emit PolTreasuryUpdated(polTreasury, v);
        polTreasury = v;
    }

    /// @notice Queue a change of POL treasury. Multisig only, 48h notice.
    /// @dev Timelocked for the same reason as {queueRounds}, one step removed: `sweepExpired`
    ///      sends forfeited credits here, so retargeting it diverts real value. Forfeited
    ///      credits are already lost to their holder (C-19), which makes this lower stakes
    ///      than the engine — but "lower stakes" is not "no stakes", and the pattern is free.
    function queuePolTreasury(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        _pendingPol = PendingAddress({queued: true, executableAt: uint64(block.timestamp) + CONFIG_TIMELOCK, target: v});
        emit PolTreasuryQueued(v, uint64(block.timestamp) + CONFIG_TIMELOCK);
    }

    function executePolTreasury() external onlyOwner {
        PendingAddress memory p = _pendingPol;
        if (!p.queued) revert NothingQueued();
        if (block.timestamp < p.executableAt) revert TimelockNotElapsed(uint64(block.timestamp), p.executableAt);
        emit PolTreasuryUpdated(polTreasury, p.target);
        polTreasury = p.target;
        delete _pendingPol;
    }

    function cancelPolTreasury() external onlyOwner {
        if (!_pendingPol.queued) revert NothingQueued();
        delete _pendingPol;
        emit RetargetCancelled();
    }

    function pendingPolTreasury() external view returns (PendingAddress memory) {
        return _pendingPol;
    }

    /// @notice Set the claim cadence and how long each window stays open. Multisig only.
    function setClaimSchedule(uint32 newWindowLength, uint32 newOpenDuration) external onlyOwner {
        _requireScheduleSane(newWindowLength, newOpenDuration, creditExpiry);
        windowLength = newWindowLength;
        windowOpenDuration = newOpenDuration;
        emit ClaimScheduleUpdated(newWindowLength, newOpenDuration, creditExpiry);
    }

    /// @notice Set how long credits survive before they can be swept. Multisig only.
    function setCreditExpiry(uint64 newExpiry) external onlyOwner {
        _requireScheduleSane(windowLength, windowOpenDuration, newExpiry);
        creditExpiry = newExpiry;
        emit ClaimScheduleUpdated(windowLength, windowOpenDuration, newExpiry);
    }

    /// @dev THE SCHEDULE RULE. Every accepted configuration must guarantee a round at least
    ///      {MIN_WINDOWS_BEFORE_EXPIRY} full claim windows before its credits can be swept.
    ///      Openings fall on a fixed cadence, so an interval of length `expiry` always
    ///      contains at least `floor(expiry / windowLength)` of them; requiring
    ///      `expiry >= MIN * windowLength` therefore makes the guarantee unconditional,
    ///      whatever moment a round happens to finalize at.
    function _requireScheduleSane(uint32 w, uint32 d, uint64 expiry) internal pure {
        if (w < MIN_WINDOW_LENGTH || w > MAX_WINDOW_LENGTH) revert BadConfig();
        if (d < MIN_OPEN_DURATION || d > w) revert BadConfig();
        if (expiry > MAX_CREDIT_EXPIRY) revert BadConfig();
        if (expiry < MIN_WINDOWS_BEFORE_EXPIRY * uint256(w)) revert BadConfig();
    }

    /* ------------------------------------------------------------------ */
    /*                              RESCUE                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Token balance not backing any live claim.
    function excess(address token) public view returns (uint256) {
        uint256 balance = _balanceOf(token, address(this));
        uint256 owed = totalOwed[token];
        return balance > owed ? balance - owed : 0;
    }

    /// @notice Recover only tokens provably in excess of every unexpired claim.
    /// @dev THE INVARIANT: this can never reduce the balance below `totalOwed`. Checked
    ///      before the transfer and again afterwards against the real balance.
    function recoverExcess(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 avail = excess(token);
        if (amount == 0 || amount > avail) revert InsufficientExcess(token, amount, avail);

        IERC20(token).safeTransfer(to, amount);

        if (_balanceOf(token, address(this)) < totalOwed[token]) revert Insolvent(token);
        emit ExcessRecovered(token, to, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                             INTERNALS                                */
    /* ------------------------------------------------------------------ */

    function _usdValue(address token, uint256 amount) internal view returns (uint256) {
        if (token == quoteToken) return (amount * 1e18) / (10 ** registry.quoteDecimals());
        try registry.priceUsd(token) returns (uint256 price1e18, uint256) {
            return (amount * price1e18) / (10 ** registry.getStock(token).tokenDecimals);
        } catch {
            return 0;
        }
    }

    /// @dev Gas-capped balance read. See ASSUMPTIONS.md A-17.
    function _balanceOf(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC20.balanceOf, (who)));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }
}
