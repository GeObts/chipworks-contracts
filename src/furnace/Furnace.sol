// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Furnace
/// @notice Burn a fuel NFT and $CHIP to forge a Based Noun or a DarkNOUN out of stock the
///         protocol has deposited.
///
/// @dev ISOLATED FROM THE MONEY PATH ON PURPOSE. This contract shares no storage, no
///      inheritance and no call path with ChipRounds, ChipClaims, Pot or POLTreasury. It
///      cannot move a holder's credits and it is not referenced by anything in the audited
///      set. A bug here loses forge stock; it cannot lose a reward.
///
///      BURNED MEANS BURNED — STRUCTURALLY, NOT BY POLICY. Inputs are transferred straight
///      to `0xdead` inside `forge`, so the Furnace never holds a single fuel token or a single
///      $CHIP at rest. There is no admin function that could reach them because there is
///      nothing to reach: the balance is always zero between transactions. `withdrawStock`
///      touches only deposited OUTPUT NFTs.
///
///      FIFO, AND THE ADMIN CANNOT JUMP THE QUEUE. Forging always takes the oldest unforged
///      token. `withdrawStock` removes from the TAIL, the most recently deposited end, so
///      the multisig can reduce stock but can never pull the specific token a user is about
///      to forge out from under them.
///
///      THE ONE EXCEPTION IS A TOKEN THAT CANNOT MOVE AT ALL, AND IT COSTS 48 HOURS.
///      External review SEC-FUR-003: an output token that becomes untransferable — a paused
///      collection, a compliance freeze, a broken migration — sits at the head and reverts
///      every `forge` against that collection, forever. Nothing behind it can ever be
///      reached, `withdrawStock` only takes the tail, and `rescueStrayNFT` refuses anything
///      in the live queue. One dead token bricked the whole recipe.
///
///      {queueStockSkip} → 48h → {executeStockSkip} advances past it without dispensing it.
///      The queued skip PINS THE TOKEN ID, so the announcement is "we intend to skip token
///      X" rather than a standing right to skip whatever reaches the head two days later —
///      a healthy token that arrives at the head in the meantime is not skippable by an
///      already-queued change. That is what keeps this from being the queue-jumping lever
///      the paragraph above says does not exist.
///
///      RECIPE CHANGES ARE TIMELOCKED. Amounts move only through queue → 48h → execute,
///      each step emitting an event, so a change is visible long before it bites. Pausing
///      is NOT timelocked: stopping a recipe is a safety action and must be immediate.
contract Furnace is Ownable2Step, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    /// @notice Where burned inputs go. Not a contract, so nothing can be recovered from it.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Delay between queueing a recipe change and being able to execute it.
    uint64 public constant RECIPE_TIMELOCK = 48 hours;

    /// @notice Most fuel tokens one recipe may ever demand. Bounds a mis-keyed config.
    uint16 public constant MAX_FUEL_COST = 100;

    struct Recipe {
        bool exists;
        bool paused;
        address outputCollection;
        uint16 fuelCost;
        uint256 chipCost;
    }

    struct PendingChange {
        bool queued;
        uint16 fuelCost;
        uint256 chipCost;
        uint64 executableAt;
    }

    /// @notice The token burned alongside the fuel.
    IERC20 public immutable chipToken;

    /// @notice The collection whose tokens are consumed as fuel.
    ///
    /// @dev A CONSTRUCTOR ARGUMENT, NOT A HARDCODED COLLECTION. The Furnace shipped assuming
    ///      Lil Based Nouns would be the fuel, and that assumption lived only in the naming —
    ///      never in the logic. It is now named for what it is.
    ///
    ///      Swapping the fuel is a deploy-time decision: pass a different address and both
    ///      recipes carry on unchanged, because the fuel is an INPUT to every recipe rather
    ///      than a recipe of its own. There is no "Lil recipe" to remove.
    ///
    ///      **Immutable on purpose.** The fuel is the thing holders are asked to destroy;
    ///      being able to repoint it after launch would let governance change what a forge
    ///      costs people without the 48h notice that guards every other economic parameter
    ///      here. Changing it means a redeploy, which is the right amount of friction.
    ///
    ///      THE FUEL IS CHIPLETS, A PLAIN ERC-721. That was an open question for a while
    ///      and it is now closed: Chiplets ships as a standard ERC-721, not a DN404 hybrid.
    ///      The interface this contract uses — `ownerOf`, then `transferFrom` to `0xdead` —
    ///      is exactly the right one, with no adapter and no mirror to reason about.
    ///
    ///      WHAT THE HYBRID WOULD HAVE COST, recorded because it is why this reads as a
    ///      relief rather than a non-event: a DN404 has an ERC-20 base and an ERC-721 mirror,
    ///      so this would have had to point at the mirror, and three things would have
    ///      stopped being obvious — token ids may be reassigned when the fungible side moves,
    ///      `ownerOf` may not be stable between a user's approval and their forge, and
    ///      "burned means burned" would need re-proving because sending a mirror token to
    ///      `0xdead` also moves the underlying balance. None of that applies now.
    ///
    ///      **So review this against a plain ERC-721 and nothing more.**
    IERC721 public immutable fuelCollection;

    mapping(uint8 recipeId => Recipe) internal _recipes;
    mapping(uint8 recipeId => PendingChange) internal _pending;

    /// @notice Deposited output NFTs, oldest first, keyed by collection.
    mapping(address collection => uint256[]) internal _stock;

    /// @notice How far through `_stock` forging has consumed. Never decreases.
    mapping(address collection => uint256) public forgedFrom;

    /// @notice A queued intent to skip one stuck token at the head of a collection's queue.
    struct PendingSkip {
        bool queued;
        uint64 executableAt;
        uint256 tokenId;
    }

    mapping(address collection => PendingSkip) internal _pendingSkip;

    /// @notice Running totals, for the site.
    uint256 public totalFuelBurned;
    uint256 public totalChipBurned;
    uint256 public totalForged;
    mapping(uint8 recipeId => uint256) public forgedByRecipe;

    event Forged(
        address indexed caller,
        uint8 indexed recipeId,
        uint256[] fuelIds,
        uint256 chipBurned,
        address indexed outputCollection,
        uint256 outputTokenId
    );
    event StockDeposited(address indexed collection, uint256 tokenId, uint256 remaining);
    event StockWithdrawn(address indexed collection, uint256 tokenId, address indexed to, uint256 remaining);
    event RecipeSet(uint8 indexed recipeId, address outputCollection, uint16 fuelCost, uint256 chipCost);
    event RecipeChangeQueued(uint8 indexed recipeId, uint16 fuelCost, uint256 chipCost, uint64 executableAt);
    event RecipeChangeExecuted(uint8 indexed recipeId, uint16 fuelCost, uint256 chipCost);
    event RecipeChangeCancelled(uint8 indexed recipeId);
    event RecipePaused(uint8 indexed recipeId, bool paused);
    event StockSkipQueued(address indexed collection, uint256 tokenId, uint64 executableAt);
    event StockSkipped(address indexed collection, uint256 tokenId);
    event StockSkipCancelled(address indexed collection, uint256 tokenId);

    error ZeroAddress();
    error BadRecipe(uint8 recipeId);
    error RecipeIsPaused(uint8 recipeId);
    error WrongFuelCount(uint256 provided, uint16 required);
    error DuplicateFuelToken(uint256 tokenId);
    error NotFuelOwner(uint256 tokenId, address caller);
    error OutOfStock(uint8 recipeId, address outputCollection);
    error NothingQueued(uint8 recipeId);
    error TimelockNotElapsed(uint64 nowTs, uint64 executableAt);
    error BadConfig();
    error NotEnoughStock(uint256 requested, uint256 available);
    error ChipBurnShortfall(uint256 delivered, uint256 required);
    /// @notice `fuelIds` must be strictly ascending. SEC-FUR-005.
    error FuelIdsNotAscending(uint256 previous, uint256 current);
    /// @notice The head moved between reading it and forging. SEC-FUR-004.
    error UnexpectedOutput(uint256 got, uint256 expected);
    /// @notice The queued skip named a different token than the one now at the head.
    error SkipTargetMoved(uint256 head, uint256 queued);
    error NothingSkipQueued(address collection);

    /// @param multisig       Owner.
    /// @param chipToken_     $CHIP.
    /// @param fuelCollection_ The collection consumed as fuel. **NOT hardcoded** — see the
    ///        note on the fuel collection above.
    /// @param basedRecipe    FORGE_BASED: output collection, fuel cost, $CHIP cost.
    /// @param darkRecipe     FORGE_DARK: output collection, fuel cost, $CHIP cost.
    /// @dev Recipe ids are fixed at 0 (Based) and 1 (Dark). Both are configured here so the
    ///      deployed contract is immediately usable and every amount is a deploy argument.
    constructor(
        address multisig,
        address chipToken_,
        address fuelCollection_,
        Recipe memory basedRecipe,
        Recipe memory darkRecipe
    ) Ownable(multisig) {
        if (multisig == address(0) || chipToken_ == address(0) || fuelCollection_ == address(0)) revert ZeroAddress();
        chipToken = IERC20(chipToken_);
        fuelCollection = IERC721(fuelCollection_);

        _setRecipe(FORGE_BASED, basedRecipe);
        _setRecipe(FORGE_DARK, darkRecipe);
    }

    uint8 public constant FORGE_BASED = 0;
    uint8 public constant FORGE_DARK = 1;

    function _setRecipe(uint8 id, Recipe memory r) internal {
        if (r.outputCollection == address(0)) revert ZeroAddress();
        if (r.fuelCost == 0 || r.fuelCost > MAX_FUEL_COST) revert BadConfig();
        _recipes[id] = Recipe({
            exists: true,
            paused: false,
            outputCollection: r.outputCollection,
            fuelCost: r.fuelCost,
            chipCost: r.chipCost
        });
        emit RecipeSet(id, r.outputCollection, r.fuelCost, r.chipCost);
    }

    /* ------------------------------------------------------------------ */
    /*                               FORGE                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Burn `fuelIds` and the recipe's $CHIP cost, receive the oldest token in stock.
    ///
    /// @dev **`fuelIds` MUST BE STRICTLY ASCENDING.** SEC-FUR-005: the duplicate check used to
    ///      be a nested loop over the inputs, which is quadratic in `fuelCost`. Bounded by
    ///      `MAX_FUEL_COST` at 100 it was never a denial of service, only waste — but sorting
    ///      is free for the caller, it makes the check a single comparison per element, and
    ///      strictly-ascending implies distinct so the two rules collapse into one. The site
    ///      must sort before submitting; see the error {FuelIdsNotAscending}.
    ///
    ///      Order is checks → effects → interactions, and the output NFT leaves last, so the
    ///      `onERC721Received` hook on a contract recipient cannot re-enter into a second
    ///      forge against stock this call has already claimed. `nonReentrant` belts it.
    function forge(uint8 recipeId, uint256[] calldata fuelIds) external nonReentrant returns (uint256 outputTokenId) {
        return _forge(recipeId, fuelIds, 0, false);
    }

    /// @notice Forge, but only if the token you receive is the one you were promised.
    ///
    /// @dev SEC-FUR-004. The queue's head is readable with {nextOutput}, and between reading
    ///      it and landing a transaction somebody else can forge and move it on. Without this
    ///      the caller burns their fuel and their $CHIP for a token they did not choose — and
    ///      since the head is public, it is trivially front-runnable by anyone who wants a
    ///      specific Noun to go to someone else.
    ///
    ///      Passing the expected id makes the forge all-or-nothing: mismatch reverts and
    ///      nothing is consumed. The unchecked overload above is kept because "give me the
    ///      next one, I do not mind which" is a real and common intent, and forcing every
    ///      caller to name a token would make an ordinary forge fail whenever anyone else
    ///      forged first.
    function forge(uint8 recipeId, uint256[] calldata fuelIds, uint256 expectedTokenId)
        external
        nonReentrant
        returns (uint256 outputTokenId)
    {
        return _forge(recipeId, fuelIds, expectedTokenId, true);
    }

    function _forge(uint8 recipeId, uint256[] calldata fuelIds, uint256 expectedTokenId, bool checkExpected)
        internal
        returns (uint256 outputTokenId)
    {
        Recipe memory r = _recipes[recipeId];
        if (!r.exists) revert BadRecipe(recipeId);
        if (r.paused) revert RecipeIsPaused(recipeId);
        if (fuelIds.length != r.fuelCost) revert WrongFuelCount(fuelIds.length, r.fuelCost);

        // ---- checks: stock first, so a doomed forge burns nothing ----
        uint256 cursor = forgedFrom[r.outputCollection];
        uint256[] storage stock = _stock[r.outputCollection];
        if (cursor >= stock.length) revert OutOfStock(recipeId, r.outputCollection);
        outputTokenId = stock[cursor];
        if (checkExpected && outputTokenId != expectedTokenId) {
            revert UnexpectedOutput(outputTokenId, expectedTokenId);
        }

        // ---- checks: inputs are the caller's, and strictly ascending ----
        // Ascending is what makes this O(n): each id need only be compared with the one
        // before it, and "greater than the last" is also "not equal to any of them".
        for (uint256 i; i < fuelIds.length; ++i) {
            if (i != 0) {
                // Equality kept its own error: submitting the same token twice is the mistake
                // a caller is overwhelmingly most likely to make, and "not ascending" is a
                // worse thing to read than "duplicate".
                if (fuelIds[i] == fuelIds[i - 1]) revert DuplicateFuelToken(fuelIds[i]);
                if (fuelIds[i] < fuelIds[i - 1]) revert FuelIdsNotAscending(fuelIds[i - 1], fuelIds[i]);
            }
            if (fuelCollection.ownerOf(fuelIds[i]) != msg.sender) revert NotFuelOwner(fuelIds[i], msg.sender);
        }

        // ---- effects ----
        forgedFrom[r.outputCollection] = cursor + 1;
        totalFuelBurned += fuelIds.length;
        totalChipBurned += r.chipCost;
        totalForged += 1;
        forgedByRecipe[recipeId] += 1;

        // ---- interactions: burn the inputs ----
        // transferFrom, not safeTransferFrom: 0xdead has no code, so the receiver hook would
        // be a no-op, and transferFrom cannot be made to call back into anything.
        for (uint256 i; i < fuelIds.length; ++i) {
            fuelCollection.transferFrom(msg.sender, BURN_ADDRESS, fuelIds[i]);
        }

        if (r.chipCost != 0) {
            // Measure what actually reached the burn address. A $CHIP that taxes transfers
            // or lies about them would otherwise let a forge through under-paid. Failing
            // closed is the right direction: the forge reverts, nothing is consumed.
            uint256 before = chipToken.balanceOf(BURN_ADDRESS);
            chipToken.safeTransferFrom(msg.sender, BURN_ADDRESS, r.chipCost);
            uint256 delivered = chipToken.balanceOf(BURN_ADDRESS) - before;
            if (delivered < r.chipCost) revert ChipBurnShortfall(delivered, r.chipCost);
        }

        // ---- interactions: hand over the output, last ----
        IERC721(r.outputCollection).transferFrom(address(this), msg.sender, outputTokenId);

        emit Forged(msg.sender, recipeId, fuelIds, r.chipCost, r.outputCollection, outputTokenId);
    }

    /* ------------------------------------------------------------------ */
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    function recipe(uint8 recipeId) external view returns (Recipe memory) {
        return _recipes[recipeId];
    }

    function pendingChange(uint8 recipeId) external view returns (PendingChange memory) {
        return _pending[recipeId];
    }

    function pendingSkip(address collection) external view returns (PendingSkip memory) {
        return _pendingSkip[collection];
    }

    /// @notice Output NFTs still available to forge for this recipe.
    function stockRemaining(uint8 recipeId) public view returns (uint256) {
        Recipe storage r = _recipes[recipeId];
        if (!r.exists) return 0;
        return stockRemainingFor(r.outputCollection);
    }

    function stockRemainingFor(address collection) public view returns (uint256) {
        return _stock[collection].length - forgedFrom[collection];
    }

    /// @notice The token the next forge of this recipe would hand out.
    function nextOutput(uint8 recipeId) external view returns (bool available, uint256 tokenId) {
        Recipe storage r = _recipes[recipeId];
        if (!r.exists) return (false, 0);
        uint256 cursor = forgedFrom[r.outputCollection];
        uint256[] storage stock = _stock[r.outputCollection];
        if (cursor >= stock.length) return (false, 0);
        return (true, stock[cursor]);
    }

    /// @notice The unforged queue for a collection, oldest first.
    function stockQueue(address collection) external view returns (uint256[] memory out) {
        uint256[] storage stock = _stock[collection];
        uint256 cursor = forgedFrom[collection];
        out = new uint256[](stock.length - cursor);
        for (uint256 i; i < out.length; ++i) {
            out[i] = stock[cursor + i];
        }
    }

    /// @notice What a forge would cost right now.
    function costOf(uint8 recipeId) external view returns (uint16 fuelCost, uint256 chipCost) {
        Recipe storage r = _recipes[recipeId];
        return (r.fuelCost, r.chipCost);
    }

    /* ------------------------------------------------------------------ */
    /*                          ADMIN: STOCK                                */
    /* ------------------------------------------------------------------ */

    /// @notice Deposit output NFTs. Multisig only. They queue behind existing stock.
    /// @dev Pulls with transferFrom, so the multisig must have approved this contract.
    /// @dev `nonReentrant` for consistency with every other NFT-moving function here, not
    ///      because a path exists: a callback from a hostile collection arrives with
    ///      `msg.sender == collection`, which `onlyOwner` already rejects. Raised by static
    ///      analysis (TRIAGE SLI-001); added because the inconsistency was an omission rather
    ///      than a decision, and the next reader should not have to re-derive that.
    function depositStock(address collection, uint256[] calldata tokenIds) external onlyOwner nonReentrant {
        if (collection == address(0)) revert ZeroAddress();
        for (uint256 i; i < tokenIds.length; ++i) {
            IERC721(collection).transferFrom(msg.sender, address(this), tokenIds[i]);
            _stock[collection].push(tokenIds[i]);
            emit StockDeposited(collection, tokenIds[i], stockRemainingFor(collection));
        }
    }

    /// @notice Withdraw unforged stock. Multisig only.
    /// @dev Removes from the TAIL — the most recently deposited end — so the multisig can
    ///      shrink the pool but can never take the specific token a user is about to forge.
    ///      Only ever touches deposited outputs; burned inputs are at `0xdead` and are not
    ///      reachable from anywhere in this contract.
    function withdrawStock(address collection, uint256 count, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 available = stockRemainingFor(collection);
        if (count == 0 || count > available) revert NotEnoughStock(count, available);

        uint256[] storage stock = _stock[collection];
        for (uint256 i; i < count; ++i) {
            uint256 tokenId = stock[stock.length - 1];
            stock.pop();
            IERC721(collection).transferFrom(address(this), to, tokenId);
            emit StockWithdrawn(collection, tokenId, to, stockRemainingFor(collection));
        }
    }

    /// @notice Announce an intent to skip the token currently at the head of a collection's
    ///         forge queue. Multisig only, executable after 48 hours.
    ///
    /// @dev SEC-FUR-003, and the escape hatch for exactly one situation: the head cannot be
    ///      transferred at all, so every forge against this collection reverts and the stock
    ///      behind it is unreachable. There was no lever for that — `withdrawStock` takes the
    ///      tail and `rescueStrayNFT` refuses live stock — so one dead token bricked a recipe.
    ///
    ///      **The token id is pinned at queue time.** This is the whole reason the function
    ///      is safe: it announces "we intend to skip token X", and if X is no longer at the
    ///      head when the timelock expires the execution reverts {SkipTargetMoved}. So a
    ///      queued skip can never be used against a healthy token that happens to reach the
    ///      head during the 48 hours, and it cannot be left queued as a standing right to
    ///      jump the queue later.
    ///
    ///      Pausing the recipe is the immediate lever while this matures, exactly as with a
    ///      recipe change.
    function queueStockSkip(address collection) external onlyOwner {
        uint256 cursor = forgedFrom[collection];
        uint256[] storage stock = _stock[collection];
        if (cursor >= stock.length) revert NotEnoughStock(1, 0);

        uint256 tokenId = stock[cursor];
        uint64 executableAt = uint64(block.timestamp) + RECIPE_TIMELOCK;
        _pendingSkip[collection] = PendingSkip({queued: true, executableAt: executableAt, tokenId: tokenId});
        emit StockSkipQueued(collection, tokenId, executableAt);
    }

    /// @notice Advance past the announced stuck token WITHOUT dispensing it. Multisig only.
    /// @dev The token stays owned by this contract and simply leaves the forge queue. It is
    ///      not sent anywhere, because the reason it is being skipped is that it cannot be
    ///      sent anywhere. If it ever becomes transferable again, `rescueStrayNFT` can move
    ///      it — it is no longer live stock once the cursor has passed it.
    function executeStockSkip(address collection) external onlyOwner {
        PendingSkip memory p = _pendingSkip[collection];
        if (!p.queued) revert NothingSkipQueued(collection);
        if (block.timestamp < p.executableAt) revert TimelockNotElapsed(uint64(block.timestamp), p.executableAt);

        uint256 cursor = forgedFrom[collection];
        uint256[] storage stock = _stock[collection];
        if (cursor >= stock.length) revert NotEnoughStock(1, 0);
        if (stock[cursor] != p.tokenId) revert SkipTargetMoved(stock[cursor], p.tokenId);

        forgedFrom[collection] = cursor + 1;
        delete _pendingSkip[collection];
        emit StockSkipped(collection, p.tokenId);
    }

    /// @notice Drop a queued skip. Multisig only.
    function cancelStockSkip(address collection) external onlyOwner {
        PendingSkip memory p = _pendingSkip[collection];
        if (!p.queued) revert NothingSkipQueued(collection);
        delete _pendingSkip[collection];
        emit StockSkipCancelled(collection, p.tokenId);
    }

    /* ------------------------------------------------------------------ */
    /*                        ADMIN: RECIPES                                */
    /* ------------------------------------------------------------------ */

    /// @notice Stop or resume a recipe. Multisig only, and deliberately NOT timelocked:
    ///         halting a recipe is a safety action that must be able to happen now.
    function setPaused(uint8 recipeId, bool paused) external onlyOwner {
        if (!_recipes[recipeId].exists) revert BadRecipe(recipeId);
        _recipes[recipeId].paused = paused;
        emit RecipePaused(recipeId, paused);
    }

    /// @notice Queue a change to a recipe's costs. Multisig only. Executable after 48h.
    /// @dev The delay and the event exist so a price change is public well before it binds,
    ///      rather than landing on someone mid-transaction.
    function queueRecipeChange(uint8 recipeId, uint16 fuelCost, uint256 chipCost) external onlyOwner {
        if (!_recipes[recipeId].exists) revert BadRecipe(recipeId);
        if (fuelCost == 0 || fuelCost > MAX_FUEL_COST) revert BadConfig();

        uint64 executableAt = uint64(block.timestamp) + RECIPE_TIMELOCK;
        _pending[recipeId] =
            PendingChange({queued: true, fuelCost: fuelCost, chipCost: chipCost, executableAt: executableAt});
        emit RecipeChangeQueued(recipeId, fuelCost, chipCost, executableAt);
    }

    /// @notice Apply a queued change once its timelock has elapsed. Multisig only.
    function executeRecipeChange(uint8 recipeId) external onlyOwner {
        PendingChange memory p = _pending[recipeId];
        if (!p.queued) revert NothingQueued(recipeId);
        if (block.timestamp < p.executableAt) revert TimelockNotElapsed(uint64(block.timestamp), p.executableAt);

        _recipes[recipeId].fuelCost = p.fuelCost;
        _recipes[recipeId].chipCost = p.chipCost;
        delete _pending[recipeId];

        emit RecipeChangeExecuted(recipeId, p.fuelCost, p.chipCost);
    }

    /// @notice Drop a queued change. Multisig only.
    function cancelRecipeChange(uint8 recipeId) external onlyOwner {
        if (!_pending[recipeId].queued) revert NothingQueued(recipeId);
        delete _pending[recipeId];
        emit RecipeChangeCancelled(recipeId);
    }

    /* ------------------------------------------------------------------ */
    /*                              ERC721                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Accept NFTs so `safeTransferFrom` deposits work.
    /// @dev Does NOT register stock. Stock is only ever created by {depositStock}, so an NFT
    ///      pushed here by accident is invisible to forging and can be recovered with
    ///      {rescueStrayNFT} — it never silently becomes someone's output.
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Recover an NFT that arrived without going through {depositStock}.
    /// @dev Cannot touch registered stock: reverts if the token is in the unforged queue.
    ///      Note this can reclaim an ALREADY-FORGED-PAST token id only if it is not in the
    ///      queue, which by definition means it has already left the contract.
    function rescueStrayNFT(address collection, uint256 tokenId, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256[] storage stock = _stock[collection];
        for (uint256 i = forgedFrom[collection]; i < stock.length; ++i) {
            if (stock[i] == tokenId) revert NotEnoughStock(0, 0); // it is live stock, not stray
        }
        IERC721(collection).transferFrom(address(this), to, tokenId);
    }
}
