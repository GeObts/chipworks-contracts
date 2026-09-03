// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Anvil
/// @notice Buy a Noun from the protocol's shelf at a fixed price, in ETH.
///
/// @dev ONE-DIRECTIONAL AT LAUNCH, AND THE CONTRACT SAYS SO OUT LOUD.
///
///      The Anvil is meant to be a two-way market: a fixed price to buy, and a guaranteed
///      exit to sell into. **Only the buy side ships now.** The sell side is a real product
///      commitment with real solvency questions — what backs the bid, what happens when the
///      backing runs out, who is left holding the floor — and it is not going out before an
///      audit. {sellToAnvil} exists as a stub that always reverts {SellNotOpen}, and
///      {sellEnabled} is readable so the site can show the state honestly rather than hiding
///      a feature that does not exist. **There is deliberately NO setter for that flag**: a
///      switch that exposes an unimplemented function is worse than no switch, so turning
///      the sell side on means deploying the version that implements it.
///
///      TWO WAYS TO BUY, AND THE DIFFERENCE IS THE POINT.
///
///      - {buyNext} — "the Box". Pays `queuePrice` for **the oldest Noun on the shelf**.
///        You do not choose. This is the cheap way in and it is FIFO **by design**: it is
///        next in line, not random, and not a lottery. Anyone can read exactly which token
///        they will receive before they call it ({nextOnShelf}), so it is a queue with a
///        known head rather than a gacha pull. Said plainly because "mystery box" invites
///        the opposite assumption, and the honest framing is the one that survives contact
///        with a disappointed buyer.
///      - {snipe} — pick any Noun on the shelf and pay `queuePrice x (1 + snipePremiumBps)`.
///        The premium is what the queue's head is worth to someone who wants a specific
///        token, and it is the only reason the FIFO order is not simply arbitraged away.
///
///      SNIPING DOES NOT DISTURB THE QUEUE. A sniped token is unlisted in place; the FIFO
///      cursor skips it when it gets there. So sniping the tenth Noun does not promote the
///      eleventh past the second, and {buyNext} always returns the oldest token still on the
///      shelf.
///
///      REVENUE IS 100% FORWARDED. Every wei of a sale goes to the FeeSplitter in the same
///      transaction, which routes it to the Pot, ops and POL exactly like any other inflow —
///      so an Anvil sale funds the next round. This contract holds no ETH between
///      transactions and has no withdraw path for it.
///
///      A PURCHASED NOUN ARRIVES UN-CHIPPED, structurally rather than by policy. This
///      contract is not a registered {IActivationCustodian}, so from {ChipActivation}'s point
///      of view a deposit here is a transfer to a stranger and any prior activation is void
///      the moment the Noun is shelved. The buyer receives a clean Noun and chips it
///      themselves. Nothing here calls the activation vault at all.
contract Anvil is Ownable2Step, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    /// @notice Notice period on every price change. Same shape as ChipActivation.
    uint64 public constant CONFIG_TIMELOCK = 48 hours;

    /// @notice Immutable ceiling on the snipe premium. A compromised multisig cannot make
    ///         picking a specific Noun cost more than three times the queue price.
    uint32 public constant MAX_SNIPE_PREMIUM_BPS = 20_000; // +200%

    /// @notice Where every wei of revenue goes.
    address public feeSplitter;

    /// @notice Price of the next Noun in line, in wei, per collection. Zero means the
    ///         collection is not for sale — which is how an unpriced shelf fails closed.
    mapping(address collection => uint256) public queuePrice;

    /// @notice Premium over `queuePrice` for choosing a specific Noun. 2500 = +25%.
    uint32 public snipePremiumBps;

    /// @notice Per-collection halt. Immediate, because stopping a sale is a safety action.
    mapping(address collection => bool) public paused;

    /// @notice THE SELL SIDE IS NOT BUILT. Readable so the site can say so; no setter.
    bool public constant sellEnabled = false;

    struct Shelf {
        uint256[] tokenIds; // append-only, oldest first
        uint256 cursor; // FIFO head; only ever moves forward
    }

    mapping(address collection => Shelf) internal _shelf;

    /// @notice Whether a shelved token is still available. False once bought or withdrawn.
    mapping(address collection => mapping(uint256 tokenId => bool)) public isListed;

    struct PendingPrice {
        bool queued;
        uint64 executableAt;
        uint256 price;
    }

    struct PendingPremium {
        bool queued;
        uint64 executableAt;
        uint32 bps;
    }

    mapping(address collection => PendingPrice) internal _pendingPrice;
    PendingPremium internal _pendingPremium;

    /// @notice Running totals, for the site.
    uint256 public totalSold;
    uint256 public totalSnipes;
    uint256 public totalRevenueWei;

    event Shelved(address indexed collection, uint256 indexed tokenId, uint256 shelfPosition, uint256 remaining);
    event Unshelved(address indexed collection, uint256 indexed tokenId, address indexed to, uint256 remaining);
    event Bought(
        address indexed collection, uint256 indexed tokenId, address indexed buyer, uint256 pricePaid, uint256 remaining
    );
    event Sniped(
        address indexed collection, uint256 indexed tokenId, address indexed buyer, uint256 pricePaid, uint256 remaining
    );
    event PriceQueued(address indexed collection, uint256 price, uint64 executableAt);
    event PriceExecuted(address indexed collection, uint256 previous, uint256 price);
    event PriceCancelled(address indexed collection);
    event PremiumQueued(uint32 bps, uint64 executableAt);
    event PremiumExecuted(uint32 previous, uint32 bps);
    event PremiumCancelled();
    event CollectionPaused(address indexed collection, bool paused);
    event FeeSplitterSet(address indexed previous, address indexed current);
    event Recovered(address indexed token, address indexed to, uint256 amount);
    event RecoveredNFT(address indexed collection, uint256 indexed tokenId, address indexed to);

    error ZeroAddress();
    error BadConfig();
    error CollectionPausedError(address collection);
    error NotForSale(address collection);
    error ShelfEmpty(address collection);
    error NotListed(address collection, uint256 tokenId);
    error Underpaid(uint256 sent, uint256 required);
    error RefundFailed();
    error FeeForwardFailed();
    error SellNotOpen();
    error NothingQueued();
    error TimelockNotElapsed(uint64 nowTs, uint64 executableAt);
    error NothingToWithdraw();
    error IsShelved(address collection, uint256 tokenId);

    /// @param multisig     Owner. Two-step ownership transfer.
    /// @param feeSplitter_ Where 100% of revenue goes.
    /// @param premiumBps   Snipe premium. Chipworks launches at 2500 (+25%).
    constructor(address multisig, address feeSplitter_, uint32 premiumBps) Ownable(multisig) {
        if (multisig == address(0) || feeSplitter_ == address(0)) revert ZeroAddress();
        if (premiumBps > MAX_SNIPE_PREMIUM_BPS) revert BadConfig();
        feeSplitter = feeSplitter_;
        snipePremiumBps = premiumBps;
        emit PremiumExecuted(0, premiumBps);
    }

    /* ------------------------------------------------------------------ */
    /*                              BUYING                                  */
    /* ------------------------------------------------------------------ */

    /// @notice THE BOX. Buy the oldest Noun on `collection`'s shelf at the queue price.
    /// @dev You do not choose which token. You CAN read which one you will get before
    ///      calling: {nextOnShelf} returns it, and it cannot change under you except by
    ///      somebody else buying first.
    /// @return tokenId The Noun bought.
    function buyNext(address collection) external payable nonReentrant returns (uint256 tokenId) {
        uint256 price = _requireSaleable(collection);

        tokenId = _takeNext(collection);
        isListed[collection][tokenId] = false;
        totalSold += 1;

        _settle(collection, tokenId, price, false);
    }

    /// @notice Buy a SPECIFIC Noun from the shelf, at the queue price plus the premium.
    /// @dev The premium is what jumping the queue costs. Sniping unlists the token in place
    ///      and does not reorder anything: {buyNext} still returns the oldest token left.
    function snipe(address collection, uint256 tokenId) external payable nonReentrant {
        uint256 price = _requireSaleable(collection);
        if (!isListed[collection][tokenId]) revert NotListed(collection, tokenId);

        uint256 snipePrice = _withPremium(price);

        isListed[collection][tokenId] = false;
        totalSold += 1;
        totalSnipes += 1;

        _settle(collection, tokenId, snipePrice, true);
    }

    /// @notice THE SELL SIDE IS NOT BUILT. Always reverts.
    /// @dev Present so the ABI and the site can be honest about what is coming rather than
    ///      silently omitting it. A guaranteed exit is a solvency commitment and ships after
    ///      the audit, in a deployment that actually implements it. {sellEnabled} is a
    ///      constant `false` with no setter, so this cannot be switched on by mistake.
    function sellToAnvil(address, uint256) external pure {
        revert SellNotOpen();
    }

    /// @dev Common tail: take the money, forward 100% of it, refund any excess, hand over
    ///      the Noun LAST.
    ///
    ///      `transferFrom`, NOT `safeTransferFrom`, and deliberately: there is then no
    ///      `onERC721Received` hook on the way out, so the buyer gets no callback at the one
    ///      moment the shelf has been debited. The remaining callback is the refund, which
    ///      only happens on an overpayment and is guarded by `nonReentrant` — a buyer who
    ///      re-enters from it reverts the whole purchase rather than getting two Nouns for
    ///      one. Both paths are tested.
    ///
    ///      The cost of `transferFrom` is that a contract buyer which cannot handle ERC-721s
    ///      would strand the Noun. They called `buyNext` to get it, so that is their choice
    ///      to make; the alternative is handing every buyer a reentrancy hook.
    function _settle(address collection, uint256 tokenId, uint256 price, bool isSnipe) internal {
        if (msg.value < price) revert Underpaid(msg.value, price);

        totalRevenueWei += price;

        // 100% to the FeeSplitter. Reverting rather than holding is deliberate: if the
        // revenue cannot be routed, the Noun does not leave. There is no withdraw path for
        // ETH on this contract, so a sale that could not forward would strand the money.
        (bool ok,) = feeSplitter.call{value: price}("");
        if (!ok) revert FeeForwardFailed();

        uint256 excess = msg.value - price;
        if (excess != 0) {
            (bool refunded,) = msg.sender.call{value: excess}("");
            if (!refunded) revert RefundFailed();
        }

        IERC721(collection).transferFrom(address(this), msg.sender, tokenId);

        uint256 remaining = shelfRemaining(collection);
        if (isSnipe) {
            emit Sniped(collection, tokenId, msg.sender, price, remaining);
        } else {
            emit Bought(collection, tokenId, msg.sender, price, remaining);
        }
    }

    function _requireSaleable(address collection) internal view returns (uint256 price) {
        if (paused[collection]) revert CollectionPausedError(collection);
        price = queuePrice[collection];
        if (price == 0) revert NotForSale(collection);
    }

    /// @dev Advances the FIFO cursor past anything already sniped or withdrawn and returns
    ///      the oldest token still listed. The cursor is PERSISTED as it advances, so the
    ///      total work across every call is linear in the shelf rather than quadratic.
    function _takeNext(address collection) internal returns (uint256) {
        Shelf storage sh = _shelf[collection];
        uint256 i = sh.cursor;
        uint256 n = sh.tokenIds.length;

        while (i < n && !isListed[collection][sh.tokenIds[i]]) {
            unchecked {
                ++i;
            }
        }
        if (i >= n) {
            sh.cursor = i;
            revert ShelfEmpty(collection);
        }

        sh.cursor = i + 1;
        return sh.tokenIds[i];
    }

    function _withPremium(uint256 price) internal view returns (uint256) {
        return price + ((price * snipePremiumBps) / BPS);
    }

    /* ------------------------------------------------------------------ */
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Nouns still available on this collection's shelf.
    function shelfRemaining(address collection) public view returns (uint256 n) {
        Shelf storage sh = _shelf[collection];
        uint256 len = sh.tokenIds.length;
        for (uint256 i = sh.cursor; i < len; ++i) {
            if (isListed[collection][sh.tokenIds[i]]) ++n;
        }
    }

    /// @notice The exact Noun {buyNext} would hand out right now.
    /// @dev The Box is a queue with a readable head, not a lottery. This is what makes that
    ///      claim checkable rather than a promise.
    function nextOnShelf(address collection) external view returns (bool available, uint256 tokenId) {
        Shelf storage sh = _shelf[collection];
        uint256 len = sh.tokenIds.length;
        for (uint256 i = sh.cursor; i < len; ++i) {
            if (isListed[collection][sh.tokenIds[i]]) return (true, sh.tokenIds[i]);
        }
        return (false, 0);
    }

    /// @notice Every Noun still on the shelf, oldest first.
    function shelfQueue(address collection) external view returns (uint256[] memory out) {
        Shelf storage sh = _shelf[collection];
        uint256 len = sh.tokenIds.length;
        uint256 n = shelfRemaining(collection);
        out = new uint256[](n);
        uint256 k;
        for (uint256 i = sh.cursor; i < len && k < n; ++i) {
            if (isListed[collection][sh.tokenIds[i]]) out[k++] = sh.tokenIds[i];
        }
    }

    /// @notice What each route costs right now.
    function prices(address collection) external view returns (uint256 boxPrice, uint256 snipePrice) {
        boxPrice = queuePrice[collection];
        snipePrice = _withPremium(boxPrice);
    }

    function snipePriceOf(address collection) external view returns (uint256) {
        return _withPremium(queuePrice[collection]);
    }

    /// @notice Everything the site needs to render a collection's shelf in one call.
    function shelfState(address collection)
        external
        view
        returns (bool forSale, bool isPaused, uint256 boxPrice, uint256 snipePrice, uint256 remaining, uint256 nextId)
    {
        boxPrice = queuePrice[collection];
        forSale = boxPrice != 0 && !paused[collection];
        isPaused = paused[collection];
        snipePrice = _withPremium(boxPrice);
        remaining = shelfRemaining(collection);
        Shelf storage sh = _shelf[collection];
        uint256 len = sh.tokenIds.length;
        for (uint256 i = sh.cursor; i < len; ++i) {
            if (isListed[collection][sh.tokenIds[i]]) {
                nextId = sh.tokenIds[i];
                break;
            }
        }
    }

    function pendingPrice(address collection) external view returns (PendingPrice memory) {
        return _pendingPrice[collection];
    }

    function pendingPremium() external view returns (PendingPremium memory) {
        return _pendingPremium;
    }

    /* ------------------------------------------------------------------ */
    /*                          ADMIN: THE SHELF                            */
    /* ------------------------------------------------------------------ */

    /// @notice Put Nouns on a collection's shelf, in the order given. Multisig only.
    /// @dev Pulls with `transferFrom`, so the multisig must have approved this contract.
    ///      Deposit order IS sale order — the first token in this array is the first one
    ///      {buyNext} hands out.
    function shelve(address collection, uint256[] calldata tokenIds) external onlyOwner nonReentrant {
        if (collection == address(0)) revert ZeroAddress();
        Shelf storage sh = _shelf[collection];
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            IERC721(collection).transferFrom(msg.sender, address(this), id);
            sh.tokenIds.push(id);
            isListed[collection][id] = true;
            emit Shelved(collection, id, sh.tokenIds.length - 1, shelfRemaining(collection));
        }
    }

    /// @notice Take Nouns back off the shelf. Multisig only.
    ///
    /// @dev Removes from the TAIL — the most recently shelved end — so the multisig can
    ///      shrink the shelf but can never take the specific Noun the next buyer is about to
    ///      receive out from under them. Same rule as the Furnace, for the same reason: the
    ///      queue's head is a promise the moment it is readable.
    function unshelve(address collection, uint256 count, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (count == 0) revert NothingToWithdraw();

        Shelf storage sh = _shelf[collection];
        uint256 taken;
        while (taken < count) {
            uint256 len = sh.tokenIds.length;
            if (len == 0 || len <= sh.cursor) revert NothingToWithdraw();

            uint256 id = sh.tokenIds[len - 1];
            sh.tokenIds.pop();

            // Already sold or already withdrawn: just drop the stale array entry.
            if (!isListed[collection][id]) continue;

            isListed[collection][id] = false;
            IERC721(collection).transferFrom(address(this), to, id);
            emit Unshelved(collection, id, to, shelfRemaining(collection));
            unchecked {
                ++taken;
            }
        }
    }

    /* ------------------------------------------------------------------ */
    /*                        ADMIN: PAUSE + WIRING                         */
    /* ------------------------------------------------------------------ */

    /// @notice Halt or resume sales for one collection. Immediate, not timelocked.
    /// @dev Stopping a sale is a safety action and must be able to happen now. Note it does
    ///      NOT touch the shelf: paused Nouns stay put and resume at the same queue position.
    function setPaused(address collection, bool paused_) external onlyOwner {
        paused[collection] = paused_;
        emit CollectionPaused(collection, paused_);
    }

    function setFeeSplitter(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        emit FeeSplitterSet(feeSplitter, v);
        feeSplitter = v;
    }

    /* ------------------------------------------------------------------ */
    /*                    ADMIN: PRICES (48h TIMELOCK)                      */
    /* ------------------------------------------------------------------ */

    /// @notice Queue a collection's queue price, in wei. Zero takes it off sale.
    /// @dev Timelocked because it is the number every buyer is deciding against. Pausing is
    ///      the immediate lever if a price is actively wrong; this is the considered one.
    function queueQueuePrice(address collection, uint256 priceWei) external onlyOwner {
        if (collection == address(0)) revert ZeroAddress();
        uint64 executableAt = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingPrice[collection] = PendingPrice({queued: true, executableAt: executableAt, price: priceWei});
        emit PriceQueued(collection, priceWei, executableAt);
    }

    function executeQueuePrice(address collection) external onlyOwner {
        PendingPrice memory p = _pendingPrice[collection];
        if (!p.queued) revert NothingQueued();
        if (block.timestamp < p.executableAt) revert TimelockNotElapsed(uint64(block.timestamp), p.executableAt);

        emit PriceExecuted(collection, queuePrice[collection], p.price);
        queuePrice[collection] = p.price;
        delete _pendingPrice[collection];
    }

    function cancelQueuePrice(address collection) external onlyOwner {
        if (!_pendingPrice[collection].queued) revert NothingQueued();
        delete _pendingPrice[collection];
        emit PriceCancelled(collection);
    }

    /// @notice Queue a change to the snipe premium. Capped at {MAX_SNIPE_PREMIUM_BPS}.
    function queueSnipePremium(uint32 bps) external onlyOwner {
        if (bps > MAX_SNIPE_PREMIUM_BPS) revert BadConfig();
        uint64 executableAt = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingPremium = PendingPremium({queued: true, executableAt: executableAt, bps: bps});
        emit PremiumQueued(bps, executableAt);
    }

    function executeSnipePremium() external onlyOwner {
        PendingPremium memory p = _pendingPremium;
        if (!p.queued) revert NothingQueued();
        if (block.timestamp < p.executableAt) revert TimelockNotElapsed(uint64(block.timestamp), p.executableAt);

        emit PremiumExecuted(snipePremiumBps, p.bps);
        snipePremiumBps = p.bps;
        delete _pendingPremium;
    }

    function cancelSnipePremium() external onlyOwner {
        if (!_pendingPremium.queued) revert NothingQueued();
        delete _pendingPremium;
        emit PremiumCancelled();
    }

    /* ------------------------------------------------------------------ */
    /*                               RESCUE                                 */
    /* ------------------------------------------------------------------ */

    /// @notice Sweep an ERC-20 that ended up here. Multisig only.
    /// @dev The Anvil trades in ETH and holds no token balance in any normal path, so there
    ///      is nothing to exclude. ETH deliberately has NO rescue: every wei of revenue is
    ///      forwarded to the FeeSplitter inside the same transaction, so a balance here
    ///      would mean something has already gone wrong, and a withdraw path would be a
    ///      standing way to take sale proceeds out of the protocol.
    function recoverExcess(address token, address to) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) {
            IERC20(token).safeTransfer(to, amount);
            emit Recovered(token, to, amount);
        }
    }

    /// @notice Return an NFT that is not on the shelf. Multisig only.
    /// @dev REVERTS ON A SHELVED NOUN. Stock leaves by exactly two paths — bought, or
    ///      withdrawn from the tail by {unshelve} — and the multisig has no third. Anything
    ///      else here arrived by accident, including via {onERC721Received}, and this is how
    ///      it goes home.
    function recoverNFT(address collection, uint256 tokenId, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (isListed[collection][tokenId]) revert IsShelved(collection, tokenId);
        IERC721(collection).transferFrom(address(this), to, tokenId);
        emit RecoveredNFT(collection, tokenId, to);
    }

    /// @notice Accept NFTs so a `safeTransferFrom` does not revert.
    /// @dev Does NOT shelve. {shelve} is the only thing that lists a Noun for sale, and it
    ///      pulls with `transferFrom`, so a Noun pushed here is not for sale at any price and
    ///      is recoverable with {recoverNFT}.
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
