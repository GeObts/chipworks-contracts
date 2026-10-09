// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IEntropyV2} from "../interfaces/IEntropyV2.sol";
import {IStockRegistry} from "../interfaces/IStockRegistry.sol";

/// @title  Raffle
/// @notice House-run raffles for an escrowed prize, sold as $1 USDC tickets.
///
/// @dev    SPEC: specs/raffle/SPEC.md. The rules that shape everything below:
///
///         ONLY THE HOUSE CREATES. {createRaffle} is owner-only (the Safe). Nobody else can
///         list a prize, so there is no user-raffle attack surface (mis-priced prizes, spam).
///
///         NO EXIT, BY DESIGN. A raffle has no deadline, refund, cancel or withdraw. Prize,
///         ticket money and the Entropy ETH reserve stay escrowed until every ticket sells.
///         The owner has NO function that can move a prize, ticket money or a reserve — its
///         powers are limited to parameters for FUTURE raffles. Non-upgradeable.
///
///         TICKETS ARE RANGES. A purchase of `qty` tickets is one storage slot
///         (buyer, endExclusive). The winner of ticket `t` is found by binary search over
///         purchases — O(log P) — so neither buying nor drawing loops over tickets.
///
///         RANDOMNESS IS PYTH ENTROPY V2, reused from the Box. The final ticket's purchase
///         requests it, paid from an ETH reserve the house posts at creation, so the last
///         buyer pays gas only. If the request cannot be made then (fee spike, Entropy
///         down) the purchase still succeeds and anyone can {requestDraw} later. Each request
///         passes Entropy a contract-mixed `userRandomNumber` (see {_drawSeed}). The callback
///         only RECORDS the number — no transfers, no search — so it cannot fail.
///
///         FRESH RANDOMNESS IS GATED. {retryDraw} (only for a draw Entropy never revealed) may be
///         called by the owner, the raffle's payee or the keeper, and only after the redraw
///         timeout SNAPSHOTTED into that raffle at creation.
///
///         PAYOUTS ARE ISOLATED. {settle} is permissionless. It tries to push each leg
///         (prize -> winner, base -> payee, fee -> Pot) and CREDITS any leg whose transfer is
///         refused (B20s and USDC refuse sanctioned addresses), so one bad recipient never
///         freezes the others. Every credit has a fixed recipient and anyone may deliver it.
contract Raffle is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ------------------------------------------------------------------ */
    /*                               TYPES                                  */
    /* ------------------------------------------------------------------ */

    /// @notice What a prize is. ERC721 ships in the code but is OFF at launch
    ///         ({nftPrizesEnabled} false); turning it on is a Safe call, not a redeploy.
    enum PrizeKind {
        ERC20,
        ERC721
    }

    struct Prize {
        PrizeKind kind;
        address token;
        /// @dev ERC20: amount in the token's units. ERC721: the token id.
        uint256 amountOrId;
    }

    enum State {
        None,
        Open, // selling tickets
        SoldOut, // every ticket sold, draw not yet requested (needs {requestDraw})
        Drawing, // Entropy requested, waiting for the reveal
        Drawn, // random number recorded, waiting for {settle}
        Settled
    }

    struct RaffleData {
        Prize prize;
        /// @notice Receives `base` USDC at settle. Set by the house at creation.
        address payee;
        uint32 feeBps;
        State state;
        uint64 base;
        uint64 totalTickets;
        uint64 sold;
        uint64 drawRequestedAt;
        uint64 sequence;
        uint64 winningTicket;
        address provider;
        address winner;
        uint128 ethReserve;
        bytes32 randomNumber;
        /// @notice {redrawTimeout} at creation. Later {setRedrawTimeout} calls never change it.
        uint64 redrawTimeout;
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
    /// @notice Hard ceiling on {maxBase}; the launch value is far below it.
    uint64 public constant MAX_BASE_CEILING = 1_000_000;
    uint64 public constant MIN_REDRAW_TIMEOUT = 1 hours;
    uint64 public constant MAX_REDRAW_TIMEOUT = 30 days;
    uint32 public constant MIN_CALLBACK_GAS = 100_000;
    uint32 public constant MAX_CALLBACK_GAS = 1_000_000;
    /// @notice The reserve posted at creation must cover this many draw fees at today's price.
    uint256 public constant RESERVE_MULTIPLIER = 3;
    /// @dev EntropyStatusConstants.CALLBACK_NOT_STARTED: requested, never revealed.
    uint8 internal constant CALLBACK_NOT_STARTED = 1;

    /* ------------------------------------------------------------------ */
    /*                             IMMUTABLES                               */
    /* ------------------------------------------------------------------ */

    IERC20 public immutable usdc;
    address public immutable entropy;
    IStockRegistry public immutable registry;
    /// @notice Where every raffle's fee tickets go. Immutable: it can never be redirected.
    address public immutable pot;

    /* ------------------------------------------------------------------ */
    /*                    PARAMETERS (FUTURE RAFFLES ONLY)                  */
    /* ------------------------------------------------------------------ */

    /// @notice Fee in bps of `base`, snapshotted per raffle at creation.
    uint32 public feeBps = 1_000;
    uint64 public minBase = 10;
    uint64 public maxBase = 1_000;
    /// @notice How long a draw must sit completely unrevealed before {retryDraw} may request
    ///         FRESH randomness. Snapshotted into each raffle at creation; changing it only
    ///         affects raffles created afterwards.
    uint64 public redrawTimeout;
    uint32 public callbackGasLimit = 200_000;
    bool public nftPrizesEnabled;
    mapping(address collection => bool) public nftCollectionAllowed;
    /// @notice The automation account allowed to call {retryDraw} (besides the owner and the
    ///         raffle's payee). Zero = none. It has no other power.
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
    /// @notice ETH reserve left over after a draw, owed to the raffle's payee.
    mapping(address account => uint256) public ethOwed;
    /// @notice The winner of a raffle whose prize has not been delivered yet (zero once delivered).
    mapping(uint256 raffleId => address) public prizeOwedTo;

    /// @notice USDC the contract must hold: ticket money of unsettled raffles + {usdcOwed}.
    uint256 public usdcLiability;
    /// @notice ETH the contract must hold: live reserves + {ethOwed}.
    uint256 public ethLiability;
    /// @notice ERC-20 prize units the contract must hold, per token.
    mapping(address token => uint256) public erc20PrizeEscrow;

    /* ------------------------------------------------------------------ */
    /*                               EVENTS                                 */
    /* ------------------------------------------------------------------ */

    event RaffleCreated(
        uint256 indexed raffleId,
        address indexed payee,
        PrizeKind kind,
        address indexed prizeToken,
        uint256 amountOrId,
        uint64 base,
        uint64 totalTickets,
        uint32 feeBps,
        uint128 ethReserve
    );
    event TicketsBought(uint256 indexed raffleId, address indexed buyer, uint64 firstTicket, uint64 quantity);
    event SoldOut(uint256 indexed raffleId);
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
        uint256 payeeUsdc,
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
    event CallbackGasLimitSet(uint32 gasLimit);
    event NftPrizesEnabledSet(bool enabled);
    event NftCollectionSet(address indexed collection, bool allowed);
    event KeeperSet(address indexed keeper);

    /* ------------------------------------------------------------------ */
    /*                               ERRORS                                 */
    /* ------------------------------------------------------------------ */

    error ZeroAddress();
    error BadConfig();
    error UsdcNotSixDecimals(uint8 decimals);
    error BaseOutOfRange(uint64 base, uint64 minBase, uint64 maxBase);
    error PrizeNotAllowed(address token);
    error NftPrizesDisabled();
    error ZeroPrize();
    error PrizeNotReceived(uint256 expected, uint256 received);
    error ReserveTooLow(uint256 sent, uint256 required);
    error WrongState(uint256 raffleId, State state);
    error ZeroQuantity();
    error NotEnoughTickets(uint64 requested, uint64 remaining);
    error OnlyEntropy();
    error RedrawNotReady(uint64 nowTs, uint64 readyAt);
    error RevealAlreadyPublic(uint256 raffleId, uint8 callbackStatus);
    error NothingOwed();
    error EthTransferFailed();
    error TicketOutOfRange(uint64 ticket, uint64 sold);
    error NotAuthorized(address caller);

    /* ------------------------------------------------------------------ */
    /*                            CONSTRUCTOR                               */
    /* ------------------------------------------------------------------ */

    /// @param owner_         The house (the Safe). Only it can create raffles.
    /// @param usdc_          Circle USDC on Base (must report 6 decimals).
    /// @param entropy_       Pyth Entropy v2. Base: 0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb.
    /// @param registry_      ChipWorks StockRegistry: only its ENABLED tokens can be ERC-20 prizes.
    /// @param pot_           ChipWorks Pot: receives every raffle's fee tickets. Immutable.
    /// @param redrawTimeout_ See {redrawTimeout}. Bounded [1 hour, 30 days].
    constructor(
        address owner_,
        address usdc_,
        address entropy_,
        address registry_,
        address pot_,
        uint64 redrawTimeout_
    ) Ownable(owner_) {
        if (usdc_ == address(0) || entropy_ == address(0) || registry_ == address(0) || pot_ == address(0)) {
            revert ZeroAddress();
        }
        uint8 d = IERC20Metadata(usdc_).decimals();
        if (d != 6) revert UsdcNotSixDecimals(d);
        if (redrawTimeout_ < MIN_REDRAW_TIMEOUT || redrawTimeout_ > MAX_REDRAW_TIMEOUT) revert BadConfig();
        usdc = IERC20(usdc_);
        entropy = entropy_;
        registry = IStockRegistry(registry_);
        pot = pot_;
        redrawTimeout = redrawTimeout_;
    }

    /* ------------------------------------------------------------------ */
    /*                              CREATE                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Open a raffle. House only. Pulls the prize from the caller (approve first) and
    ///         keeps `msg.value` as the raffle's Entropy reserve.
    /// @param prize  ERC20: a StockRegistry-enabled token and an amount. ERC721: only when
    ///               {nftPrizesEnabled} and the collection is allow-listed.
    /// @param base   The house's asking, in whole USD. Tickets = base + ceil(base*feeBps/10000).
    /// @param payee  Receives `base` USDC at settle and the leftover ETH reserve (as a credit paid
    ///               by {withdrawEth} with a plain call). MUST be an EOA or a contract that can
    ///               receive ETH, or that credit can never be withdrawn.
    function createRaffle(Prize calldata prize, uint64 base, address payee)
        external
        payable
        onlyOwner
        nonReentrant
        returns (uint256 raffleId)
    {
        if (payee == address(0) || prize.token == address(0)) revert ZeroAddress();
        // base >= minBase >= 1 already (setBaseLimits refuses 0); explicit so N can never be 0.
        if (base == 0 || base < minBase || base > maxBase) revert BaseOutOfRange(base, minBase, maxBase);
        _validatePrize(prize);

        uint256 required = RESERVE_MULTIPLIER * uint256(quoteDrawFee());
        if (msg.value < required) revert ReserveTooLow(msg.value, required);

        uint32 fee = feeBps;
        uint64 total = _ticketsFor(base, fee);

        raffleId = ++raffleCount;
        RaffleData storage r = _raffles[raffleId];
        r.prize = prize;
        r.payee = payee;
        r.feeBps = fee;
        r.state = State.Open;
        r.base = base;
        r.totalTickets = total;
        r.redrawTimeout = redrawTimeout;
        r.ethReserve = uint128(msg.value);
        ethLiability += msg.value;

        _escrowPrize(prize);

        emit RaffleCreated(raffleId, payee, prize.kind, prize.token, prize.amountOrId, base, total, fee, uint128(msg.value));
    }

    /* ------------------------------------------------------------------ */
    /*                                BUY                                   */
    /* ------------------------------------------------------------------ */

    /// @notice Buy `quantity` tickets at 1 USDC each (approve USDC first). Any number, by anyone,
    ///         until the raffle sells out. There is no refund: the money stays escrowed until the
    ///         last ticket sells and the draw settles.
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
            emit SoldOut(raffleId);
            // The last buyer is never penalised: if the draw can't be requested right now the
            // purchase still stands and anyone can {requestDraw} later.
            if (!_tryRequestDraw(raffleId, r)) emit DrawAwaitingRequest(raffleId);
        }
    }

    /* ------------------------------------------------------------------ */
    /*                                DRAW                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Request the draw for a sold-out raffle whose automatic request did not go through.
    ///         Permissionless. Any ETH sent tops up the raffle's reserve (leftover reserve goes to
    ///         the payee at settle, so send only the shortfall: {quoteDrawFee} - reserve).
    function requestDraw(uint256 raffleId) external payable nonReentrant {
        RaffleData storage r = _raffles[raffleId];
        if (r.state != State.SoldOut) revert WrongState(raffleId, r.state);
        _topUp(raffleId, r);
        _requestDraw(raffleId, r);
    }

    /// @notice Ask Entropy for FRESH randomness when a draw has gone completely unrevealed for
    ///         the raffle's snapshotted redraw timeout. Owner, the raffle's payee or {keeper}
    ///         only — never a ticket holder, so nobody holding a ticket can choose to re-roll.
    ///         Any ETH sent tops up the reserve.
    /// @dev    NOT A RE-ROLL. A FAILED callback means Pyth already published the number; the
    ///         fix for that is Pyth's permissionless `revealWithCallback`, which re-runs our
    ///         callback with the SAME number. So this refuses anything but CALLBACK_NOT_STARTED.
    ///         Residual risk (see spec): a provider's revelation can be readable off chain
    ///         before it lands on chain; the keeper must complete stuck reveals well inside
    ///         {redrawTimeout} so a ticket holder cannot read a losing number and redraw.
    function retryDraw(uint256 raffleId) external payable nonReentrant {
        RaffleData storage r = _raffles[raffleId];
        if (r.state != State.Drawing) revert WrongState(raffleId, r.state);
        if (msg.sender != owner() && msg.sender != r.payee && msg.sender != keeper) revert NotAuthorized(msg.sender);
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

    /// @notice Pay out a drawn raffle. Permissionless. Prize -> winner, `base` USDC -> payee,
    ///         fee tickets -> Pot, leftover reserve -> payee (credited). A refused push becomes a
    ///         credit for that recipient alone.
    function settle(uint256 raffleId) external nonReentrant {
        RaffleData storage r = _raffles[raffleId];
        if (r.state != State.Drawn) revert WrongState(raffleId, r.state);
        r.state = State.Settled;

        address winner = _buyerOf(raffleId, r.winningTicket);
        r.winner = winner;

        uint256 proceeds = uint256(r.totalTickets) * TICKET_PRICE;
        uint256 payeeAmount = uint256(r.base) * TICKET_PRICE;
        uint256 potAmount = proceeds - payeeAmount;
        usdcLiability -= proceeds;

        uint128 leftover = r.ethReserve;
        if (leftover != 0) {
            r.ethReserve = 0;
            ethOwed[r.payee] += leftover; // liability unchanged: reserve becomes a credit
            emit EthCredited(r.payee, leftover);
        }

        bool delivered = _deliverPrize(raffleId, r.prize, winner, false);
        _pushOrCreditUsdc(r.payee, payeeAmount);
        _pushOrCreditUsdc(pot, potAmount);

        emit Settled(raffleId, winner, r.winningTicket, payeeAmount, potAmount, delivered);
    }

    /* ------------------------------------------------------------------ */
    /*                         CREDITS (PERMISSIONLESS)                     */
    /* ------------------------------------------------------------------ */

    /// @notice Deliver an undelivered prize to its winner. Anyone may call; it only ever pays
    ///         the recorded winner. Reverts (moving nothing) while the transfer is refused.
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

    function setCallbackGasLimit(uint32 gasLimit) external onlyOwner {
        if (gasLimit < MIN_CALLBACK_GAS || gasLimit > MAX_CALLBACK_GAS) revert BadConfig();
        callbackGasLimit = gasLimit;
        emit CallbackGasLimitSet(gasLimit);
    }

    function setNftPrizesEnabled(bool enabled) external onlyOwner {
        nftPrizesEnabled = enabled;
        emit NftPrizesEnabledSet(enabled);
    }

    /// @notice Set (or clear, with zero) the automation account allowed to call {retryDraw}.
    function setKeeper(address newKeeper) external onlyOwner {
        keeper = newKeeper;
        emit KeeperSet(newKeeper);
    }

    function setNftCollectionAllowed(address collection, bool allowed) external onlyOwner {
        if (collection == address(0)) revert ZeroAddress();
        nftCollectionAllowed[collection] = allowed;
        emit NftCollectionSet(collection, allowed);
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
    /*                              INTERNAL                                */
    /* ------------------------------------------------------------------ */

    function _validatePrize(Prize calldata prize) internal view {
        if (prize.kind == PrizeKind.ERC20) {
            if (prize.amountOrId == 0) revert ZeroPrize();
            if (!registry.isEnabled(prize.token)) revert PrizeNotAllowed(prize.token);
        } else {
            if (!nftPrizesEnabled) revert NftPrizesDisabled();
            if (!nftCollectionAllowed[prize.token]) revert PrizeNotAllowed(prize.token);
        }
    }

    /// @dev Pull the prize and prove it arrived in full (no fee-on-transfer shortfall).
    function _escrowPrize(Prize calldata prize) internal {
        if (prize.kind == PrizeKind.ERC20) {
            IERC20 token = IERC20(prize.token);
            uint256 before = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), prize.amountOrId);
            uint256 received = token.balanceOf(address(this)) - before;
            if (received != prize.amountOrId) revert PrizeNotReceived(prize.amountOrId, received);
            erc20PrizeEscrow[prize.token] += prize.amountOrId;
        } else {
            IERC721(prize.token).transferFrom(msg.sender, address(this), prize.amountOrId);
            if (IERC721(prize.token).ownerOf(prize.amountOrId) != address(this)) {
                revert PrizeNotReceived(1, 0);
            }
        }
    }

    /// @dev `strict` (claim): revert if refused, so the prize stays owed.
    ///      Non-strict (settle): an ERC-20 refusal, and every ERC-721, becomes {prizeOwedTo} —
    ///      an NFT is never pushed during settle so a receiver's code can't run there.
    ///      ERC-721 is released with `transferFrom`, NOT `safeTransferFrom`, BY DESIGN: no
    ///      receiver hook ever runs in this contract's context, so a hostile winner contract
    ///      can neither revert nor re-enter the claim. The cost is that a winner contract which
    ///      cannot handle ERC-721s receives a token it cannot use; that only affects the winner.
    function _deliverPrize(uint256 raffleId, Prize memory prize, address winner, bool strict)
        internal
        returns (bool delivered)
    {
        if (prize.kind == PrizeKind.ERC20) {
            erc20PrizeEscrow[prize.token] -= prize.amountOrId;
            if (strict) {
                IERC20(prize.token).safeTransfer(winner, prize.amountOrId);
                return true;
            }
            if (_tryTransfer(prize.token, winner, prize.amountOrId)) return true;
            erc20PrizeEscrow[prize.token] += prize.amountOrId;
            prizeOwedTo[raffleId] = winner;
            return false;
        }
        if (strict) {
            IERC721(prize.token).transferFrom(address(this), winner, prize.amountOrId);
            return true;
        }
        prizeOwedTo[raffleId] = winner;
        return false;
    }

    function _pushOrCreditUsdc(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (_tryTransfer(address(usdc), to, amount)) return;
        usdcOwed[to] += amount;
        usdcLiability += amount;
        emit UsdcCredited(to, amount);
    }

    /// @dev A transfer that reports failure instead of reverting. Handles tokens that return
    ///      nothing, and refuses a "success" from an address with no code.
    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) return false;
        if (ret.length == 0) return token.code.length != 0;
        // Exactly one word, and exactly 1. Decoded as uint256 so a malformed word reads as
        // "refused" instead of reverting (a bool decode reverts on anything but 0 or 1).
        if (ret.length == 32) return abi.decode(ret, (uint256)) == 1;
        return false;
    }

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

    /// @dev Non-reverting request path, used inside the final {buy}. Any failure leaves the raffle
    ///      SoldOut with its reserve untouched.
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
    ///      Entropy combines it with the provider's pre-committed revelation, so neither side
    ///      alone fixes the result. Mixed from this contract, the raffle, a per-request nonce,
    ///      the final ticket count, the last buyer, the previous block's hash, prevrandao and
    ///      the timestamp, so every request (including a retry) gets a distinct seed. It is not
    ///      secret and does not need to be: the provider's revelation is committed before the
    ///      request and unknown until reveal, so knowing the seed predicts nothing.
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

    /// @dev base + ceil(base * fee / BPS): the Pot never gets less than `fee` of the base.
    ///      base <= 1,000,000 and fee <= 2,000, so the cast cannot truncate.
    function _ticketsFor(uint64 base, uint32 fee) internal pure returns (uint64) {
        return base + uint64((uint256(base) * fee + BPS - 1) / BPS);
    }

    function _requestKey(address provider, uint64 sequence) internal pure returns (bytes32) {
        return keccak256(abi.encode(provider, sequence));
    }
}
