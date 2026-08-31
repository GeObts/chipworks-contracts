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
/// @notice Burn Lil Based Nouns and $CHIP to forge a Based Noun or a DarkNOUN out of stock
///         the protocol has deposited.
///
/// @dev ISOLATED FROM THE MONEY PATH ON PURPOSE. This contract shares no storage, no
///      inheritance and no call path with ChipRounds, ChipClaims, Pot or POLTreasury. It
///      cannot move a holder's credits and it is not referenced by anything in the audited
///      set. A bug here loses forge stock; it cannot lose a reward.
///
///      BURNED MEANS BURNED — STRUCTURALLY, NOT BY POLICY. Inputs are transferred straight
///      to `0xdead` inside `forge`, so the Furnace never holds a single Lil or a single
///      $CHIP at rest. There is no admin function that could reach them because there is
///      nothing to reach: the balance is always zero between transactions. `withdrawStock`
///      touches only deposited OUTPUT NFTs.
///
///      FIFO, AND THE ADMIN CANNOT JUMP THE QUEUE. Forging always takes the oldest unforged
///      token. `withdrawStock` removes from the TAIL, the most recently deposited end, so
///      the multisig can reduce stock but can never pull the specific token a user is about
///      to forge out from under them.
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

    /// @notice Most Lils one recipe may ever demand. Bounds a mis-keyed config.
    uint16 public constant MAX_LIL_COST = 100;

    struct Recipe {
        bool exists;
        bool paused;
        address outputCollection;
        uint16 lilCost;
        uint256 chipCost;
    }

    struct PendingChange {
        bool queued;
        uint16 lilCost;
        uint256 chipCost;
        uint64 executableAt;
    }

    /// @notice The token burned alongside the Lils.
    IERC20 public immutable chipToken;

    /// @notice The collection whose tokens are consumed as fuel.
    IERC721 public immutable lilCollection;

    mapping(uint8 recipeId => Recipe) internal _recipes;
    mapping(uint8 recipeId => PendingChange) internal _pending;

    /// @notice Deposited output NFTs, oldest first, keyed by collection.
    mapping(address collection => uint256[]) internal _stock;

    /// @notice How far through `_stock` forging has consumed. Never decreases.
    mapping(address collection => uint256) public forgedFrom;

    /// @notice Running totals, for the site.
    uint256 public totalLilsBurned;
    uint256 public totalChipBurned;
    uint256 public totalForged;
    mapping(uint8 recipeId => uint256) public forgedByRecipe;

    event Forged(
        address indexed caller,
        uint8 indexed recipeId,
        uint256[] lilIds,
        uint256 chipBurned,
        address indexed outputCollection,
        uint256 outputTokenId
    );
    event StockDeposited(address indexed collection, uint256 tokenId, uint256 remaining);
    event StockWithdrawn(address indexed collection, uint256 tokenId, address indexed to, uint256 remaining);
    event RecipeSet(uint8 indexed recipeId, address outputCollection, uint16 lilCost, uint256 chipCost);
    event RecipeChangeQueued(uint8 indexed recipeId, uint16 lilCost, uint256 chipCost, uint64 executableAt);
    event RecipeChangeExecuted(uint8 indexed recipeId, uint16 lilCost, uint256 chipCost);
    event RecipeChangeCancelled(uint8 indexed recipeId);
    event RecipePaused(uint8 indexed recipeId, bool paused);

    error ZeroAddress();
    error BadRecipe(uint8 recipeId);
    error RecipeIsPaused(uint8 recipeId);
    error WrongLilCount(uint256 provided, uint16 required);
    error DuplicateLil(uint256 tokenId);
    error NotLilOwner(uint256 tokenId, address caller);
    error OutOfStock(uint8 recipeId, address outputCollection);
    error NothingQueued(uint8 recipeId);
    error TimelockNotElapsed(uint64 nowTs, uint64 executableAt);
    error BadConfig();
    error NotEnoughStock(uint256 requested, uint256 available);
    error ChipBurnShortfall(uint256 delivered, uint256 required);

    /// @param multisig       Owner.
    /// @param chipToken_     $CHIP.
    /// @param lilCollection_ Lil Based Nouns.
    /// @param basedRecipe    FORGE_BASED: output collection, Lil cost, $CHIP cost.
    /// @param darkRecipe     FORGE_DARK: output collection, Lil cost, $CHIP cost.
    /// @dev Recipe ids are fixed at 0 (Based) and 1 (Dark). Both are configured here so the
    ///      deployed contract is immediately usable and every amount is a deploy argument.
    constructor(
        address multisig,
        address chipToken_,
        address lilCollection_,
        Recipe memory basedRecipe,
        Recipe memory darkRecipe
    ) Ownable(multisig) {
        if (multisig == address(0) || chipToken_ == address(0) || lilCollection_ == address(0)) revert ZeroAddress();
        chipToken = IERC20(chipToken_);
        lilCollection = IERC721(lilCollection_);

        _setRecipe(FORGE_BASED, basedRecipe);
        _setRecipe(FORGE_DARK, darkRecipe);
    }

    uint8 public constant FORGE_BASED = 0;
    uint8 public constant FORGE_DARK = 1;

    function _setRecipe(uint8 id, Recipe memory r) internal {
        if (r.outputCollection == address(0)) revert ZeroAddress();
        if (r.lilCost == 0 || r.lilCost > MAX_LIL_COST) revert BadConfig();
        _recipes[id] =
            Recipe({exists: true, paused: false, outputCollection: r.outputCollection, lilCost: r.lilCost, chipCost: r.chipCost});
        emit RecipeSet(id, r.outputCollection, r.lilCost, r.chipCost);
    }

    /* ------------------------------------------------------------------ */
    /*                               FORGE                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Burn `lilIds` and the recipe's $CHIP cost, receive the oldest token in stock.
    ///
    /// @dev Order is checks → effects → interactions, and the output NFT leaves last, so the
    ///      `onERC721Received` hook on a contract recipient cannot re-enter into a second
    ///      forge against stock this call has already claimed. `nonReentrant` belts it.
    function forge(uint8 recipeId, uint256[] calldata lilIds) external nonReentrant returns (uint256 outputTokenId) {
        Recipe memory r = _recipes[recipeId];
        if (!r.exists) revert BadRecipe(recipeId);
        if (r.paused) revert RecipeIsPaused(recipeId);
        if (lilIds.length != r.lilCost) revert WrongLilCount(lilIds.length, r.lilCost);

        // ---- checks: stock first, so a doomed forge burns nothing ----
        uint256 cursor = forgedFrom[r.outputCollection];
        uint256[] storage stock = _stock[r.outputCollection];
        if (cursor >= stock.length) revert OutOfStock(recipeId, r.outputCollection);
        outputTokenId = stock[cursor];

        // ---- checks: inputs are the caller's, and distinct ----
        for (uint256 i; i < lilIds.length; ++i) {
            if (lilCollection.ownerOf(lilIds[i]) != msg.sender) revert NotLilOwner(lilIds[i], msg.sender);
            for (uint256 j; j < i; ++j) {
                if (lilIds[j] == lilIds[i]) revert DuplicateLil(lilIds[i]);
            }
        }

        // ---- effects ----
        forgedFrom[r.outputCollection] = cursor + 1;
        totalLilsBurned += lilIds.length;
        totalChipBurned += r.chipCost;
        totalForged += 1;
        forgedByRecipe[recipeId] += 1;

        // ---- interactions: burn the inputs ----
        // transferFrom, not safeTransferFrom: 0xdead has no code, so the receiver hook would
        // be a no-op, and transferFrom cannot be made to call back into anything.
        for (uint256 i; i < lilIds.length; ++i) {
            lilCollection.transferFrom(msg.sender, BURN_ADDRESS, lilIds[i]);
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

        emit Forged(msg.sender, recipeId, lilIds, r.chipCost, r.outputCollection, outputTokenId);
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
    function costOf(uint8 recipeId) external view returns (uint16 lilCost, uint256 chipCost) {
        Recipe storage r = _recipes[recipeId];
        return (r.lilCost, r.chipCost);
    }

    /* ------------------------------------------------------------------ */
    /*                          ADMIN: STOCK                                */
    /* ------------------------------------------------------------------ */

    /// @notice Deposit output NFTs. Multisig only. They queue behind existing stock.
    /// @dev Pulls with transferFrom, so the multisig must have approved this contract.
    function depositStock(address collection, uint256[] calldata tokenIds) external onlyOwner {
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
    function queueRecipeChange(uint8 recipeId, uint16 lilCost, uint256 chipCost) external onlyOwner {
        if (!_recipes[recipeId].exists) revert BadRecipe(recipeId);
        if (lilCost == 0 || lilCost > MAX_LIL_COST) revert BadConfig();

        uint64 executableAt = uint64(block.timestamp) + RECIPE_TIMELOCK;
        _pending[recipeId] =
            PendingChange({queued: true, lilCost: lilCost, chipCost: chipCost, executableAt: executableAt});
        emit RecipeChangeQueued(recipeId, lilCost, chipCost, executableAt);
    }

    /// @notice Apply a queued change once its timelock has elapsed. Multisig only.
    function executeRecipeChange(uint8 recipeId) external onlyOwner {
        PendingChange memory p = _pending[recipeId];
        if (!p.queued) revert NothingQueued(recipeId);
        if (block.timestamp < p.executableAt) revert TimelockNotElapsed(uint64(block.timestamp), p.executableAt);

        _recipes[recipeId].lilCost = p.lilCost;
        _recipes[recipeId].chipCost = p.chipCost;
        delete _pending[recipeId];

        emit RecipeChangeExecuted(recipeId, p.lilCost, p.chipCost);
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
