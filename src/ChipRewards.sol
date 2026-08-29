// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IStockRegistry, Stock, Venue} from "./interfaces/IStockRegistry.sol";
import {IActivationSource} from "./interfaces/IActivationSource.sol";
import {IPot} from "./interfaces/IPot.sol";
import {IUniswapV3SwapRouter, ISlipstreamSwapRouter} from "./interfaces/ISwapRouters.sol";

/// @title ChipRewards
/// @notice The rewards layer. Every 24h it takes a budget from the Pot, works out how much
///         each activated Noun is owed based on its Clutch tier, its collection and its
///         chosen stock split, buys those stocks, and credits the results to owner
///         addresses so a later NFT sale never strands earned stock.
///
/// @dev ARCHITECTURE NOTES — read these before changing anything.
///
///      NO MASTERCHEF ACCUMULATOR, DELIBERATELY. The spec asks for one, but an accumulator
///      cannot express "this credit expires 90 days after round 42" — it has no memory of
///      which round a credit came from, so per-round expiry would need a second structure
///      anyway. Accumulators also exist to avoid iterating holders, and we must iterate
///      regardless because the Clutch vault cannot enumerate activated tokens
///      (ASSUMPTIONS A-10). So instead this stores per-round WEIGHT SHARES, and converts
///      them to token amounts lazily at claim time:
///
///          claimable = acquired[round][stock] * weight[round][stock][you]
///                                             / totalWeight[round][stock]
///
///      One structure, exact per-round expiry, exact sweeps, no second iteration.
///
///      EVERYTHING IS PER-STOCK AND PERMISSIONLESS, SO FAILURES STAY ISOLATED. Buying is
///      one call per stock and claiming is one call per (round, stock). A stock that is
///      frozen, paused or policy-blocked by its issuer therefore fails only its own call.
///      Other stocks in the same round still buy, still claim, still sweep. This is the
///      single most important safety property in the contract and it is a structural
///      consequence of the shape, not a check anyone has to remember.
///
///      ROUNDS ARE FILLED PERMISSIONLESSLY. `contributeWeights` can be called by anyone for
///      anyone's Nouns, and the round cannot close until `accumulationWindow` has passed.
///      That combination is what stops a griefer opening a round, adding only their own
///      Noun and closing it: anybody left out can add themselves before the window ends.
contract ChipRewards is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    /// @notice Gas cap on calls into foreign contracts (hoodie collection, stock tokens).
    /// @dev See ASSUMPTIONS.md A-17: a precompile or hostile contract that fails with an
    ///      invalid opcode consumes all forwarded gas unless capped.
    uint256 public constant PROBE_GAS = 100_000;

    /// @notice Minimum number of full claim windows a round must offer before it expires.
    /// @dev Enforced on every config setter. This is the guarantee that a holder always has
    ///      several separate chances to claim, no matter how the windows are tuned. See
    ///      {_requireScheduleSane} and the config invariant in the test suite.
    uint256 public constant MIN_WINDOWS_BEFORE_EXPIRY = 3;

    uint32 public constant MIN_WINDOW_LENGTH = 1 days;
    uint32 public constant MAX_WINDOW_LENGTH = 30 days;
    uint32 public constant MIN_OPEN_DURATION = 1 hours;
    uint32 public constant MAX_CREDIT_EXPIRY = 365 days;

    /// @notice Hard ceiling on the POL holdback. Spec section 6 allows 0-25%.
    /// @dev Immutable so the multisig can tune the holdback but can never redirect an
    ///      arbitrary share of every round away from holders.
    uint32 public constant MAX_HOLDBACK_BPS = 2_500;

    enum RoundState {
        None,
        Accumulating,
        Buying,
        Finalized
    }

    struct Round {
        RoundState state;
        uint64 openedAt;
        uint64 finalizedAt;
        uint128 budget; // quote-token budget taken from the Pot
        uint128 spent; // quote token actually deployed
        uint256 totalWeight; // sum of all per-stock weights in this round
        // --- claim schedule, FROZEN at finalize ---
        uint64 expiresAt; // after this, credits are sweepable to POL
        uint32 windowLengthAt; // cadence this round was finalized under
        uint32 openDurationAt; // how long each of its windows stays open
    }

    struct Split {
        bool set;
        uint8 count;
        address[3] stocks;
        uint8[3] pcts;
    }

    /* ----------------------------- wiring ----------------------------- */

    IStockRegistry public immutable registry;
    address public immutable quoteToken;
    IPot public pot;
    IActivationSource public activationSource;
    address public polTreasury;
    address public chipToken;
    address public chipBurnAddress;

    IUniswapV3SwapRouter public uniswapRouter;
    ISlipstreamSwapRouter public slipstreamRouter;

    /* --------------------------- tunables ----------------------------- */

    uint64 public roundDuration; // 24h
    uint64 public accumulationWindow; // minimum time a round stays open for contributions
    uint32 public windowLength; // claims unlock on this cycle
    uint32 public windowOpenDuration; // and stay open this long each time
    uint64 public creditExpiry; // after this long, unclaimed credits sweep to POL
    uint128 public minPotToOpen; // $250 in quote units
    uint128 public maxRoundBudget; // $10k in quote units
    uint256 public splitChangeFeeChip; // flat $CHIP burn to change a split
    uint32 public defaultMaxSlippageBps; // min-out bound around the Chainlink mark
    uint32 public boostBps; // hoodie boost, e.g. 11_000 == 1.10x
    uint32 public holdbackBps; // share of each purchase routed to POL, 0-25%
    address public hoodieCollection;

    mapping(address collection => uint32 bps) public collectionBaseBps;
    mapping(address stock => uint32 bps) internal _maxSlippageBpsOverride;

    /* ----------------------------- state ------------------------------ */

    uint256 public roundCount;
    uint64 public lastRoundOpenedAt;
    uint256 public totalPaidUsd; // 18-decimal USD, marked at Chainlink at finalize time

    mapping(uint256 roundId => Round) internal _rounds;
    mapping(uint256 roundId => address[]) internal _roundStocks;
    mapping(uint256 roundId => mapping(address stock => bool)) internal _roundHasStock;

    mapping(uint256 roundId => mapping(address stock => uint256)) public totalWeight;
    mapping(uint256 roundId => mapping(address stock => mapping(address owner => uint256))) public weightOf;
    mapping(uint256 roundId => mapping(address stock => uint256)) public acquired;
    mapping(uint256 roundId => mapping(address stock => uint256)) public claimedTotal;
    mapping(uint256 roundId => mapping(address stock => bool)) public stockSkipped;
    mapping(uint256 roundId => mapping(address stock => bool)) public stockSettled;
    mapping(uint256 roundId => mapping(address stock => bool)) public stockSwept;
    mapping(uint256 roundId => mapping(address stock => mapping(address owner => bool))) public hasClaimed;
    mapping(uint256 roundId => mapping(address collection => mapping(uint256 tokenId => bool))) public counted;

    mapping(address collection => mapping(uint256 tokenId => Split)) internal _splits;
    mapping(address owner => bool) public autoCompound;
    mapping(address owner => uint256) public polCreditUsd;

    /// @notice Token units this contract owes to claimants across every unexpired round.
    /// @dev The rescue function can never touch this. See {recoverExcess}.
    mapping(address token => uint256) public totalOwed;

    /// @notice Timestamp all claim windows are counted from. Set at deploy, never changeable.
    /// @dev Immutable on purpose: if governance could move the anchor it could slide the
    ///      windows forward indefinitely and block claims without ever changing a duration.
    uint64 public immutable windowAnchor;

    /// @notice Everyone credited in a (round, stock), in credit order. Used to emit
    ///         per-holder amounts when a round expires.
    mapping(uint256 roundId => mapping(address stock => address[])) internal _holders;

    /// @notice How far through `_holders` an expiry sweep has got. Sweeps are batched.
    mapping(uint256 roundId => mapping(address stock => uint256)) public sweepCursor;

    /// @notice Total already swept out of a (round, stock), excluding the final dust.
    mapping(uint256 roundId => mapping(address stock => uint256)) public sweptTotal;

    /// @notice Quote token pulled from the Pot for rounds that have not finished yet.
    /// @dev Not yet anyone's credit, but already committed to holders, so the rescue must
    ///      not be able to reach it. Found by the solvency invariant: without this, the
    ///      multisig could pull a live round's unspent budget and a later settlement would
    ///      then credit money the contract no longer held.
    uint256 public committedQuote;

    /* ----------------------------- events ----------------------------- */

    event RoundOpened(uint256 indexed roundId, uint256 budget, address indexed opener);
    event WeightsContributed(uint256 indexed roundId, address indexed collection, uint256 count, uint256 weightAdded);
    event AccumulationClosed(uint256 indexed roundId, uint256 totalWeight);
    event StockBought(uint256 indexed roundId, address indexed stock, uint256 spent, uint256 received);
    event HoldbackSent(uint256 indexed roundId, address indexed stock, uint256 amount);
    /// @dev The swap consumed input but delivered less than the Chainlink-derived floor.
    ///      A well-behaved router cannot do this; a misbehaving token can. Loud on purpose.
    event StockUnderdelivered(uint256 indexed roundId, address indexed stock, uint256 spent, uint256 received);
    event StockSkipped(uint256 indexed roundId, address indexed stock, uint256 wouldHaveSpent, bytes reason);
    event RoundFinalized(uint256 indexed roundId, uint256 spent, uint256 returned, uint256 valueUsd);
    event Claimed(uint256 indexed roundId, address indexed stock, address indexed owner, uint256 amount);
    event Compounded(uint256 indexed roundId, address indexed stock, address indexed owner, uint256 amount);
    event Swept(uint256 indexed roundId, address indexed stock, uint256 amount, bool complete);
    /// @dev One per holder whose credit expired, so the site can show exactly what was lost.
    event CreditExpired(uint256 indexed roundId, address indexed stock, address indexed owner, uint256 amount);
    event ClaimScheduleUpdated(uint32 windowLength, uint32 openDuration, uint64 creditExpiry);
    event SplitSet(address indexed collection, uint256 indexed tokenId, address[3] stocks, uint8[3] pcts, uint256 fee);
    event AutoCompoundSet(address indexed owner, bool enabled);
    event ExcessRecovered(address indexed token, address indexed to, uint256 amount);
    event ConfigUpdated(bytes32 indexed key, uint256 value);
    event AddressUpdated(bytes32 indexed key, address value);

    /* ----------------------------- errors ----------------------------- */

    error ZeroAddress();
    error TooSoon(uint64 nowTs, uint64 openableAt);
    error PotTooSmall(uint256 available, uint256 required);
    error WrongState(uint256 roundId, RoundState actual, RoundState expected);
    error AccumulationStillOpen(uint64 nowTs, uint64 closesAt);
    error NoWeight(uint256 roundId);
    error BadSplit();
    error StockNotEnabled(address stock);
    error NotNounOwner(address caller);
    error AlreadyClaimed(uint256 roundId, address stock, address owner);
    error NothingToClaim();
    error CreditsExpired(uint256 roundId, uint64 expiredAt);
    /// @dev Carries the next opening so a caller (or the site) knows exactly when to return.
    error ClaimsClosed(uint64 nowTs, uint64 nextOpenAt);
    error NotExpiredYet(uint256 roundId, uint64 expiresAt);
    error AlreadySettled(uint256 roundId, address stock);
    error NotSettled(uint256 roundId, address stock);
    error AlreadySwept(uint256 roundId, address stock);
    error InsufficientExcess(address token, uint256 requested, uint256 available);
    error Insolvent(address token);
    error BadConfig();

    /// @param multisig            Owner.
    /// @param registry_           StockRegistry.
    /// @param pot_                Pot.
    /// @param source_             Activation source (the Clutch adapter).
    /// @param splitChangeFeeChip_ Flat $CHIP burned to change an already-set split. The
    ///                            first split is always free. Spec value is 5,000 CHIP,
    ///                            10% of a base activation: cheap enough not to punish a
    ///                            genuine re-pick, dear enough that flipping weekly to
    ///                            chase the cheapest stock costs more than it gains.
    constructor(address multisig, address registry_, address pot_, address source_, uint256 splitChangeFeeChip_)
        Ownable(multisig)
    {
        if (multisig == address(0) || registry_ == address(0) || pot_ == address(0) || source_ == address(0)) {
            revert ZeroAddress();
        }
        registry = IStockRegistry(registry_);
        quoteToken = IStockRegistry(registry_).quoteToken();
        pot = IPot(pot_);
        activationSource = IActivationSource(source_);

        // Spec defaults. Every one of these is changeable by the multisig; none is a constant.
        roundDuration = 24 hours;
        accumulationWindow = 2 hours;
        windowAnchor = uint64(block.timestamp);
        windowLength = 7 days;
        windowOpenDuration = 48 hours;
        creditExpiry = 30 days;
        defaultMaxSlippageBps = 200; // 2%
        boostBps = 11_000; // 1.10x
        splitChangeFeeChip = splitChangeFeeChip_;
    }

    /* ------------------------------------------------------------------ */
    /*                            GOVERNANCE                                */
    /* ------------------------------------------------------------------ */

    function setPot(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        pot = IPot(v);
        emit AddressUpdated("pot", v);
    }

    function setActivationSource(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        activationSource = IActivationSource(v);
        emit AddressUpdated("activationSource", v);
    }

    function setPolTreasury(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        polTreasury = v;
        emit AddressUpdated("polTreasury", v);
    }

    function setChip(address token, address burnAddress) external onlyOwner {
        chipToken = token;
        chipBurnAddress = burnAddress;
        emit AddressUpdated("chipToken", token);
        emit AddressUpdated("chipBurnAddress", burnAddress);
    }

    function setRouters(address uni, address slip) external onlyOwner {
        uniswapRouter = IUniswapV3SwapRouter(uni);
        slipstreamRouter = ISlipstreamSwapRouter(slip);
        emit AddressUpdated("uniswapRouter", uni);
        emit AddressUpdated("slipstreamRouter", slip);
    }

    function setHoodie(address collection, uint32 bps) external onlyOwner {
        if (bps != 0 && bps < BPS) revert BadConfig();
        hoodieCollection = collection;
        boostBps = bps;
        emit AddressUpdated("hoodieCollection", collection);
        emit ConfigUpdated("boostBps", bps);
    }

    function setCollectionBaseBps(address collection, uint32 bps) external onlyOwner {
        if (collection == address(0)) revert ZeroAddress();
        collectionBaseBps[collection] = bps;
        emit ConfigUpdated(bytes32(uint256(uint160(collection))), bps);
    }

    function setRoundParams(uint64 duration, uint64 window, uint128 minPot, uint128 maxBudget) external onlyOwner {
        if (duration == 0 || window >= duration || maxBudget == 0) revert BadConfig();
        roundDuration = duration;
        accumulationWindow = window;
        minPotToOpen = minPot;
        maxRoundBudget = maxBudget;
        emit ConfigUpdated("roundDuration", duration);
        emit ConfigUpdated("accumulationWindow", window);
        emit ConfigUpdated("minPotToOpen", minPot);
        emit ConfigUpdated("maxRoundBudget", maxBudget);
    }

    /// @notice Set the claim cadence and how long each window stays open. Multisig only.
    function setClaimSchedule(uint32 newWindowLength, uint32 newOpenDuration) external onlyOwner {
        _requireScheduleSane(newWindowLength, newOpenDuration, creditExpiry);
        windowLength = newWindowLength;
        windowOpenDuration = newOpenDuration;
        emit ClaimScheduleUpdated(newWindowLength, newOpenDuration, creditExpiry);
    }

    /// @notice Set how long credits survive before they can be swept to POL. Multisig only.
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

    function setSplitChangeFeeChip(uint256 v) external onlyOwner {
        splitChangeFeeChip = v;
        emit ConfigUpdated("splitChangeFeeChip", v);
    }

    function setMaxSlippageBps(address stock, uint32 bps) external onlyOwner {
        if (bps >= BPS) revert BadConfig();
        _maxSlippageBpsOverride[stock] = bps;
        emit ConfigUpdated(bytes32(uint256(uint160(stock))), bps);
    }

    /// @notice Share of each stock purchase held back for protocol-owned liquidity.
    /// @dev Bounded by {MAX_HOLDBACK_BPS}. Spec section 6 says announce changes.
    function setHoldbackBps(uint32 bps) external onlyOwner {
        if (bps > MAX_HOLDBACK_BPS) revert BadConfig();
        holdbackBps = bps;
        emit ConfigUpdated("holdbackBps", bps);
    }

    function setDefaultMaxSlippageBps(uint32 bps) external onlyOwner {
        if (bps >= BPS) revert BadConfig();
        defaultMaxSlippageBps = bps;
        emit ConfigUpdated("defaultMaxSlippageBps", bps);
    }

    /// @notice Effective slippage bound for a stock: its override, else the default.
    function maxSlippageBps(address stock) public view returns (uint32) {
        uint32 o = _maxSlippageBpsOverride[stock];
        return o == 0 ? defaultMaxSlippageBps : o;
    }

    /* ------------------------------------------------------------------ */
    /*                              SPLITS                                  */
    /* ------------------------------------------------------------------ */

    function splitOf(address collection, uint256 tokenId) external view returns (Split memory) {
        return _splits[collection][tokenId];
    }

    /// @notice Choose up to three stocks and the whole-percent split between them.
    /// @dev Callable by the Noun's current owner. The first set is free; every later change
    ///      burns a flat amount of $CHIP, which is what stops split-flipping right before
    ///      a round to chase whichever stock happens to be cheapest.
    function setSplit(address collection, uint256 tokenId, address[] calldata stocks, uint8[] calldata pcts)
        external
        nonReentrant
    {
        if (IERC721(collection).ownerOf(tokenId) != msg.sender) revert NotNounOwner(msg.sender);
        if (stocks.length == 0 || stocks.length > 3 || stocks.length != pcts.length) revert BadSplit();

        uint256 sum;
        address[3] memory s;
        uint8[3] memory p;
        for (uint256 i; i < stocks.length; ++i) {
            if (pcts[i] == 0) revert BadSplit();
            if (!registry.isEnabled(stocks[i])) revert StockNotEnabled(stocks[i]);
            for (uint256 j; j < i; ++j) {
                if (stocks[j] == stocks[i]) revert BadSplit();
            }
            s[i] = stocks[i];
            p[i] = pcts[i];
            sum += pcts[i];
        }
        if (sum != 100) revert BadSplit();

        Split storage existing = _splits[collection][tokenId];
        uint256 fee;
        if (existing.set && splitChangeFeeChip != 0 && chipToken != address(0)) {
            fee = splitChangeFeeChip;
            IERC20(chipToken).safeTransferFrom(msg.sender, chipBurnAddress, fee);
        }

        _splits[collection][tokenId] = Split({set: true, count: uint8(stocks.length), stocks: s, pcts: p});
        emit SplitSet(collection, tokenId, s, p, fee);
    }

    function setAutoCompound(bool enabled) external {
        autoCompound[msg.sender] = enabled;
        emit AutoCompoundSet(msg.sender, enabled);
    }

    /* ------------------------------------------------------------------ */
    /*                              ROUNDS                                  */
    /* ------------------------------------------------------------------ */

    function getRound(uint256 roundId) external view returns (Round memory) {
        return _rounds[roundId];
    }

    function roundStocks(uint256 roundId) external view returns (address[] memory) {
        return _roundStocks[roundId];
    }

    /// @notice When a new round may be opened.
    function nextRoundOpensAt() public view returns (uint64) {
        return lastRoundOpenedAt == 0 ? uint64(block.timestamp) : lastRoundOpenedAt + roundDuration;
    }

    /// @notice Open the next 24h round. Permissionless: site button, keeper bot, anyone.
    function openRound() external nonReentrant returns (uint256 roundId) {
        uint64 openableAt = nextRoundOpensAt();
        if (block.timestamp < openableAt) revert TooSoon(uint64(block.timestamp), openableAt);

        uint256 availableInPot = pot.available();
        if (availableInPot < minPotToOpen) revert PotTooSmall(availableInPot, minPotToOpen);

        uint256 want = availableInPot > maxRoundBudget ? maxRoundBudget : availableInPot;
        uint256 got = pot.pullBudget(want);

        roundId = ++roundCount;
        _rounds[roundId] = Round({
            state: RoundState.Accumulating,
            openedAt: uint64(block.timestamp),
            finalizedAt: 0,
            budget: uint128(got),
            spent: 0,
            totalWeight: 0,
            expiresAt: 0,
            windowLengthAt: 0,
            openDurationAt: 0
        });
        lastRoundOpenedAt = uint64(block.timestamp);
        committedQuote += got;

        emit RoundOpened(roundId, got, msg.sender);
    }

    /// @notice Add Nouns to the open round. Permissionless and batched.
    /// @dev Anyone may submit anyone's token ids; the contract verifies each one against
    ///      the activation source, so a padded or wrong list cannot inflate a share.
    function contributeWeights(uint256 roundId, address collection, uint256[] calldata tokenIds) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Accumulating) revert WrongState(roundId, r.state, RoundState.Accumulating);

        uint256 added;
        uint256 accepted;
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            if (counted[roundId][collection][tokenId]) continue;

            (bool active, uint32 tierBps, address owner) = activationSource.activation(collection, tokenId);
            if (!active || owner == address(0)) continue;

            uint256 weight = _weight(collection, tierBps, owner);
            if (weight == 0) continue;

            counted[roundId][collection][tokenId] = true;
            added += _allocate(roundId, collection, tokenId, owner, weight);
            ++accepted;
        }
        r.totalWeight += added;
        emit WeightsContributed(roundId, collection, accepted, added);
    }

    /// @dev weight = tier x collectionBase x boost, all in basis points.
    function _weight(address collection, uint32 tierBps, address owner) internal view returns (uint256) {
        uint256 base = collectionBaseBps[collection];
        if (base == 0) return 0;
        uint256 w = (uint256(tierBps) * base) / BPS;
        if (_hasHoodie(owner)) w = (w * boostBps) / BPS;
        return w;
    }

    /// @dev Read live rather than from a poked cache: always correct, one less stale-state
    ///      bug class, and no keeper dependency. Gas-capped so a broken hoodie contract
    ///      cannot wedge a round. See ASSUMPTIONS C-6.
    function _hasHoodie(address owner) internal view returns (bool) {
        address h = hoodieCollection;
        if (h == address(0) || boostBps <= BPS) return false;
        (bool ok, bytes memory ret) = h.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC721.balanceOf, (owner)));
        if (!ok || ret.length < 32) return false;
        return abi.decode(ret, (uint256)) > 0;
    }

    /// @dev Books a Noun's weight across its chosen stocks. A Noun with no split, or whose
    ///      chosen stock has since been disabled, routes that slice to the quote token,
    ///      exactly as the spec's "existing slices route to USDC until re-picked".
    function _allocate(uint256 roundId, address collection, uint256 tokenId, address owner, uint256 weight)
        internal
        returns (uint256 added)
    {
        Split storage sp = _splits[collection][tokenId];

        if (!sp.set) {
            _credit(roundId, quoteToken, owner, weight);
            return weight;
        }

        for (uint256 i; i < sp.count; ++i) {
            uint256 slice = (weight * sp.pcts[i]) / 100;
            if (slice == 0) continue;
            address stock = registry.isEnabled(sp.stocks[i]) ? sp.stocks[i] : quoteToken;
            _credit(roundId, stock, owner, slice);
            added += slice;
        }
    }

    function _credit(uint256 roundId, address stock, address owner, uint256 weight) internal {
        if (!_roundHasStock[roundId][stock]) {
            _roundHasStock[roundId][stock] = true;
            _roundStocks[roundId].push(stock);
        }
        // First credit for this holder in this (round, stock): remember them so the expiry
        // sweep can emit exactly what each person lost.
        if (weightOf[roundId][stock][owner] == 0) _holders[roundId][stock].push(owner);
        weightOf[roundId][stock][owner] += weight;
        totalWeight[roundId][stock] += weight;
    }

    /// @notice Everyone credited in a (round, stock).
    function holders(uint256 roundId, address stock) external view returns (address[] memory) {
        return _holders[roundId][stock];
    }

    function holderCount(uint256 roundId, address stock) public view returns (uint256) {
        return _holders[roundId][stock].length;
    }

    /// @notice Close contributions and move the round to buying. Permissionless, but only
    ///         after `accumulationWindow`, so nobody can close a round out from under the
    ///         Nouns that have not been submitted yet.
    function closeAccumulation(uint256 roundId) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Accumulating) revert WrongState(roundId, r.state, RoundState.Accumulating);
        uint64 closesAt = r.openedAt + accumulationWindow;
        if (block.timestamp < closesAt) revert AccumulationStillOpen(uint64(block.timestamp), closesAt);
        if (r.totalWeight == 0) revert NoWeight(roundId);

        r.state = RoundState.Buying;
        emit AccumulationClosed(roundId, r.totalWeight);
    }

    /// @notice Buy one stock for a round. Permissionless, one stock per call.
    /// @dev ONE CALL PER STOCK IS THE ISOLATION MECHANISM. A stock whose token is frozen,
    ///      paused or policy-blocked fails only this call; every other stock in the round
    ///      proceeds. The failed stock is marked skipped and its budget slice is carried
    ///      back to the Pot at finalize, exactly as the spec requires for excess impact.
    function settleStock(uint256 roundId, address stock) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Buying) revert WrongState(roundId, r.state, RoundState.Buying);
        if (stockSettled[roundId][stock]) revert AlreadySettled(roundId, stock);

        uint256 stockWeight = totalWeight[roundId][stock];
        if (stockWeight == 0) revert NoWeight(roundId);

        stockSettled[roundId][stock] = true;
        uint256 slice = (uint256(r.budget) * stockWeight) / r.totalWeight;
        if (slice == 0) {
            stockSkipped[roundId][stock] = true;
            emit StockSkipped(roundId, stock, 0, "zero slice");
            return;
        }

        // The quote token needs no swap: credit it straight through.
        if (stock == quoteToken) {
            acquired[roundId][stock] = slice;
            totalOwed[stock] += slice;
            committedQuote -= slice;
            r.spent += uint128(slice);
            emit StockBought(roundId, stock, slice, slice);
            return;
        }

        (bool executed, uint256 received, uint256 quoteSpent, bytes memory reason) = _buy(stock, slice);

        // Not executed means the swap reverted atomically: nothing left the contract, so
        // the slice is untouched and carries to the next round.
        if (!executed) {
            stockSkipped[roundId][stock] = true;
            emit StockSkipped(roundId, stock, slice, reason);
            return;
        }

        // Executed. Book what ACTUALLY moved in both directions, never the intent. A swap
        // that consumed the input but under-delivered is a real loss that has already
        // happened; recording it as a skip would leave the round claiming to hold quote
        // token it no longer has, and finalizeRound would then be unable to return the
        // balance to the Pot. Found by the lying-token test.
        uint256 heldBack = _sendHoldback(stock, received);
        uint256 credited = received - heldBack;

        acquired[roundId][stock] = credited;
        totalOwed[stock] += credited;
        committedQuote -= quoteSpent;
        r.spent += uint128(quoteSpent);

        emit StockBought(roundId, stock, quoteSpent, credited);
        if (heldBack != 0) emit HoldbackSent(roundId, stock, heldBack);
        if (received < _minOutFor(stock, quoteSpent)) {
            emit StockUnderdelivered(roundId, stock, quoteSpent, received);
        }
    }

    /// @dev Moves the POL share of a purchase to the treasury and reports how much
    ///      ACTUALLY left, measured by balance delta rather than trusted from a return
    ///      value. A token that lies about transferring, or refuses because the treasury is
    ///      policy-blocked, simply results in a smaller (or zero) holdback and a larger
    ///      credit to holders. It can never make the round fail, and it can never cause the
    ///      contract to credit stock it does not hold.
    function _sendHoldback(address stock, uint256 received) internal returns (uint256 moved) {
        uint32 bps = holdbackBps;
        address treasury = polTreasury;
        if (bps == 0 || treasury == address(0) || received == 0) return 0;

        uint256 target = (received * bps) / BPS;
        if (target == 0) return 0;

        uint256 before = _balanceOf(stock, address(this));
        (bool ok,) = stock.call(abi.encodeCall(IERC20.transfer, (treasury, target)));
        if (!ok) return 0;
        uint256 remaining = _balanceOf(stock, address(this));
        moved = before > remaining ? before - remaining : 0;
        if (moved > target) moved = target;
    }

    /// @dev Buys `stock` with `spendAmount` of quote token, bounded by the Chainlink mark.
    ///      Returns ok=false rather than reverting so the caller can skip and carry.
    /// @notice Chainlink-derived minimum acceptable output for spending `spendAmount`.
    /// @dev Returns 0 when the price is unavailable, so callers treat it as "no floor".
    function _minOutFor(address stock, uint256 spendAmount) internal view returns (uint256) {
        uint8 dec = registry.getStock(stock).tokenDecimals;
        uint256 price1e18;
        try registry.priceUsd(stock) returns (uint256 p, uint256) {
            price1e18 = p;
        } catch {
            return 0;
        }
        if (price1e18 == 0) return 0;
        uint256 spendUsd = (spendAmount * 1e18) / (10 ** registry.quoteDecimals());
        uint256 expectedOut = (spendUsd * (10 ** dec)) / price1e18;
        return (expectedOut * (BPS - maxSlippageBps(stock))) / BPS;
    }

    /// @dev Buys `stock` with up to `spendAmount` of quote token, bounded by the Chainlink
    ///      mark. Reports whether the swap EXECUTED, and how much actually moved in each
    ///      direction, measured by balance deltas rather than trusted from return values.
    ///      `executed == false` means the call reverted atomically and nothing moved.
    function _buy(address stock, uint256 spendAmount)
        internal
        returns (bool executed, uint256 received, uint256 quoteSpent, bytes memory why)
    {
        Stock memory s = registry.getStock(stock);
        if (!s.enabled) return (false, 0, 0, "stock disabled");

        uint256 minOut = _minOutFor(stock, spendAmount);
        if (minOut == 0) return (false, 0, 0, "no price");

        address router = s.venue == Venue.UniswapV3
            ? address(uniswapRouter)
            : (s.venue == Venue.Slipstream ? address(slipstreamRouter) : address(0));
        if (router == address(0)) return (false, 0, 0, "no router");

        uint256 stockBefore = _balanceOf(stock, address(this));
        uint256 quoteBefore = _balanceOf(quoteToken, address(this));

        IERC20(quoteToken).forceApprove(router, spendAmount);

        bool ok;
        if (s.venue == Venue.UniswapV3) {
            try uniswapRouter.exactInputSingle(
                IUniswapV3SwapRouter.ExactInputSingleParams({
                    tokenIn: quoteToken,
                    tokenOut: stock,
                    fee: s.fee,
                    recipient: address(this),
                    amountIn: spendAmount,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            ) {
                ok = true;
            } catch (bytes memory err) {
                why = err.length == 0 ? bytes("swap failed") : err;
            }
        } else {
            try slipstreamRouter.exactInputSingle(
                ISlipstreamSwapRouter.ExactInputSingleParams({
                    tokenIn: quoteToken,
                    tokenOut: stock,
                    tickSpacing: s.tickSpacing,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: spendAmount,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            ) {
                ok = true;
            } catch (bytes memory err) {
                why = err.length == 0 ? bytes("swap failed") : err;
            }
        }

        IERC20(quoteToken).forceApprove(router, 0);

        uint256 quoteAfter = _balanceOf(quoteToken, address(this));
        quoteSpent = quoteBefore > quoteAfter ? quoteBefore - quoteAfter : 0;

        // A reverted swap must not have moved anything. If it somehow did, treat the round
        // as executed so the accounting still matches reality.
        if (!ok && quoteSpent == 0) return (false, 0, 0, why);

        received = _balanceOf(stock, address(this)) - stockBefore;
        return (true, received, quoteSpent, why);
    }

    /// @notice Finish a round: return everything unspent to the Pot and start the claim
    ///         clock. Permissionless. Every stock with weight must be settled first.
    function finalizeRound(uint256 roundId) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Buying) revert WrongState(roundId, r.state, RoundState.Buying);

        address[] memory stocks = _roundStocks[roundId];
        for (uint256 i; i < stocks.length; ++i) {
            if (!stockSettled[roundId][stocks[i]]) revert NotSettled(roundId, stocks[i]);
        }

        r.state = RoundState.Finalized;
        r.finalizedAt = uint64(block.timestamp);
        // Freeze this round's claim schedule. Governance can retune the config afterwards
        // without ever shortening or narrowing a round that already exists.
        r.expiresAt = uint64(block.timestamp + creditExpiry);
        r.windowLengthAt = windowLength;
        r.openDurationAt = windowOpenDuration;

        uint256 unspent = uint256(r.budget) - uint256(r.spent);
        if (unspent != 0) {
            committedQuote -= unspent;
            IERC20(quoteToken).safeTransfer(address(pot), unspent);
            pot.noteReturned(unspent);
        }

        uint256 valueUsd = _roundValueUsd(roundId, stocks);
        totalPaidUsd += valueUsd;

        emit RoundFinalized(roundId, r.spent, unspent, valueUsd);
    }

    /// @notice Abandon a round that was opened but never closed, returning its whole
    ///         budget to the Pot. Permissionless, and only once a full round period has
    ///         passed with the round still taking contributions.
    /// @dev Exists because a round's budget is committed the moment it opens, and
    ///      committed funds are deliberately out of reach of {recoverExcess}. Without this
    ///      an abandoned round would strand its budget permanently. No credits can have
    ///      been booked yet in this state, so nobody is short-changed.
    function cancelRound(uint256 roundId) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Accumulating) revert WrongState(roundId, r.state, RoundState.Accumulating);
        uint64 abandonedAt = r.openedAt + roundDuration;
        if (block.timestamp < abandonedAt) revert AccumulationStillOpen(uint64(block.timestamp), abandonedAt);

        r.state = RoundState.Finalized;
        r.finalizedAt = uint64(block.timestamp);

        uint256 budget = r.budget;
        if (budget != 0) {
            committedQuote -= budget;
            IERC20(quoteToken).safeTransfer(address(pot), budget);
            pot.noteReturned(budget);
        }
        emit RoundFinalized(roundId, 0, budget, 0);
    }

    /// @dev Marks the round at Chainlink prices. Never reverts on a bad feed: a stock whose
    ///      feed is down contributes zero to the headline counter rather than blocking the
    ///      whole round from finalizing.
    function _roundValueUsd(uint256 roundId, address[] memory stocks) internal view returns (uint256 valueUsd) {
        for (uint256 i; i < stocks.length; ++i) {
            address stock = stocks[i];
            uint256 amount = acquired[roundId][stock];
            if (amount == 0) continue;
            if (stock == quoteToken) {
                valueUsd += (amount * 1e18) / (10 ** registry.quoteDecimals());
                continue;
            }
            try registry.priceUsd(stock) returns (uint256 price1e18, uint256) {
                uint8 dec = registry.getStock(stock).tokenDecimals;
                valueUsd += (amount * price1e18) / (10 ** dec);
            } catch {}
        }
    }

    /* ------------------------------------------------------------------ */
    /*                              CLAIMS                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Whether claims are open right now, under the CURRENT configuration.
    function isClaimOpen() public view returns (bool) {
        return _isOpenAt(uint64(block.timestamp), windowLength, windowOpenDuration);
    }

    /// @notice Whether claims are open for a specific round, under ITS frozen schedule.
    function isClaimOpenFor(uint256 roundId) public view returns (bool) {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Finalized) return false;
        return _isOpenAt(uint64(block.timestamp), r.windowLengthAt, r.openDurationAt);
    }

    /// @notice When the current or next claim window opens and closes.
    /// @return open     Whether a window is open right now.
    /// @return opensAt  Start of the current window if open, otherwise of the next one.
    /// @return closesAt When that window closes.
    function claimWindowState() public view returns (bool open, uint64 opensAt, uint64 closesAt) {
        return _windowStateAt(uint64(block.timestamp), windowLength, windowOpenDuration);
    }

    /// @notice The next moment claims open. Equals now if a window is already open.
    function nextWindowOpensAt() public view returns (uint64) {
        (bool open, uint64 opensAt,) = claimWindowState();
        return open ? uint64(block.timestamp) : opensAt;
    }

    /// @notice How many full claim windows a finalized round still has before it expires.
    /// @dev The site can show "3 chances left". Counts openings strictly after now and at
    ///      or before the round's frozen expiry.
    function windowsRemaining(uint256 roundId) external view returns (uint256) {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Finalized || r.windowLengthAt == 0) return 0;
        if (block.timestamp >= r.expiresAt) return 0;
        return _openingsIn(uint64(block.timestamp), r.expiresAt, r.windowLengthAt);
    }

    /// @notice Full window openings a round was guaranteed at the moment it was finalized.
    /// @dev Must always be at least {MIN_WINDOWS_BEFORE_EXPIRY}. This is the property the
    ///      config invariant test pins down across every accepted configuration.
    function guaranteedWindows(uint256 roundId) public view returns (uint256) {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Finalized || r.windowLengthAt == 0) return 0;
        return _openingsIn(r.finalizedAt, r.expiresAt, r.windowLengthAt);
    }

    /// @notice Window openings strictly after `from` and at or before `to`, for cadence `w`.
    /// @dev Exposed so the schedule guarantee can be asserted directly against arbitrary
    ///      configurations, not only against rounds that happen to exist.
    function openingsInFor(uint64 from, uint64 to, uint32 w) external view returns (uint256) {
        return _openingsIn(from, to, w);
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
    function claim(uint256 roundId, address stock) public nonReentrant returns (uint256 amount) {
        amount = _claim(roundId, stock, msg.sender);
    }

    /// @notice Claim on someone else's behalf. The proceeds always go to `owner`, never to
    ///         the caller, so this is safe to leave permissionless.
    /// @dev Exists so {ClaimRouter} can bundle a claim without becoming the claimant, and
    ///      so the site can auto-claim for a holder before they sell into the anvil. A
    ///      stranger triggering it can only ever help: it delivers the owner's own credit
    ///      to the owner, and it protects them from the 90-day expiry.
    function claimFor(address owner, uint256 roundId, address stock) external nonReentrant returns (uint256 amount) {
        if (owner == address(0)) revert ZeroAddress();
        amount = _claim(roundId, stock, owner);
    }

    /// @notice Claim many (round, stock) pairs in one transaction.
    /// @dev Pairs that yield nothing are skipped rather than reverting, so one empty or
    ///      already-claimed entry cannot brick the batch. A pair whose TOKEN is frozen will
    ///      still revert the whole batch: fall back to single `claim` calls in that case.
    function claimMany(uint256[] calldata roundIds, address[] calldata stocks)
        external
        nonReentrant
        returns (uint256 total)
    {
        if (roundIds.length != stocks.length) revert BadConfig();
        for (uint256 i; i < roundIds.length; ++i) {
            if (claimable(roundIds[i], stocks[i], msg.sender) == 0) continue;
            total += _claim(roundIds[i], stocks[i], msg.sender);
        }
        if (total == 0) revert NothingToClaim();
    }

    function _claim(uint256 roundId, address stock, address owner) internal returns (uint256 amount) {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Finalized) revert WrongState(roundId, r.state, RoundState.Finalized);
        if (block.timestamp > r.expiresAt) revert CreditsExpired(roundId, r.expiresAt);

        // Credits accrue continuously and are always visible via `claimable`, but they can
        // only be taken while a window is open. The round's own frozen cadence is used, so
        // a later governance change can never narrow a round that already exists.
        if (!_isOpenAt(uint64(block.timestamp), r.windowLengthAt, r.openDurationAt)) {
            (, uint64 opensAt,) = _windowStateAt(uint64(block.timestamp), r.windowLengthAt, r.openDurationAt);
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
            // Best effort: the POL-side ledger is a mirror. If it reverts, the claim still
            // stands and this contract's counter remains the authoritative record.
            (bool noted,) = polTreasury.call{gas: PROBE_GAS}(
                abi.encodeWithSignature("notifyCompound(address,address,uint256,uint256)", owner, stock, amount, usd)
            );
            noted; // intentionally ignored: the mirror must never block a claim
            emit Compounded(roundId, stock, owner, amount);
        } else {
            IERC20(stock).safeTransfer(owner, amount);
            emit Claimed(roundId, stock, owner, amount);
        }
    }

    /// @notice After a round's credits expire, send what nobody claimed to the POL treasury.
    ///         Permissionless, one stock at a time, batched over holders.
    ///
    /// @param maxHolders How many holders to process this call. Zero means all remaining.
    /// @return moved     Tokens moved to POL by THIS call.
    /// @return complete  Whether the (round, stock) is now fully swept.
    ///
    /// @dev Emits a {CreditExpired} per holder so the site can show exactly what each person
    ///      lost. That is the reason holders are tracked at all; the token movement itself
    ///      would be a single subtraction.
    ///
    ///      NO LEDGER ENTRY IS MADE. An expired credit is forfeited, not compounded: the
    ///      holder gets no POL share for it. The opt-in `setAutoCompound` ledger is
    ///      untouched and remains purely voluntary.
    ///
    ///      Batching matters because a popular round can have many holders. The cursor makes
    ///      repeated calls safe and idempotent, and the final call settles any rounding dust
    ///      so the contract never keeps a remainder it no longer owes.
    function sweepExpired(uint256 roundId, address stock, uint256 maxHolders)
        public
        nonReentrant
        returns (uint256 moved, bool complete)
    {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Finalized) revert WrongState(roundId, r.state, RoundState.Finalized);
        if (block.timestamp <= r.expiresAt) revert NotExpiredYet(roundId, r.expiresAt);
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
            // Settle rounding dust: per-holder shares are floored, so the sum can fall a few
            // units short of what the round actually still holds.
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
    /*                              RESCUE                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Token balance not backing any live claim.
    /// @dev Mirrors the BasedPacks `excessERC20` pattern: balance minus everything owed.
    function excess(address token) public view returns (uint256) {
        uint256 balance = _balanceOf(token, address(this));
        uint256 reserved = totalOwed[token];
        if (token == quoteToken) reserved += committedQuote;
        return balance > reserved ? balance - reserved : 0;
    }

    /// @notice Recover only tokens provably in excess of every unexpired claim.
    /// @dev THE INVARIANT: this can never reduce the balance below `totalOwed`. Checked
    ///      before the transfer against {excess}, and again afterwards against the real
    ///      balance, so even a fee-on-transfer or rebasing token cannot slip through.
    ///      Deliberately cannot touch user credits — that is the entire point.
    function recoverExcess(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 avail = excess(token);
        if (amount == 0 || amount > avail) revert InsufficientExcess(token, amount, avail);

        IERC20(token).safeTransfer(to, amount);

        uint256 mustKeep = totalOwed[token];
        if (token == quoteToken) mustKeep += committedQuote;
        if (_balanceOf(token, address(this)) < mustKeep) revert Insolvent(token);
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
