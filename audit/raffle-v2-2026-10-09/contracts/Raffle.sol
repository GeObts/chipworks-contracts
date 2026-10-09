// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IEntropyV2} from "../interfaces/IEntropyV2.sol";
import {IStockRegistry, Stock, Venue} from "../interfaces/IStockRegistry.sol";
import {ISlipstreamSwapRouter} from "../interfaces/ISwapRouters.sol";
import {ISlipstreamPool, ISlipstreamFactory, ISlipstreamRouterFactory} from "../interfaces/ISlipstreamPool.sol";

/// @title  Raffle (v2)
/// @notice House-run raffles whose prize is a B20 stock the contract BUYS with the ticket money.
///
/// @dev    SPEC: specs/raffle/SPEC-v2.md (signed off 2026-10-09). The rules that shape everything:
///
///         ONLY THE HOUSE CREATES. {createRaffle} is owner-only (the Safe). The house names a
///         prize of `base` whole USD in one Slipstream-traded stock and posts an ETH reserve for
///         the randomness fee. It escrows no prize.
///
///         FEE ON TOP. A raffle sells `base + ceil(base * feeBps / 10_000)` tickets at 1 USDC.
///         `base` USDC buys the prize; the rest is the Pot's fee, paid at settle.
///
///         THE PRIZE IS HELD BEFORE ANYONE CAN WIN IT. Selling the last ticket only marks the
///         raffle SoldOut. Then {acquirePrize} (owner/keeper) buys the stock with exactly `base`
///         USDC, all-or-nothing, behind an onchain price guard, and only after the stock is in
///         this contract is randomness requested. If the buy cannot complete within the raffle's
///         acquire timeout, ANYONE can {fallbackToUsdc}: the prize becomes the `base` USDC already
///         held and the draw proceeds. So every sold-out raffle reaches a draw, and no winner is
///         ever owed a prize this contract does not hold.
///
///         THE PRICE GUARD IS 24/7 AND ONCHAIN. It reads only the stock's own pool: a TWAP over
///         `twapWindow` from the pool oracle, a refusal when spot sits more than
///         `maxDeviationTicks` from that TWAP (a pushed pool), a `minOut` floor `maxSlippageBps`
///         under the TWAP price, and a size cap of `maxPoolShareBps` of the USDC in the pool. No
///         market-hours equity feed is read anywhere.
///
///         NO EXIT BEFORE SELLOUT, BY DESIGN. No deadline, refund, cancel or admin withdraw.
///         The owner has NO function that moves a prize, ticket money or a reserve. Every
///         parameter that shapes a raffle is snapshotted into it at creation. Non-upgradeable.
///
///         RANDOMNESS IS PYTH ENTROPY V2 with a contract-mixed user seed. The callback only
///         records the number. Fresh randomness ({retryDraw}) only for a draw Entropy never
///         revealed, only after the raffle's redraw timeout, only by the owner or the keeper.
///
///         PAYOUTS ARE ISOLATED. {settle} is permissionless and pushes or CREDITS each leg, so a
///         refused recipient never blocks the others.
contract Raffle is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ------------------------------------------------------------------ */
    /*                               TYPES                                  */
    /* ------------------------------------------------------------------ */

    /// @notice What the prize is. APPEND-ONLY: a future pre-funded NFT mode adds a kind here.
    enum PrizeKind {
        Stock, // bought by {acquirePrize}
        Usdc // the `base` USDC, after {fallbackToUsdc}
    }

    /// @notice Where the prize comes from. APPEND-ONLY: a future pre-funded mode adds a source.
    enum PrizeSource {
        Acquire
    }

    enum State {
        None,
        Open, // selling tickets
        SoldOut, // every ticket sold; prize not yet held ({acquirePrize} / {fallbackToUsdc})
        PrizeReady, // prize held; draw not requested yet (needs {requestDraw})
        Drawing, // Entropy requested, waiting for the reveal
        Drawn, // random number recorded, waiting for {settle}
        Settled
    }

    /// @notice Why a stock cannot be raffled or bought right now (SPEC-v2 §2.4).
    enum Refusal {
        None,
        StockDisabled, // not registered or not enabled in the StockRegistry
        NotSlipstream, // the registry does not route it on Slipstream
        PoolMismatch, // the registry's pool is not the router's pool, or not USDC/stock
        TwapUnavailable, // the pool oracle cannot produce the TWAP window
        SpotDeviates, // spot sits further from the TWAP than the guard allows
        TooLargeForPool, // the prize exceeds the pool-share cap
        NoOutput, // the floor rounds to zero
        PartialSpend, // the router did not spend exactly the budget
        UnderDelivered // the measured stock received is under the floor
    }

    /// @notice The price guard, snapshotted per raffle.
    struct PriceGuard {
        uint32 twapWindow; // seconds
        uint16 maxDeviationTicks; // |spot tick - TWAP tick|; 1 tick ~ 1 bp
        uint16 maxSlippageBps; // minOut = TWAP-price output * (1 - this)
        uint16 maxPoolShareBps; // buy <= this share of the USDC in the pool
    }

    struct Prize {
        PrizeKind kind;
        address token; // the stock, or USDC after a fallback
        uint256 amount; // 0 until held; then the stock received, or base * 1e6 USDC
    }

    struct RaffleData {
        Prize prize;
        PrizeSource source;
        /// @notice The stock named at creation (fixed) and the pool its price guard reads.
        address stock;
        address pool;
        int24 tickSpacing;
        /// @notice The owner account that created the raffle: gets the leftover ETH reserve.
        address creator;
        uint32 feeBps;
        State state;
        uint64 base;
        uint64 totalTickets;
        uint64 sold;
        uint64 soldOutAt;
        uint64 drawRequestedAt;
        uint64 sequence;
        uint64 winningTicket;
        address provider;
        address winner;
        uint128 ethReserve;
        bytes32 randomNumber;
        /// @notice Snapshots at creation. Later owner changes never touch a live raffle.
        uint64 redrawTimeout;
        uint64 acquireTimeout;
        PriceGuard guard;
    }

    struct Purchase {
        address buyer;
        /// @dev Cumulative tickets sold after this purchase. Tickets [prev, this) are the buyer's.
        uint64 endExclusive;
    }

    /* ------------------------------------------------------------------ */
    /*                             CONSTANTS                                */
    /* ------------------------------------------------------------------ */

    /// @notice One ticket costs exactly 1 USDC (6 decimals, checked in the constructor).
    uint256 public constant TICKET_PRICE = 1e6;
    uint256 public constant BPS = 10_000;
    uint32 public constant MAX_FEE_BPS = 2_000;
    uint64 public constant MAX_BASE_CEILING = 1_000_000;
    uint64 public constant MIN_REDRAW_TIMEOUT = 1 hours;
    uint64 public constant MAX_REDRAW_TIMEOUT = 30 days;
    uint64 public constant MIN_ACQUIRE_TIMEOUT = 1 hours;
    uint64 public constant MAX_ACQUIRE_TIMEOUT = 7 days;
    uint32 public constant MIN_TWAP_WINDOW = 5 minutes;
    uint32 public constant MAX_TWAP_WINDOW = 2 hours;
    uint16 public constant MAX_DEVIATION_TICKS = 500;
    uint16 public constant MAX_SLIPPAGE_BPS = 500;
    uint16 public constant MAX_POOL_SHARE_BPS = 500;
    uint32 public constant MIN_CALLBACK_GAS = 100_000;
    uint32 public constant MAX_CALLBACK_GAS = 1_000_000;
    /// @notice The reserve posted at creation must cover this many draw fees at today's price.
    uint256 public constant RESERVE_MULTIPLIER = 3;
    /// @dev EntropyStatusConstants.CALLBACK_NOT_STARTED: requested, never revealed.
    uint8 internal constant CALLBACK_NOT_STARTED = 1;
    /// @dev 1.0001 in 18-decimal fixed point: the price ratio of one tick.
    uint256 internal constant TICK_BASE_WAD = 1.0001e18;
    uint256 internal constant WAD = 1e18;

    /* ------------------------------------------------------------------ */
    /*                             IMMUTABLES                               */
    /* ------------------------------------------------------------------ */

    IERC20 public immutable usdc;
    address public immutable entropy;
    IStockRegistry public immutable registry;
    /// @notice Where every raffle's fee tickets go. Immutable: it can never be redirected.
    address public immutable pot;
    /// @notice The Slipstream router every prize is bought through, and the factory it swaps in.
    ISlipstreamSwapRouter public immutable router;
    address public immutable factory;

    /* ------------------------------------------------------------------ */
    /*                    PARAMETERS (FUTURE RAFFLES ONLY)                  */
    /* ------------------------------------------------------------------ */

    uint32 public feeBps = 1_000;
    uint64 public minBase = 10;
    uint64 public maxBase = 1_000;
    /// @notice How long a draw must sit completely unrevealed before {retryDraw}. Snapshotted.
    uint64 public redrawTimeout;
    /// @notice How long after sellout the prize may stay unbought before anyone may
    ///         {fallbackToUsdc}. Snapshotted.
    uint64 public acquireTimeout;
    /// @notice The price guard new raffles snapshot. Launch: 30 min, 100 ticks, 150 bps, 100 bps.
    PriceGuard public priceGuard =
        PriceGuard({twapWindow: 30 minutes, maxDeviationTicks: 100, maxSlippageBps: 150, maxPoolShareBps: 100});
    uint32 public callbackGasLimit = 200_000;
    /// @notice The automation account allowed to {acquirePrize} and {retryDraw} (besides the
    ///         owner). Zero = none. It has no other power.
    address public keeper;

    /* ------------------------------------------------------------------ */
    /*                               STATE                                  */
    /* ------------------------------------------------------------------ */

    uint256 public raffleCount;
    /// @dev Increments on every Entropy request, so no two requests share a user seed.
    uint256 internal _drawNonce;
    mapping(uint256 raffleId => RaffleData) internal _raffles;
    mapping(uint256 raffleId => Purchase[]) internal _purchases;
    /// @dev Keyed by (provider, sequence): Entropy numbers requests per provider.
    mapping(bytes32 requestKey => uint256 raffleId) internal _raffleOfRequest;

    /// @notice USDC a recipient is owed because a push at settle was refused.
    mapping(address account => uint256) public usdcOwed;
    /// @notice ETH reserve left over after a draw, owed to the raffle's creator.
    mapping(address account => uint256) public ethOwed;
    /// @notice The winner of a raffle whose STOCK prize was refused at settle (zero once delivered).
    mapping(uint256 raffleId => address) public prizeOwedTo;

    /// @notice USDC the contract must hold: ticket money not yet spent or paid + {usdcOwed}.
    uint256 public usdcLiability;
    /// @notice ETH the contract must hold: live reserves + {ethOwed}.
    uint256 public ethLiability;
    /// @notice Stock prize units the contract must hold, per token.
    mapping(address token => uint256) public erc20PrizeEscrow;

    /* ------------------------------------------------------------------ */
    /*                               EVENTS                                 */
    /* ------------------------------------------------------------------ */

    event RaffleCreated(
        uint256 indexed raffleId,
        address indexed stock,
        address indexed pool,
        uint64 base,
        uint64 totalTickets,
        uint32 feeBps,
        uint128 ethReserve,
        PriceGuard guard,
        uint64 acquireTimeout,
        uint64 redrawTimeout
    );
    event TicketsBought(uint256 indexed raffleId, address indexed buyer, uint64 firstTicket, uint64 quantity);
    event SoldOut(uint256 indexed raffleId);
    event PrizeAcquired(
        uint256 indexed raffleId,
        address indexed stock,
        uint256 usdcSpent,
        uint256 stockReceived,
        uint256 minOut,
        int24 twapTick,
        int24 spotTick
    );
    event PrizeFellBackToUsdc(uint256 indexed raffleId, uint256 usdcPrize);
    event DrawAwaitingRequest(uint256 indexed raffleId);
    event DrawRequested(
        uint256 indexed raffleId, address indexed provider, uint64 indexed sequence, uint128 fee, bytes32 userRandomNumber
    );
    event DrawRetried(uint256 indexed raffleId, uint64 oldSequence);
    event Drawn(uint256 indexed raffleId, bytes32 randomNumber, uint64 winningTicket);
    event OrphanCallback(uint64 indexed sequence, address indexed provider);
    event Settled(
        uint256 indexed raffleId,
        address indexed winner,
        uint64 winningTicket,
        PrizeKind prizeKind,
        uint256 prizeAmount,
        uint256 potUsdc,
        bool prizeDelivered
    );
    event UsdcCredited(address indexed account, uint256 amount);
    event UsdcWithdrawn(address indexed account, uint256 amount);
    event EthCredited(address indexed account, uint256 amount);
    event EthWithdrawn(address indexed account, uint256 amount);
    event PrizeClaimed(uint256 indexed raffleId, address indexed winner);
    event ReserveToppedUp(uint256 indexed raffleId, address indexed from, uint256 amount);

    event FeeBpsSet(uint32 feeBps);
    event BaseLimitsSet(uint64 minBase, uint64 maxBase);
    event RedrawTimeoutSet(uint64 timeout);
    event AcquireTimeoutSet(uint64 timeout);
    event PriceGuardSet(PriceGuard guard);
    event CallbackGasLimitSet(uint32 gasLimit);
    event KeeperSet(address indexed keeper);

    /* ------------------------------------------------------------------ */
    /*                               ERRORS                                 */
    /* ------------------------------------------------------------------ */

    error ZeroAddress();
    error BadConfig();
    error UsdcNotSixDecimals(uint8 decimals);
    error BaseOutOfRange(uint64 base, uint64 minBase, uint64 maxBase);
    /// @notice The stock cannot be raffled (or bought) right now; `reason` says why.
    error StockNotBuyable(address stock, Refusal reason);
    error ReserveTooLow(uint256 sent, uint256 required);
    error WrongState(uint256 raffleId, State state);
    error ZeroQuantity();
    error NotEnoughTickets(uint64 requested, uint64 remaining);
    error OnlyEntropy();
    error RedrawNotReady(uint64 nowTs, uint64 readyAt);
    error RevealAlreadyPublic(uint256 raffleId, uint8 callbackStatus);
    error AcquireTimeoutNotReached(uint64 nowTs, uint64 readyAt);
    /// @notice {acquirePrize} refused before or after the swap; nothing moved (SPEC-v2 §2.4).
    error AcquireRefused(uint256 raffleId, Refusal reason);
    /// @notice {acquirePrize}: the router reverted; nothing moved. Carries the router's revert data.
    error SwapReverted(uint256 raffleId, bytes routerError);
    error NothingOwed();
    error EthTransferFailed();
    error TicketOutOfRange(uint64 ticket, uint64 sold);
    error NotAuthorized(address caller);

    /* ------------------------------------------------------------------ */
    /*                            CONSTRUCTOR                               */
    /* ------------------------------------------------------------------ */

    /// @param owner_          The house (the Safe). Only it can create raffles.
    /// @param usdc_           Circle USDC on Base (must report 6 decimals; must be the registry's
    ///                        quote token, which every stock pool is paired against).
    /// @param entropy_        Pyth Entropy v2. Base: 0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb.
    /// @param registry_       ChipWorks StockRegistry: which stocks are enabled, and their pools.
    /// @param pot_            ChipWorks Pot: receives every raffle's fee tickets. Immutable.
    /// @param router_         Slipstream SwapRouter; its factory must be the registry's.
    /// @param redrawTimeout_  See {redrawTimeout}. Bounded [1 hour, 30 days].
    /// @param acquireTimeout_ See {acquireTimeout}. Bounded [1 hour, 7 days].
    constructor(
        address owner_,
        address usdc_,
        address entropy_,
        address registry_,
        address pot_,
        address router_,
        uint64 redrawTimeout_,
        uint64 acquireTimeout_
    ) Ownable(owner_) {
        if (
            usdc_ == address(0) || entropy_ == address(0) || registry_ == address(0) || pot_ == address(0)
                || router_ == address(0)
        ) revert ZeroAddress();
        uint8 d = IERC20Metadata(usdc_).decimals();
        if (d != 6) revert UsdcNotSixDecimals(d);
        if (IStockRegistry(registry_).quoteToken() != usdc_) revert BadConfig();
        address factory_ = ISlipstreamRouterFactory(router_).factory();
        if (factory_ == address(0) || factory_ != IStockRegistry(registry_).slipstreamFactory()) revert BadConfig();
        if (redrawTimeout_ < MIN_REDRAW_TIMEOUT || redrawTimeout_ > MAX_REDRAW_TIMEOUT) revert BadConfig();
        if (acquireTimeout_ < MIN_ACQUIRE_TIMEOUT || acquireTimeout_ > MAX_ACQUIRE_TIMEOUT) revert BadConfig();
        usdc = IERC20(usdc_);
        entropy = entropy_;
        registry = IStockRegistry(registry_);
        pot = pot_;
        router = ISlipstreamSwapRouter(router_);
        factory = factory_;
        redrawTimeout = redrawTimeout_;
        acquireTimeout = acquireTimeout_;
    }

    modifier onlyOwnerOrKeeper() {
        if (msg.sender != owner() && msg.sender != keeper) revert NotAuthorized(msg.sender);
        _;
    }

    /* ------------------------------------------------------------------ */
    /*                              CREATE                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Open a raffle for a prize of `base` whole USD in `stock`. House only. Escrows
    ///         nothing but `msg.value`, the raffle's Entropy reserve.
    /// @dev    Refuses a stock that could not be bought RIGHT NOW: not enabled, not on Slipstream,
    ///         a pool that is not the router's pool, a pool whose oracle cannot produce the TWAP,
    ///         or a prize larger than the pool-share cap. So the house cannot open a raffle that
    ///         could only ever fall back to USDC.
    function createRaffle(address stock, uint64 base) external payable onlyOwner nonReentrant returns (uint256 raffleId) {
        if (stock == address(0)) revert ZeroAddress();
        // base >= minBase >= 1 already (setBaseLimits refuses 0); explicit so N can never be 0.
        if (base == 0 || base < minBase || base > maxBase) revert BaseOutOfRange(base, minBase, maxBase);

        PriceGuard memory g = priceGuard;
        (address pool, int24 spacing) = _validateStock(stock, base, g);

        uint256 required = RESERVE_MULTIPLIER * uint256(quoteDrawFee());
        if (msg.value < required) revert ReserveTooLow(msg.value, required);

        uint32 fee = feeBps;
        raffleId = ++raffleCount;
        RaffleData storage r = _raffles[raffleId];
        r.prize = Prize({kind: PrizeKind.Stock, token: stock, amount: 0});
        r.source = PrizeSource.Acquire;
        r.stock = stock;
        r.pool = pool;
        r.tickSpacing = spacing;
        r.creator = msg.sender;
        r.feeBps = fee;
        r.state = State.Open;
        r.base = base;
        r.totalTickets = _ticketsFor(base, fee);
        r.redrawTimeout = redrawTimeout;
        r.acquireTimeout = acquireTimeout;
        r.guard = g;
        r.ethReserve = uint128(msg.value);
        ethLiability += msg.value;

        _emitCreated(raffleId, r);
    }

    /// @dev The pool for a new raffle's stock, or a {StockNotBuyable} revert with the reason.
    function _validateStock(address stock, uint64 base, PriceGuard memory g)
        internal
        view
        returns (address pool, int24 spacing)
    {
        Refusal why;
        (why, pool, spacing) = _poolFor(stock);
        if (why != Refusal.None) revert StockNotBuyable(stock, why);
        (bool twapOk,) = _twapTick(pool, g.twapWindow);
        if (!twapOk) revert StockNotBuyable(stock, Refusal.TwapUnavailable);
        if (uint256(base) * TICKET_PRICE > _poolCap(pool, g.maxPoolShareBps)) {
            revert StockNotBuyable(stock, Refusal.TooLargeForPool);
        }
    }

    function _emitCreated(uint256 raffleId, RaffleData storage r) internal {
        emit RaffleCreated(
            raffleId,
            r.stock,
            r.pool,
            r.base,
            r.totalTickets,
            r.feeBps,
            r.ethReserve,
            r.guard,
            r.acquireTimeout,
            r.redrawTimeout
        );
    }

    /* ------------------------------------------------------------------ */
    /*                                BUY                                   */
    /* ------------------------------------------------------------------ */

    /// @notice Buy `quantity` tickets at 1 USDC each (approve USDC first). Any number, by anyone,
    ///         until the raffle sells out. There is no refund: the money stays escrowed until the
    ///         raffle sells out, its prize is bought (or falls back to USDC) and the draw settles.
    /// @dev    The last ticket only marks the raffle SoldOut. It never swaps: the last buyer must
    ///         not choose the moment the prize is bought.
    function buy(uint256 raffleId, uint64 quantity) external nonReentrant {
        RaffleData storage r = _raffles[raffleId];
        if (r.state != State.Open) revert WrongState(raffleId, r.state);
        if (quantity == 0) revert ZeroQuantity();
        uint64 remaining = r.totalTickets - r.sold;
        if (quantity > remaining) revert NotEnoughTickets(quantity, remaining);

        uint256 cost = uint256(quantity) * TICKET_PRICE;
        uint64 first = r.sold;
        uint64 end = first + quantity;
        r.sold = end;
        usdcLiability += cost;
        _purchases[raffleId].push(Purchase({buyer: msg.sender, endExclusive: end}));

        usdc.safeTransferFrom(msg.sender, address(this), cost);
        emit TicketsBought(raffleId, msg.sender, first, quantity);

        if (end == r.totalTickets) {
            r.state = State.SoldOut;
            r.soldOutAt = uint64(block.timestamp);
            emit SoldOut(raffleId);
        }
    }

    /* ------------------------------------------------------------------ */
    /*                         ACQUIRE THE PRIZE                            */
    /* ------------------------------------------------------------------ */

    /// @notice Buy the prize stock with exactly `base` USDC, then request the draw. Owner or
    ///         keeper only, so nobody else picks the moment of the buy.
    /// @dev    ALL OR NOTHING. Any refusal — stock disabled, pool mismatch, TWAP unavailable,
    ///         spot deviating from the TWAP, prize too large for the pool, the swap reverting or
    ///         under-delivering — reverts with {AcquireRefused} and moves nothing; the raffle
    ///         stays SoldOut for a retry, and after its acquire timeout anyone may
    ///         {fallbackToUsdc}. Reverting (rather than logging a skip) lets the keeper simulate
    ///         first and send nothing while a guard is refusing.
    function acquirePrize(uint256 raffleId) external onlyOwnerOrKeeper nonReentrant {
        RaffleData storage r = _raffles[raffleId];
        if (r.state != State.SoldOut) revert WrongState(raffleId, r.state);

        (uint256 minOut, int24 twapTick, int24 spotTick) = _priceCheck(raffleId, r);
        (uint256 received, uint256 spent) = _swap(raffleId, r, minOut);

        // Effects. `received` is a measured balance delta, already checked >= minOut.
        usdcLiability -= spent;
        erc20PrizeEscrow[r.stock] += received;
        r.prize.amount = received;
        r.state = State.PrizeReady;
        emit PrizeAcquired(raffleId, r.stock, spent, received, minOut, twapTick, spotTick);

        if (!_tryRequestDraw(raffleId, r)) emit DrawAwaitingRequest(raffleId);
    }

    /// @notice After a sold-out raffle's acquire timeout, ANYONE may make its prize the `base`
    ///         USDC the contract already holds, and request the draw. Nothing can fail here:
    ///         this is what guarantees every sold-out raffle reaches a draw.
    function fallbackToUsdc(uint256 raffleId) external nonReentrant {
        RaffleData storage r = _raffles[raffleId];
        if (r.state != State.SoldOut) revert WrongState(raffleId, r.state);
        uint64 readyAt = r.soldOutAt + r.acquireTimeout;
        if (block.timestamp < readyAt) revert AcquireTimeoutNotReached(uint64(block.timestamp), readyAt);

        uint256 prize = uint256(r.base) * TICKET_PRICE;
        r.prize = Prize({kind: PrizeKind.Usdc, token: address(usdc), amount: prize});
        r.state = State.PrizeReady;
        emit PrizeFellBackToUsdc(raffleId, prize);

        if (!_tryRequestDraw(raffleId, r)) emit DrawAwaitingRequest(raffleId);
    }

    /* ------------------------------------------------------------------ */
    /*                                DRAW                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Request the draw for a raffle whose prize is held but whose automatic request did
    ///         not go through. Permissionless. Any ETH sent tops up the raffle's reserve.
    function requestDraw(uint256 raffleId) external payable nonReentrant {
        RaffleData storage r = _raffles[raffleId];
        if (r.state != State.PrizeReady) revert WrongState(raffleId, r.state);
        _topUp(raffleId, r);
        _requestDraw(raffleId, r);
    }

    /// @notice Ask Entropy for FRESH randomness when a draw has gone completely unrevealed for
    ///         the raffle's snapshotted redraw timeout. Owner or keeper only — never a ticket
    ///         holder, so nobody holding a ticket can choose to re-roll.
    /// @dev    NOT A RE-ROLL. A FAILED callback means Pyth already published the number; the fix
    ///         for that is Pyth's permissionless `revealWithCallback` with the SAME number. So
    ///         this refuses anything but CALLBACK_NOT_STARTED.
    function retryDraw(uint256 raffleId) external payable onlyOwnerOrKeeper nonReentrant {
        RaffleData storage r = _raffles[raffleId];
        if (r.state != State.Drawing) revert WrongState(raffleId, r.state);
        uint64 readyAt = r.drawRequestedAt + r.redrawTimeout;
        if (block.timestamp < readyAt) revert RedrawNotReady(uint64(block.timestamp), readyAt);
        IEntropyV2.RequestV2 memory req = IEntropyV2(entropy).getRequestV2(r.provider, r.sequence);
        if (req.sequenceNumber != r.sequence || req.callbackStatus != CALLBACK_NOT_STARTED) {
            revert RevealAlreadyPublic(raffleId, req.callbackStatus);
        }
        uint64 oldSequence = r.sequence;
        delete _raffleOfRequest[_requestKey(r.provider, oldSequence)];
        _topUp(raffleId, r);
        _requestDraw(raffleId, r);
        emit DrawRetried(raffleId, oldSequence);
    }

    /// @notice The selector Pyth Entropy calls with the revealed number.
    /// @dev    Records the number and the winning ticket index only. No transfers, no search,
    ///         no external calls, never reverts for a known request: it cannot fail.
    function _entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) external {
        if (msg.sender != entropy) revert OnlyEntropy();
        bytes32 key = _requestKey(provider, sequence);
        uint256 raffleId = _raffleOfRequest[key];
        if (raffleId == 0) {
            emit OrphanCallback(sequence, provider);
            return;
        }
        RaffleData storage r = _raffles[raffleId];
        if (r.state != State.Drawing || r.sequence != sequence || r.provider != provider) {
            emit OrphanCallback(sequence, provider);
            return;
        }
        delete _raffleOfRequest[key];
        uint64 winningTicket = uint64(uint256(randomNumber) % r.totalTickets);
        r.randomNumber = randomNumber;
        r.winningTicket = winningTicket;
        r.state = State.Drawn;
        emit Drawn(raffleId, randomNumber, winningTicket);
    }

    /* ------------------------------------------------------------------ */
    /*                               SETTLE                                 */
    /* ------------------------------------------------------------------ */

    /// @notice Pay out a drawn raffle. Permissionless. Prize -> winner, fee tickets -> Pot,
    ///         leftover reserve -> creator (credited). A refused push becomes a credit for that
    ///         recipient alone.
    function settle(uint256 raffleId) external nonReentrant {
        RaffleData storage r = _raffles[raffleId];
        if (r.state != State.Drawn) revert WrongState(raffleId, r.state);
        r.state = State.Settled;

        address winner = _buyerOf(raffleId, r.winningTicket);
        r.winner = winner;

        uint256 potAmount = (uint256(r.totalTickets) - r.base) * TICKET_PRICE;
        Prize memory prize = r.prize;
        // The USDC this raffle still holds: its fee, plus the prize when it fell back to USDC.
        usdcLiability -= potAmount + (prize.kind == PrizeKind.Usdc ? prize.amount : 0);

        uint128 leftover = r.ethReserve;
        if (leftover != 0) {
            r.ethReserve = 0;
            ethOwed[r.creator] += leftover; // liability unchanged: reserve becomes a credit
            emit EthCredited(r.creator, leftover);
        }

        bool delivered = _deliverPrize(raffleId, prize, winner, false);
        _pushOrCreditUsdc(pot, potAmount);

        emit Settled(raffleId, winner, r.winningTicket, prize.kind, prize.amount, potAmount, delivered);
    }

    /* ------------------------------------------------------------------ */
    /*                         CREDITS (PERMISSIONLESS)                     */
    /* ------------------------------------------------------------------ */

    /// @notice Deliver an undelivered stock prize to its winner. Anyone may call; it only ever
    ///         pays the recorded winner. Reverts (moving nothing) while the transfer is refused.
    function claimPrize(uint256 raffleId) external nonReentrant {
        address winner = prizeOwedTo[raffleId];
        if (winner == address(0)) revert NothingOwed();
        delete prizeOwedTo[raffleId];
        _deliverPrize(raffleId, _raffles[raffleId].prize, winner, true);
        emit PrizeClaimed(raffleId, winner);
    }

    /// @notice Deliver credited USDC to `account`. Anyone may call; it only pays `account`.
    function withdrawUsdc(address account) external nonReentrant {
        uint256 amount = usdcOwed[account];
        if (amount == 0) revert NothingOwed();
        usdcOwed[account] = 0;
        usdcLiability -= amount;
        usdc.safeTransfer(account, amount);
        emit UsdcWithdrawn(account, amount);
    }

    /// @notice Deliver credited ETH to `account`. Anyone may call; it only pays `account`.
    function withdrawEth(address account) external nonReentrant {
        uint256 amount = ethOwed[account];
        if (amount == 0) revert NothingOwed();
        ethOwed[account] = 0;
        ethLiability -= amount;
        (bool ok,) = account.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit EthWithdrawn(account, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                     OWNER: FUTURE RAFFLES ONLY                       */
    /* ------------------------------------------------------------------ */

    function setFeeBps(uint32 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert BadConfig();
        feeBps = newFeeBps;
        emit FeeBpsSet(newFeeBps);
    }

    function setBaseLimits(uint64 newMinBase, uint64 newMaxBase) external onlyOwner {
        if (newMinBase == 0 || newMinBase > newMaxBase || newMaxBase > MAX_BASE_CEILING) revert BadConfig();
        minBase = newMinBase;
        maxBase = newMaxBase;
        emit BaseLimitsSet(newMinBase, newMaxBase);
    }

    function setRedrawTimeout(uint64 timeout) external onlyOwner {
        if (timeout < MIN_REDRAW_TIMEOUT || timeout > MAX_REDRAW_TIMEOUT) revert BadConfig();
        redrawTimeout = timeout;
        emit RedrawTimeoutSet(timeout);
    }

    function setAcquireTimeout(uint64 timeout) external onlyOwner {
        if (timeout < MIN_ACQUIRE_TIMEOUT || timeout > MAX_ACQUIRE_TIMEOUT) revert BadConfig();
        acquireTimeout = timeout;
        emit AcquireTimeoutSet(timeout);
    }

    /// @notice The price guard new raffles snapshot. Every field bounded; none may be zero.
    function setPriceGuard(PriceGuard calldata g) external onlyOwner {
        if (
            g.twapWindow < MIN_TWAP_WINDOW || g.twapWindow > MAX_TWAP_WINDOW || g.maxDeviationTicks == 0
                || g.maxDeviationTicks > MAX_DEVIATION_TICKS || g.maxSlippageBps == 0
                || g.maxSlippageBps > MAX_SLIPPAGE_BPS || g.maxPoolShareBps == 0
                || g.maxPoolShareBps > MAX_POOL_SHARE_BPS
        ) revert BadConfig();
        priceGuard = g;
        emit PriceGuardSet(g);
    }

    function setCallbackGasLimit(uint32 gasLimit) external onlyOwner {
        if (gasLimit < MIN_CALLBACK_GAS || gasLimit > MAX_CALLBACK_GAS) revert BadConfig();
        callbackGasLimit = gasLimit;
        emit CallbackGasLimitSet(gasLimit);
    }

    /// @notice Set (or clear, with zero) the automation account allowed to {acquirePrize} and
    ///         {retryDraw}.
    function setKeeper(address newKeeper) external onlyOwner {
        keeper = newKeeper;
        emit KeeperSet(newKeeper);
    }

    /* ------------------------------------------------------------------ */
    /*                                VIEWS                                 */
    /* ------------------------------------------------------------------ */

    function getRaffle(uint256 raffleId) external view returns (RaffleData memory) {
        return _raffles[raffleId];
    }

    function purchaseCount(uint256 raffleId) external view returns (uint256) {
        return _purchases[raffleId].length;
    }

    function purchaseAt(uint256 raffleId, uint256 index) external view returns (Purchase memory) {
        return _purchases[raffleId][index];
    }

    /// @notice Who holds ticket `ticket` (0-based) of a raffle.
    function buyerOf(uint256 raffleId, uint64 ticket) external view returns (address) {
        uint64 sold = _raffles[raffleId].sold;
        if (ticket >= sold) revert TicketOutOfRange(ticket, sold);
        return _buyerOf(raffleId, ticket);
    }

    /// @notice Tickets a raffle with `base` would have at the current fee.
    function ticketsFor(uint64 base) external view returns (uint64) {
        return _ticketsFor(base, feeBps);
    }

    /// @notice The stock `usdcAmount` buys at the pool's current TWAP (before slippage), using
    ///         the current price guard's window. For "≈ X shares" displays; 0 when unavailable.
    function quotePrize(address stock, uint256 usdcAmount) external view returns (uint256 stockOut) {
        (Refusal why, address pool,) = _poolFor(stock);
        if (why != Refusal.None) return 0;
        (bool ok, int24 twapTick) = _twapTick(pool, priceGuard.twapWindow);
        if (!ok) return 0;
        (uint160 sqrtPriceX96, int24 spotTick,,,,) = ISlipstreamPool(pool).slot0();
        if (_absDiff(spotTick, twapTick) > MAX_DEVIATION_TICKS) return 0;
        return _refOut(sqrtPriceX96, spotTick, twapTick, usdcAmount, ISlipstreamPool(pool).token0() == address(usdc));
    }

    /// @notice What one draw costs in ETH right now.
    function quoteDrawFee() public view returns (uint128) {
        IEntropyV2 e = IEntropyV2(entropy);
        return e.getFeeV2(e.getDefaultProvider(), callbackGasLimit);
    }

    /// @notice The minimum ETH {createRaffle} accepts right now.
    function requiredReserve() external view returns (uint256) {
        return RESERVE_MULTIPLIER * uint256(quoteDrawFee());
    }

    /* ------------------------------------------------------------------ */
    /*                         INTERNAL: THE PRIZE                          */
    /* ------------------------------------------------------------------ */

    /// @dev The stock's pool, if the stock can be bought through {router} right now. Returns a
    ///      non-empty reason otherwise. The pool must be the one the router actually swaps in:
    ///      the registry's pool == factory.getPool(USDC, stock, tickSpacing), paired USDC/stock.
    function _poolFor(address stock) internal view returns (Refusal why, address pool, int24 spacing) {
        Stock memory s = registry.getStock(stock);
        if (!s.registered || !s.enabled) return (Refusal.StockDisabled, address(0), 0);
        if (s.venue != Venue.Slipstream) return (Refusal.NotSlipstream, address(0), 0);
        pool = s.pool;
        spacing = s.tickSpacing;
        if (pool == address(0) || ISlipstreamFactory(factory).getPool(address(usdc), stock, spacing) != pool) {
            return (Refusal.PoolMismatch, address(0), 0);
        }
        address t0 = ISlipstreamPool(pool).token0();
        address t1 = ISlipstreamPool(pool).token1();
        if (!((t0 == address(usdc) && t1 == stock) || (t0 == stock && t1 == address(usdc)))) {
            return (Refusal.PoolMismatch, address(0), 0);
        }
        if (ISlipstreamPool(pool).tickSpacing() != spacing) return (Refusal.PoolMismatch, address(0), 0);
    }

    /// @dev Arithmetic-mean tick over the last `window` seconds from the pool oracle, rounded
    ///      toward negative infinity. (false, 0) when the oracle cannot answer — e.g. its
    ///      observation buffer does not reach `window` back.
    function _twapTick(address pool, uint32 window) internal view returns (bool ok, int24 tick) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        try ISlipstreamPool(pool).observe(ago) returns (int56[] memory cum, uint160[] memory) {
            if (cum.length != 2) return (false, 0);
            int56 delta = cum[1] - cum[0];
            int56 w = int56(uint56(window));
            int56 mean = delta / w;
            if (delta < 0 && delta % w != 0) mean--;
            if (mean < type(int24).min || mean > type(int24).max) return (false, 0);
            return (true, int24(mean));
        } catch {
            return (false, 0);
        }
    }

    /// @dev Raw stock units `usdcIn` buys at the TWAP price. Computed as the exact SPOT output
    ///      (from slot0's sqrtPrice) scaled by 1.0001^(twapTick - spotTick), so no tick-to-
    ///      sqrtPrice table is needed. The exponent is bounded by the deviation guard
    ///      (|k| <= 500). Accurate to within one tick (~1 bp): slot0's tick is the floor of the
    ///      spot price's tick.
    function _refOut(uint160 sqrtPriceX96, int24 spotTick, int24 twapTick, uint256 usdcIn, bool usdcIsToken0)
        internal
        pure
        returns (uint256)
    {
        uint256 spotOut = _spotOut(sqrtPriceX96, usdcIn, usdcIsToken0);
        // A higher tick means more token1 per token0. Buying token1 with token0 at a higher
        // tick yields more; buying token0 with token1 yields less.
        int256 k = int256(twapTick) - int256(spotTick);
        if (!usdcIsToken0) k = -k;
        if (k >= 0) return Math.mulDiv(spotOut, _tickPowWad(uint256(k)), WAD);
        return Math.mulDiv(spotOut, WAD, _tickPowWad(uint256(-k)));
    }

    /// @dev Output of `amountIn` at the pool's spot price, sqrtPriceX96^2 / 2^192 being token1
    ///      per token0. Two branches keep the square inside 256 bits.
    function _spotOut(uint160 sqrtPriceX96, uint256 amountIn, bool zeroForOne) internal pure returns (uint256) {
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            return zeroForOne
                ? Math.mulDiv(ratioX192, amountIn, 1 << 192)
                : Math.mulDiv(1 << 192, amountIn, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        return zeroForOne ? Math.mulDiv(ratioX128, amountIn, 1 << 128) : Math.mulDiv(1 << 128, amountIn, ratioX128);
    }

    /// @dev 1.0001^n in WAD, by binary exponentiation. Only ever called with n <= 500.
    function _tickPowWad(uint256 n) internal pure returns (uint256 result) {
        result = WAD;
        uint256 b = TICK_BASE_WAD;
        while (n != 0) {
            if (n & 1 != 0) result = Math.mulDiv(result, b, WAD);
            b = Math.mulDiv(b, b, WAD);
            n >>= 1;
        }
    }

    /// @dev Every pre-swap check of {acquirePrize}, and the swap's floor. Reverts
    ///      {AcquireRefused} with the reason when any check fails.
    function _priceCheck(uint256 raffleId, RaffleData storage r)
        internal
        view
        returns (uint256 minOut, int24 twapTick, int24 spotTick)
    {
        (Refusal why, address pool,) = _poolFor(r.stock);
        if (why != Refusal.None) revert AcquireRefused(raffleId, why);
        // The registry may have re-pointed the stock since creation; buy only in the pool the
        // raffle's guard was validated against.
        if (pool != r.pool) revert AcquireRefused(raffleId, Refusal.PoolMismatch);

        PriceGuard memory g = r.guard;
        uint256 budget = uint256(r.base) * TICKET_PRICE;
        if (budget > _poolCap(pool, g.maxPoolShareBps)) revert AcquireRefused(raffleId, Refusal.TooLargeForPool);

        bool twapOk;
        (twapOk, twapTick) = _twapTick(pool, g.twapWindow);
        if (!twapOk) revert AcquireRefused(raffleId, Refusal.TwapUnavailable);
        uint160 sqrtPriceX96;
        (sqrtPriceX96, spotTick,,,,) = ISlipstreamPool(pool).slot0();
        if (_absDiff(spotTick, twapTick) > g.maxDeviationTicks) revert AcquireRefused(raffleId, Refusal.SpotDeviates);

        uint256 refOut =
            _refOut(sqrtPriceX96, spotTick, twapTick, budget, ISlipstreamPool(pool).token0() == address(usdc));
        minOut = (refOut * (BPS - g.maxSlippageBps)) / BPS;
        if (minOut == 0) revert AcquireRefused(raffleId, Refusal.NoOutput);
    }

    /// @dev The most a single prize buy may spend: a share of the USDC sitting in the pool.
    ///      Raw balance, no oracle.
    function _poolCap(address pool, uint16 shareBps) internal view returns (uint256) {
        return (usdc.balanceOf(pool) * shareBps) / BPS;
    }

    /// @dev The ChipRounds `_buy` pattern: exact approval, exactInputSingle with a floor,
    ///      approval reset, and both legs MEASURED by balance delta. Reverts {SwapReverted} or
    ///      {AcquireRefused} on any failure — which, being a revert, also undoes anything that did move.
    function _swap(uint256 raffleId, RaffleData storage r, uint256 minOut)
        internal
        returns (uint256 received, uint256 spent)
    {
        address stock = r.stock;
        uint256 budget = uint256(r.base) * TICKET_PRICE;
        uint256 stockBefore = IERC20(stock).balanceOf(address(this));
        uint256 usdcBefore = usdc.balanceOf(address(this));
        usdc.forceApprove(address(router), budget);
        try router.exactInputSingle(
            ISlipstreamSwapRouter.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: stock,
                tickSpacing: r.tickSpacing,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: budget,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256) {
            // the router's return value is not trusted; balances are measured below
        } catch (bytes memory err) {
            revert SwapReverted(raffleId, err);
        }
        usdc.forceApprove(address(router), 0);

        received = IERC20(stock).balanceOf(address(this)) - stockBefore;
        spent = usdcBefore - usdc.balanceOf(address(this));
        if (spent != budget) revert AcquireRefused(raffleId, Refusal.PartialSpend);
        if (received < minOut) revert AcquireRefused(raffleId, Refusal.UnderDelivered);
    }

    function _absDiff(int24 a, int24 b) internal pure returns (uint256) {
        int256 d = int256(a) - int256(b);
        return d >= 0 ? uint256(d) : uint256(-d);
    }

    /// @dev `strict` (claim): revert if refused, so the prize stays owed.
    ///      Non-strict (settle): a refused STOCK becomes {prizeOwedTo}; a refused USDC prize
    ///      becomes a {usdcOwed} credit. Future prize kinds plug in here.
    function _deliverPrize(uint256 raffleId, Prize memory prize, address winner, bool strict)
        internal
        returns (bool delivered)
    {
        if (prize.kind == PrizeKind.Usdc) {
            return _pushOrCreditUsdc(winner, prize.amount);
        }
        erc20PrizeEscrow[prize.token] -= prize.amount;
        if (strict) {
            IERC20(prize.token).safeTransfer(winner, prize.amount);
            return true;
        }
        if (_tryTransfer(prize.token, winner, prize.amount)) return true;
        erc20PrizeEscrow[prize.token] += prize.amount;
        prizeOwedTo[raffleId] = winner;
        return false;
    }

    /// @return pushed True when `amount` reached `to` now; false when it was credited instead.
    function _pushOrCreditUsdc(address to, uint256 amount) internal returns (bool pushed) {
        if (amount == 0) return true;
        if (_tryTransfer(address(usdc), to, amount)) return true;
        usdcOwed[to] += amount;
        usdcLiability += amount;
        emit UsdcCredited(to, amount);
        return false;
    }

    /// @dev A transfer that reports failure instead of reverting. Success is no return data
    ///      from a contract, or exactly one word equal to 1; anything else is "refused".
    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) return false;
        if (ret.length == 0) return token.code.length != 0;
        // Decoded as uint256 so a malformed word reads as "refused" instead of reverting.
        if (ret.length == 32) return abi.decode(ret, (uint256)) == 1;
        return false;
    }

    /* ------------------------------------------------------------------ */
    /*                         INTERNAL: THE DRAW                           */
    /* ------------------------------------------------------------------ */

    function _topUp(uint256 raffleId, RaffleData storage r) internal {
        if (msg.value == 0) return;
        r.ethReserve += uint128(msg.value);
        ethLiability += msg.value;
        emit ReserveToppedUp(raffleId, msg.sender, msg.value);
    }

    /// @dev Reverting request path ({requestDraw}, {retryDraw}).
    function _requestDraw(uint256 raffleId, RaffleData storage r) internal {
        IEntropyV2 e = IEntropyV2(entropy);
        address provider = e.getDefaultProvider();
        uint32 gasLimit = callbackGasLimit;
        uint128 fee = e.getFeeV2(provider, gasLimit);
        if (r.ethReserve < fee) revert ReserveTooLow(r.ethReserve, fee);
        r.ethReserve -= fee;
        ethLiability -= fee;
        bytes32 seed = _drawSeed(raffleId, r);
        uint64 sequence = e.requestV2{value: fee}(provider, seed, gasLimit);
        _recordRequest(raffleId, r, provider, sequence, fee, seed);
    }

    /// @dev Non-reverting request path ({acquirePrize}, {fallbackToUsdc}). Any failure leaves the
    ///      raffle PrizeReady with its reserve untouched.
    function _tryRequestDraw(uint256 raffleId, RaffleData storage r) internal returns (bool) {
        IEntropyV2 e = IEntropyV2(entropy);
        uint32 gasLimit = callbackGasLimit;
        address provider;
        try e.getDefaultProvider() returns (address p) {
            provider = p;
        } catch {
            return false;
        }
        uint128 fee;
        try e.getFeeV2(provider, gasLimit) returns (uint128 f) {
            fee = f;
        } catch {
            return false;
        }
        if (r.ethReserve < fee) return false;
        bytes32 seed = _drawSeed(raffleId, r);
        try e.requestV2{value: fee}(provider, seed, gasLimit) returns (uint64 sequence) {
            r.ethReserve -= fee;
            ethLiability -= fee;
            _recordRequest(raffleId, r, provider, sequence, fee, seed);
            return true;
        } catch {
            return false;
        }
    }

    /// @dev The caller's contribution to Entropy's commit-reveal (Pyth's `userRandomNumber`).
    ///      Entropy combines it with the provider's pre-committed revelation. Mixed from this
    ///      contract, the raffle, a per-request nonce, the final ticket count, the last buyer,
    ///      the previous block's hash, prevrandao and the timestamp, so every request
    ///      (including a retry) gets a distinct seed. It is not secret and does not need to be.
    function _drawSeed(uint256 raffleId, RaffleData storage r) internal returns (bytes32) {
        Purchase[] storage p = _purchases[raffleId];
        return keccak256(
            abi.encode(
                address(this),
                raffleId,
                ++_drawNonce,
                r.sold,
                p[p.length - 1].buyer,
                blockhash(block.number - 1),
                block.prevrandao,
                block.timestamp
            )
        );
    }

    function _recordRequest(
        uint256 raffleId,
        RaffleData storage r,
        address provider,
        uint64 sequence,
        uint128 fee,
        bytes32 seed
    ) internal {
        r.provider = provider;
        r.sequence = sequence;
        r.drawRequestedAt = uint64(block.timestamp);
        r.state = State.Drawing;
        _raffleOfRequest[_requestKey(provider, sequence)] = raffleId;
        emit DrawRequested(raffleId, provider, sequence, fee, seed);
    }

    /// @dev Binary search: the first purchase whose endExclusive is greater than `ticket`.
    function _buyerOf(uint256 raffleId, uint64 ticket) internal view returns (address) {
        Purchase[] storage p = _purchases[raffleId];
        uint256 lo;
        uint256 hi = p.length - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (p[mid].endExclusive > ticket) hi = mid;
            else lo = mid + 1;
        }
        return p[lo].buyer;
    }

    /// @dev base + ceil(base * fee / BPS): the fee is added ON TOP of the prize, rounded up.
    ///      base <= 1,000,000 and fee <= 2,000, so the cast cannot truncate.
    function _ticketsFor(uint64 base, uint32 fee) internal pure returns (uint64) {
        return base + uint64((uint256(base) * fee + BPS - 1) / BPS);
    }

    function _requestKey(address provider, uint64 sequence) internal pure returns (bytes32) {
        return keccak256(abi.encode(provider, sequence));
    }
}
