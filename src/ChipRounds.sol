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
import {IChipClaims} from "./interfaces/IChipClaims.sol";
import {RoundState, Round} from "./interfaces/IChipRounds.sol";
import {IUniswapV3SwapRouter, ISlipstreamSwapRouter} from "./interfaces/ISwapRouters.sol";

/// @title ChipRounds
/// @notice The engine. Every 24h it takes a budget from the Pot, works out how much each
///         activated Noun is owed, buys the stocks they chose, and hands the results to
///         {ChipClaims}.
///
/// @dev THE SPLIT. This contract SPENDS money; {ChipClaims} OWES it. Everything with
///      moving parts lives here — routers, Chainlink bounds, venue selection, weights,
///      splits, the POL holdback — and none of it can pay a holder. The engine's only
///      reach into the ledger is four calls that create entitlements and hand over assets.
///      There is no proxy and no delegatecall: two plain contracts, wired at deploy.
///
///      NO MASTERCHEF ACCUMULATOR, DELIBERATELY. An accumulator cannot express "this credit
///      expires 30 days after round 42", and we must iterate Nouns anyway because the
///      Clutch vault cannot enumerate activated tokens (ASSUMPTIONS A-10). Per-round weight
///      shares give exact expiry and exact sweeps with no second pass.
///
///      EVERYTHING IS PER-STOCK AND PERMISSIONLESS, SO FAILURES STAY ISOLATED. Buying is one
///      call per stock. A stock that is frozen, paused or policy-blocked by its issuer fails
///      only its own call; the others still buy. This is a structural consequence of the
///      shape, not a check anyone has to remember.
///
///      ROUNDS ARE FILLED PERMISSIONLESSLY. `contributeWeights` can be called by anyone for
///      anyone's Nouns, and a round cannot close until `accumulationWindow` has passed. That
///      combination stops a griefer opening a round, adding only their own Noun and closing
///      it: anybody left out can add themselves before the window ends.
contract ChipRounds is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    /// @notice Gas cap on calls into foreign contracts. See ASSUMPTIONS.md A-17.
    uint256 public constant PROBE_GAS = 100_000;

    /// @notice Hard ceiling on the POL holdback. Spec section 6 allows 0-25%.
    uint32 public constant MAX_HOLDBACK_BPS = 2_500;

    /// @notice Floor on {maxFeedAge} when it is switched on at all.
    /// @dev B20 equity feeds have NO heartbeat when equity markets are closed; they hold the
    ///      last close (ASSUMPTIONS A-14). An ordinary weekend is already about 65 hours from
    ///      Friday's close to Monday's open, and a holiday weekend runs past 110. A staleness
    ///      limit tighter than this would not catch a dead feed, it would skip every Monday
    ///      round on a healthy one — a liveness bug that would be very easy to miss, because
    ///      skipping is silent and safe. So the floor exists to stop a well-meaning
    ///      "tighten it up" from quietly switching the protocol off two days a week.
    uint64 public constant MIN_FEED_AGE = 72 hours;

    struct Split {
        bool set;
        uint8 count;
        address[3] stocks;
        uint8[3] pcts;
    }

    /* ----------------------------- wiring ----------------------------- */

    IStockRegistry public immutable registry;
    address public immutable quoteToken;
    IChipClaims public claims;
    IPot public pot;
    IActivationSource public activationSource;
    address public polTreasury;
    address public chipToken;
    address public chipBurnAddress;

    IUniswapV3SwapRouter public uniswapRouter;
    ISlipstreamSwapRouter public slipstreamRouter;

    /* --------------------------- tunables ----------------------------- */

    uint64 public roundDuration;
    uint64 public accumulationWindow;
    /// @notice Smallest pot that may open a round. The only size bound that remains.
    /// @dev THERE IS NO MAXIMUM. A round distributes whatever the Pot holds.
    ///
    ///      `maxRoundBudget` existed as a pre-audit blast radius: while the contracts were
    ///      unreviewed, a bug could only ever reach one capped round's worth of value. The
    ///      audit is complete and the cap is gone. A floor is a different thing and stays —
    ///      it stops a round firing on dust, where the per-stock slices round to zero and
    ///      the round spends gas to distribute nothing.
    ///
    ///      **What removing the cap does NOT change: what a single buy is allowed to fill.**
    ///      That bound is per stock, per buy, and lives in `_minOutFor` — a buy must clear
    ///      the Chainlink mark less `maxSlippageBps` or it does not execute at all. A larger
    ///      round makes each slice larger; it does not make a bad fill acceptable. See the
    ///      note on {settleStock} for how a slice too large for its pool behaves now.
    uint128 public minPotToOpen;
    uint256 public splitChangeFeeChip;
    uint32 public defaultMaxSlippageBps;

    /// @notice Skip a stock whose Chainlink feed has not updated in this long. 0 disables.
    /// @dev Not a price check — a skip, and the slice carries to the next round. See
    ///      {setMaxFeedAge}.
    uint64 public maxFeedAge;
    uint32 public holdbackBps;

    mapping(address collection => uint32 bps) public collectionBaseBps;
    mapping(address stock => uint32 bps) internal _maxSlippageBpsOverride;

    /* ----------------------------- state ------------------------------ */

    uint256 public roundCount;
    uint64 public lastRoundOpenedAt;
    uint256 public totalPaidUsd;
    uint256 public committedQuote;

    mapping(uint256 roundId => Round) internal _rounds;
    mapping(uint256 roundId => address[]) internal _roundStocks;
    mapping(uint256 roundId => mapping(address stock => bool)) internal _roundHasStock;
    mapping(uint256 roundId => mapping(address stock => bool)) public stockSkipped;
    mapping(uint256 roundId => mapping(address stock => bool)) public stockSettled;
    mapping(uint256 roundId => mapping(address collection => mapping(uint256 tokenId => bool))) public counted;

    mapping(address collection => mapping(uint256 tokenId => Split)) internal _splits;

    /* ----------------------------- events ----------------------------- */

    event RoundOpened(uint256 indexed roundId, uint256 budget, address indexed opener);
    event WeightsContributed(uint256 indexed roundId, address indexed collection, uint256 count, uint256 weightAdded);
    event AccumulationClosed(uint256 indexed roundId, uint256 totalWeight);
    event StockBought(uint256 indexed roundId, address indexed stock, uint256 spent, uint256 received);
    event HoldbackSent(uint256 indexed roundId, address indexed stock, uint256 amount);
    /// @dev The swap consumed input but delivered less than the Chainlink-derived floor.
    ///      A well-behaved router cannot do this; a misbehaving token can. Loud on purpose.
    event StockUnderdelivered(uint256 indexed roundId, address indexed stock, uint256 spent, uint256 received);
    /// @dev Stock was bought but the ledger could not receive it. It sits in the engine,
    ///      credited to nobody, recoverable by the multisig. Loud on purpose.
    event StockStranded(uint256 indexed roundId, address indexed stock, uint256 amount);
    /// @notice Stock reached the ledger but the ledger refused to book it. The tokens are at
    ///         `ChipClaims`, owed to nobody, and recoverable there via `recoverExcess`.
    event LedgerRefusedBooking(uint256 indexed roundId, address indexed stock, uint256 amount);
    /// @notice A stock's feed could not be read at finalize, so `amount` of it is missing from
    ///         this round's reported USD value. The credit itself is unaffected.
    event RoundValueUnpriced(uint256 indexed roundId, address indexed stock, uint256 amount);
    event StockSkipped(uint256 indexed roundId, address indexed stock, uint256 wouldHaveSpent, bytes reason);
    event RoundFinalized(uint256 indexed roundId, uint256 spent, uint256 returned, uint256 valueUsd);
    event SplitSet(address indexed collection, uint256 indexed tokenId, address[3] stocks, uint8[3] pcts, uint256 fee);
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
    error AlreadySettled(uint256 roundId, address stock);
    error NotSettled(uint256 roundId, address stock);
    error InsufficientExcess(address token, uint256 requested, uint256 available);
    error Insolvent(address token);
    error BadConfig();

    /// @param multisig  Owner.
    /// @param registry_ StockRegistry.
    /// @param pot_      Pot.
    /// @param source_   Activation source (the Clutch adapter).
    /// @param claims_   The claims ledger.
    /// @param splitChangeFeeChip_ Flat $CHIP burned to change an already-set split. The
    ///                  first split is always free. Spec value is 5,000 CHIP: cheap enough
    ///                  not to punish a genuine re-pick, dear enough that flipping weekly
    ///                  to chase the cheapest stock costs more than it gains.
    constructor(
        address multisig,
        address registry_,
        address pot_,
        address source_,
        address claims_,
        uint256 splitChangeFeeChip_
    ) Ownable(multisig) {
        if (
            multisig == address(0) || registry_ == address(0) || pot_ == address(0) || source_ == address(0)
                || claims_ == address(0)
        ) revert ZeroAddress();

        registry = IStockRegistry(registry_);
        quoteToken = IStockRegistry(registry_).quoteToken();
        pot = IPot(pot_);
        activationSource = IActivationSource(source_);
        claims = IChipClaims(claims_);

        roundDuration = 24 hours;
        accumulationWindow = 2 hours;
        defaultMaxSlippageBps = 200; // 2%
        splitChangeFeeChip = splitChangeFeeChip_;
    }

    /* ------------------------------------------------------------------ */
    /*                            GOVERNANCE                                */
    /* ------------------------------------------------------------------ */

    function setClaims(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        claims = IChipClaims(v);
        emit AddressUpdated("claims", v);
    }

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
    }

    function setRouters(address uni, address slip) external onlyOwner {
        uniswapRouter = IUniswapV3SwapRouter(uni);
        slipstreamRouter = ISlipstreamSwapRouter(slip);
        emit AddressUpdated("uniswapRouter", uni);
        emit AddressUpdated("slipstreamRouter", slip);
    }

    function setCollectionBaseBps(address collection, uint32 bps) external onlyOwner {
        if (collection == address(0)) revert ZeroAddress();
        collectionBaseBps[collection] = bps;
        emit ConfigUpdated(bytes32(uint256(uint160(collection))), bps);
    }

    /// @notice Round timing and the minimum pot to open. There is no maximum.
    /// @dev The `maxBudget` argument was removed rather than accepted-and-ignored: a
    ///      parameter that silently does nothing is the failure mode this repo has already
    ///      been bitten by twice (the `setCustodian` trap, and the `callerMinOut` that
    ///      existed but was never passed). Callers of the old four-argument form will fail to
    ///      compile, which is the intended way to find them.
    function setRoundParams(uint64 duration, uint64 window, uint128 minPot) external onlyOwner {
        if (duration == 0 || window >= duration) revert BadConfig();
        roundDuration = duration;
        accumulationWindow = window;
        minPotToOpen = minPot;
        emit ConfigUpdated("roundDuration", duration);
        emit ConfigUpdated("minPotToOpen", minPot);
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

    function setDefaultMaxSlippageBps(uint32 bps) external onlyOwner {
        if (bps >= BPS) revert BadConfig();
        defaultMaxSlippageBps = bps;
        emit ConfigUpdated("defaultMaxSlippageBps", bps);
    }

    /// @notice Skip any stock whose feed is older than `v` seconds, carrying its budget.
    ///         Zero switches the check off entirely.
    ///
    /// @dev THIS IS A LIVENESS SETTING, NOT A SAFETY ONE, AND IT CUTS BOTH WAYS.
    ///
    ///      The risk it addresses: a feed that has genuinely died still returns its last
    ///      answer forever, so a round would keep pricing purchases off a number nobody is
    ///      updating. The Chainlink bound would still be enforced — against a stale mark,
    ///      which is worse than useless if the real price has moved.
    ///
    ///      The risk it creates: these feeds legitimately look stale. They have no off-hours
    ///      heartbeat (ASSUMPTIONS A-14), so on a Monday morning every equity feed is ~65
    ///      hours old and after a holiday weekend past 110. Set this too tight and every
    ///      round of the working week's first day silently buys nothing.
    ///
    ///      Hence {MIN_FEED_AGE}, a 72-hour floor on any non-zero value, and a recommended
    ///      setting of 120 hours in DEPLOY.md. A skip is cheap — the slice carries to the
    ///      next round and nobody loses a cent — so erring generous costs almost nothing,
    ///      while erring tight costs a day of rounds a week.
    function setMaxFeedAge(uint64 v) external onlyOwner {
        if (v != 0 && v < MIN_FEED_AGE) revert BadConfig();
        maxFeedAge = v;
        emit ConfigUpdated("maxFeedAge", v);
    }

    /// @notice Share of each stock purchase held back for protocol-owned liquidity.
    function setHoldbackBps(uint32 bps) external onlyOwner {
        if (bps > MAX_HOLDBACK_BPS) revert BadConfig();
        holdbackBps = bps;
        emit ConfigUpdated("holdbackBps", bps);
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
    /// @dev Callable by the Noun's EFFECTIVE owner. The first set is free; every later change
    ///      burns a flat amount of $CHIP, which is what stops split-flipping right before a
    ///      round to chase whichever stock happens to be cheapest.
    ///
    ///      EFFECTIVE, NOT `ownerOf`, and that difference is the whole point of custody
    ///      support. A Noun locked as loan collateral keeps earning for the borrower, so the
    ///      borrower must also keep the ability to re-pick what it earns — a raw `ownerOf`
    ///      check would hand that right to the loan vault, which cannot use it. The
    ///      activation source resolves through a registered custodian to the beneficiary;
    ///      for a Noun in an ordinary wallet the two answers are identical.
    ///
    ///      This does put `setSplit` authorisation behind the multisig-set activation source.
    ///      That is not a new power: the same contract already decides whose weight counts in
    ///      every round, which is strictly more than deciding whose split may change, and it
    ///      still cannot move a token.
    function setSplit(address collection, uint256 tokenId, address[] calldata stocks, uint8[] calldata pcts)
        external
        nonReentrant
    {
        address effective = activationSource.effectiveOwner(collection, tokenId);
        if (effective == address(0) || effective != msg.sender) revert NotNounOwner(msg.sender);
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

        // The whole pot, whatever it is. `pullBudget` is what bounds this against what the
        // Pot can actually pay, and `uint128` is what bounds it against the Round struct.
        uint256 got = pot.pullBudget(availableInPot);
        if (got > type(uint128).max) revert BadConfig();

        roundId = ++roundCount;
        _rounds[roundId] = Round({
            state: RoundState.Accumulating,
            openedAt: uint64(block.timestamp),
            finalizedAt: 0,
            budget: uint128(got),
            spent: 0,
            totalWeight: 0
        });
        lastRoundOpenedAt = uint64(block.timestamp);
        committedQuote += got;

        emit RoundOpened(roundId, got, msg.sender);
    }

    /// @notice Add Nouns to the open round. Permissionless and batched.
    /// @dev Anyone may submit anyone's token ids; the contract verifies each one against the
    ///      activation source, so a padded or wrong list cannot inflate a share.
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

            uint256 weight = _weight(collection, tierBps);
            if (weight == 0) continue;

            counted[roundId][collection][tokenId] = true;
            added += _allocate(roundId, collection, tokenId, owner, weight);
            ++accepted;
        }
        r.totalWeight += added;
        emit WeightsContributed(roundId, collection, accepted, added);
    }

    /// @notice A Noun's weight: tier multiplier x collection base, in basis points.
    ///
    /// @dev THERE IS NO THIRD TERM, AND THERE USED TO BE.
    ///
    ///      A 1.10x "hoodie boost" — an external NFT collection whose holders scored extra —
    ///      was carried over from the pre-Clutch v0.1 spec and removed before launch. That
    ///      collection is not part of this project and is not on Base, so the term was
    ///      configuration pointing at nothing, priced into nobody's expectations, and
    ///      carrying a live sybil: the boost read ownership at contribution time while
    ///      `counted` tracked Nouns rather than boost tokens, so one NFT passed between
    ///      addresses inside the 2-hour accumulation window could boost unlimited Nouns.
    ///
    ///      Removed rather than fixed. See TRIAGE.md EXT-R-M-2.
    function _weight(address collection, uint32 tierBps) internal view returns (uint256) {
        uint256 base = collectionBaseBps[collection];
        if (base == 0) return 0;
        return (uint256(tierBps) * base) / BPS;
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
        claims.creditWeight(roundId, stock, owner, weight);
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
    ///      paused or policy-blocked fails only this call; every other stock proceeds. The
    ///      failed stock is marked skipped and its slice carries back to the Pot at finalize.
    ///
    ///      A SLICE TOO LARGE FOR ITS POOL IS ALL-OR-NOTHING, AND THAT IS WORTH KNOWING
    ///      PRECISELY NOW THAT ROUNDS ARE UNCAPPED. `_buy` asks the router for the whole
    ///      slice with a Chainlink-derived `amountOutMinimum`. Against a pool too thin to
    ///      fill it at that price the swap reverts inside the router, `_buy` reports
    ///      `executed == false`, nothing moved, and the ENTIRE slice is marked skipped and
    ///      carried. It does not partially fill.
    ///
    ///      So the guarantees a large round has are: **the round never reverts**, **no funds
    ///      are lost**, and **the unfilled value returns to the Pot and is re-split by the
    ///      next round**. What it does NOT have is a partial fill — a thin stock in a big
    ///      round buys nothing rather than buying what it safely can. That is the safe
    ///      direction, and it is a real limitation: see OPEN_ITEMS 26.
    function settleStock(uint256 roundId, address stock) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Buying) revert WrongState(roundId, r.state, RoundState.Buying);
        if (stockSettled[roundId][stock]) revert AlreadySettled(roundId, stock);

        uint256 stockWeight = claims.totalWeight(roundId, stock);
        if (stockWeight == 0) revert NoWeight(roundId);

        stockSettled[roundId][stock] = true;
        uint256 slice = (uint256(r.budget) * stockWeight) / r.totalWeight;
        if (slice == 0) {
            stockSkipped[roundId][stock] = true;
            emit StockSkipped(roundId, stock, 0, "zero slice");
            return;
        }

        // The quote token needs no swap: hand it straight to the ledger.
        if (stock == quoteToken) {
            committedQuote -= slice;
            r.spent += uint128(slice);
            IERC20(quoteToken).safeTransfer(address(claims), slice);
            claims.recordAcquired(roundId, stock, slice);
            emit StockBought(roundId, stock, slice, slice);
            return;
        }

        (bool executed, uint256 received, uint256 quoteSpent, bytes memory reason) = _buy(stock, slice);

        // Not executed means the swap reverted atomically: nothing left the contract, so the
        // slice is untouched and carries to the next round.
        if (!executed) {
            stockSkipped[roundId][stock] = true;
            emit StockSkipped(roundId, stock, slice, reason);
            return;
        }

        // Executed. Book what ACTUALLY moved in both directions, never the intent. A swap
        // that consumed the input but under-delivered is a real loss that has already
        // happened; recording it as a skip would leave the round claiming to hold quote
        // token it no longer has, and finalize would then be unable to return the balance.
        uint256 heldBack = _sendHoldback(stock, received);
        uint256 credited = received - heldBack;

        committedQuote -= quoteSpent;
        r.spent += uint128(quoteSpent);

        // Handing the stock to the ledger is its own failure point, and it must not take
        // the round down with it. A stock whose issuer has blocked the LEDGER (rather than
        // this engine) would otherwise revert settleStock and leave the round unfinishable
        // — the split would have created a new way to break isolation. Instead the transfer
        // is attempted, measured, and any shortfall is stranded here and reported. The
        // quote token was genuinely spent either way, so the budget records that honestly.
        uint256 delivered = _deliver(roundId, stock, credited);

        emit StockBought(roundId, stock, quoteSpent, delivered);
        if (heldBack != 0) emit HoldbackSent(roundId, stock, heldBack);
        if (received < _minOutFor(stock, quoteSpent)) {
            emit StockUnderdelivered(roundId, stock, quoteSpent, received);
        }
    }

    /// @dev Hands purchased stock to the ledger and books exactly what arrived. NEVER
    ///      REVERTS — and that promise has two halves, because the handover can fail in two
    ///      independent places.
    ///
    ///      1. THE TRANSFER FAILS. A ledger the stock's issuer has policy-blocked cannot
    ///         receive it. `ok` is false, nothing moved, the tokens stay in this contract and
    ///         are reported by {StockStranded}. Recoverable through this contract's
    ///         `recoverExcess`, which cannot reach committed budget.
    ///
    ///      2. THE TRANSFER SUCCEEDS AND THE LEDGER REFUSES TO BOOK IT. This is the one that
    ///         used to wedge the round, and it is subtler: `recordAcquired` verifies against
    ///         the LEDGER's own balance before believing us, so a stock that taxes transfers
    ///         makes the two disagree — this contract's balance falls by the full amount
    ///         while the ledger receives less — and the ledger reverts `Underfunded`. An
    ///         unprotected call meant that revert propagated: `settleStock` reverted, so the
    ///         stock could never be settled, `finalizeRound` requires every stock settled and
    ///         could never succeed, `cancelRound` is blocked by the `Buying` state, and
    ///         `committedQuote` stranded permanently. One misbehaving stock froze every
    ///         holder in the round. Found by external review (TRIAGE EXT-R-M-1); reproduced
    ///         by `test_aLedgerThatRefusesToBookDoesNotWedgeTheRound`.
    ///
    ///         Now caught. The tokens are at the LEDGER, unbooked, and reported by
    ///         {LedgerRefusedBooking} rather than by {StockStranded} — a different address
    ///         holds them, so a different event names them and a different rescue reaches
    ///         them. Because `totalOwed` never rose, they are *excess* by the ledger's own
    ///         definition, so `ChipClaims.recoverExcess` can take them and, by construction,
    ///         cannot touch a single booked credit on the way.
    ///
    ///      NO REDELIVERY, DELIBERATELY. It would have to re-enter `recordAcquired` after the
    ///      round finalized, which reverts `AlreadyFinalized` — and rightly, since the round's
    ///      shares are fixed at finalize and re-opening them is a far larger hole than the one
    ///      it would close. Recovery plus manual distribution is the honest path, and it is a
    ///      multisig action against tokens nobody is owed.
    function _deliver(uint256 roundId, address stock, uint256 amount) internal returns (uint256 delivered) {
        if (amount == 0) return 0;

        uint256 before = _balanceOf(stock, address(this));
        (bool ok,) = stock.call(abi.encodeCall(IERC20.transfer, (address(claims), amount)));

        uint256 sent;
        if (ok) {
            uint256 remaining = _balanceOf(stock, address(this));
            sent = before > remaining ? before - remaining : 0;
            if (sent > amount) sent = amount;
        }

        if (sent != 0) {
            try claims.recordAcquired(roundId, stock, sent) {
                delivered = sent;
            } catch {
                // The tokens left this contract and the ledger would not book them. Say so,
                // with the amount and where it is, and let the round finish.
                emit LedgerRefusedBooking(roundId, stock, sent);
            }
        }

        // Only what never left THIS contract is stranded here.
        if (sent < amount) emit StockStranded(roundId, stock, amount - sent);
    }

    /// @dev Moves the POL share of a purchase to the treasury and reports how much ACTUALLY
    ///      left, measured by balance delta rather than trusted from a return value. A token
    ///      that lies about transferring, or refuses because the treasury is policy-blocked,
    ///      simply results in a smaller (or zero) holdback and a larger credit to holders. It
    ///      can never make the round fail, and never causes stock to be credited that this
    ///      contract does not hold.
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

    /// @notice Whether this stock's feed is currently too old to buy against.
    /// @dev Exposed so the keeper and the site can explain a skip before it happens rather
    ///      than after. Always false when the check is switched off.
    function isFeedStale(address stock) public view returns (bool) {
        uint64 maxAge = maxFeedAge;
        if (maxAge == 0) return false;
        try registry.priceUsd(stock) returns (uint256, uint256 updatedAt) {
            if (updatedAt == 0) return true;
            return block.timestamp > updatedAt + maxAge;
        } catch {
            // No readable price at all. Not this check's business: `_minOutFor` returns zero
            // and the buy is skipped as "no price", which is the more accurate reason.
            return false;
        }
    }

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

        // A frozen feed prices the buy off a number nobody is updating any more. Skip and
        // carry: the slice is untouched and goes to the next round. See {setMaxFeedAge}.
        if (isFeedStale(stock)) return (false, 0, 0, "stale feed");

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
    ///         clock in the ledger. Permissionless. Every stock with weight must be settled.
    function finalizeRound(uint256 roundId) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Buying) revert WrongState(roundId, r.state, RoundState.Buying);

        address[] memory stocks = _roundStocks[roundId];
        for (uint256 i; i < stocks.length; ++i) {
            if (!stockSettled[roundId][stocks[i]]) revert NotSettled(roundId, stocks[i]);
        }

        r.state = RoundState.Finalized;
        r.finalizedAt = uint64(block.timestamp);

        uint256 unspent = uint256(r.budget) - uint256(r.spent);
        if (unspent != 0) {
            committedQuote -= unspent;
            IERC20(quoteToken).safeTransfer(address(pot), unspent);
            pot.noteReturned(unspent);
        }

        // Freezes expiry and the window cadence for this round, in the ledger.
        claims.freezeSchedule(roundId);

        uint256 valueUsd = _roundValueUsd(roundId, stocks);
        totalPaidUsd += valueUsd;

        emit RoundFinalized(roundId, r.spent, unspent, valueUsd);
    }

    /// @notice Abandon a round that was opened but never closed, returning its whole budget
    ///         to the Pot. Permissionless, once a full round period has passed.
    /// @dev A round's budget is committed the moment it opens, and committed funds are
    ///      deliberately out of reach of {recoverExcess}. Without this an abandoned round
    ///      would strand its budget permanently. No credits exist yet in this state.
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
    /// @dev NOT `view`, so the unpriceable case can say so. A stock whose feed reverts at
    ///      finalize is simply omitted from the round's USD figure — the tokens are bought and
    ///      credited either way, and refusing to finalize over a reporting number would be
    ///      the wrong trade. But an omission that leaves no trace is a lie by rounding:
    ///      `totalPaidUsd` under-reports, and neither the site nor anyone reading the chain
    ///      can tell "this round paid less" from "this round could not be priced".
    ///
    ///      {RoundValueUnpriced} names each stock it happened to, so the site can show the
    ///      round as partially priced and re-derive it later from a working feed. Raised by
    ///      external review as I-1.
    function _roundValueUsd(uint256 roundId, address[] memory stocks) internal returns (uint256 valueUsd) {
        for (uint256 i; i < stocks.length; ++i) {
            address stock = stocks[i];
            uint256 amount = IChipClaimsView(address(claims)).acquired(roundId, stock);
            if (amount == 0) continue;
            if (stock == quoteToken) {
                valueUsd += (amount * 1e18) / (10 ** registry.quoteDecimals());
                continue;
            }
            try registry.priceUsd(stock) returns (uint256 price1e18, uint256) {
                uint8 dec = registry.getStock(stock).tokenDecimals;
                valueUsd += (amount * price1e18) / (10 ** dec);
            } catch {
                emit RoundValueUnpriced(roundId, stock, amount);
            }
        }
    }

    /* ------------------------------------------------------------------ */
    /*                              RESCUE                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Token balance not backing a live round's committed budget.
    /// @dev The engine holds quote token only transiently. Committed budget belongs to a
    ///      round in flight and is deliberately out of reach, which is what stops a rescue
    ///      leaving a settlement unable to pay. Booked credits are not here at all: they
    ///      live in {ChipClaims}, behind its own rescue.
    function excess(address token) public view returns (uint256) {
        uint256 balance = _balanceOf(token, address(this));
        uint256 reserved = token == quoteToken ? committedQuote : 0;
        return balance > reserved ? balance - reserved : 0;
    }

    function recoverExcess(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 avail = excess(token);
        if (amount == 0 || amount > avail) revert InsufficientExcess(token, amount, avail);

        IERC20(token).safeTransfer(to, amount);

        uint256 mustKeep = token == quoteToken ? committedQuote : 0;
        if (_balanceOf(token, address(this)) < mustKeep) revert Insolvent(token);
        emit ExcessRecovered(token, to, amount);
    }

    /// @dev Gas-capped balance read. See ASSUMPTIONS.md A-17.
    function _balanceOf(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC20.balanceOf, (who)));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }
}

/// @dev The one extra read the engine needs for its USD marks.
interface IChipClaimsView {
    function acquired(uint256 roundId, address stock) external view returns (uint256);
}
