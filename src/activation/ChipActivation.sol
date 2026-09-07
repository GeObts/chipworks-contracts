// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IActivationSource} from "../interfaces/IActivationSource.sol";
import {IActivationCustodian} from "../interfaces/IActivationCustodian.sol";

/// @title ChipActivation
/// @notice Chipworks' own non-custodial soft-staking vault. Burn $CHIP to activate a Noun at
///         a tier; the Noun never moves; the activation resets the moment it changes hands.
///
/// @dev THIS REPLACES CLUTCH. It is the production implementation behind the same
///      {IActivationSource} interface `ChipRounds` already reads, so nothing downstream
///      changed to adopt it: one multisig call to `setActivationSource`.
///      `ClutchVaultAdapter` stays in the repo as the retired alternative implementation
///      and is not deployed. See AUDIT_BRIEF section 7 for why Clutch is off the table.
///
///      FOUR PROPERTIES, IN THE ORDER THEY MATTER.
///
///      1. NON-CUSTODIAL, STRUCTURALLY. This contract never takes a Noun. It has no
///         `onERC721Received`, so `safeTransferFrom` into it reverts, and it holds no NFT to
///         lose. Activation is a record keyed by (collection, tokenId), nothing more.
///
///      2. RESET IS LAZY AND ATOMIC, WITH NO KEEPER. There is no `kick`, and no job that has
///         to run for correctness. Every read — the weight `ChipRounds` books, and every view
///         the site shows — recomputes the effective owner and compares it to the owner at
///         activation. They disagree, the token is inactive, that instant, for everybody.
///         A sold Noun stops earning in the same block it is sold, with nobody doing
///         anything. THIS IS THE BUG CLASS THAT SANK THE CLUTCH ROUTE: their vault records a
///         stale owner after a transfer and needs `kick` to catch up, so five of fourteen
///         sampled live activations on Robinhood are earning for sellers right now
///         (CLUTCH_RECON section 3). Nothing here can drift, because nothing here is stored
///         that could go stale.
///
///         NOTE ON "TIER 0". The spec says a transferred Noun "simply reads as tier 0",
///         meaning inactive. The tier TABLE says index 0 is the base tier worth 1.00x.
///         Those two collide (ASSUMPTIONS A-12) and this contract resolves it the only safe
///         way: activation status is `ownerAtActivation != 0` AND the owner check passing.
///         Tier is never used to infer whether a Noun is activated, so a reset returns
///         `active = false`, not `tierBps = 10000`. Do not "simplify" this by treating tier
///         index 0 as inactive — that would silently zero every base-tier Noun.
///
///      3. CUSTODY IS ALLOWLISTED, WHICH IS WHAT MAKES LENDING POSSIBLE. Plain soft staking
///         cannot tell a sale from a deposit: both are `ownerOf` changing. When `ownerOf` is
///         a registered custodian, the effective owner is whatever that custodian names as
///         beneficiary, so a Noun locked as loan collateral keeps earning FOR THE BORROWER.
///         Chip while collateralised works, borrow while chipped keeps earning, repay
///         changes nothing, liquidation resets. See {IActivationCustodian} for the trust
///         model and `NounLoans` for the first registered custodian.
///
///      4. 100% OF THE COST BURNS. Clutch took 5% of every activation. There is no cut here,
///         no treasury leg and no fee address: `activate` moves $CHIP from the caller
///         straight to `0xdead` and this contract holds no $CHIP between transactions. That
///         is structural, not policy — there is no code path that could route it elsewhere,
///         and `test_theContractNeverHoldsChip` asserts the balance is zero after every
///         operation. $CHIP is a standard ERC-20 from a Doppler/Bankr launch with no
///         `burn()`, so a transfer to `0xdead` is the burn.
///
///      THREE PROPERTIES REVIEWED AND KEPT AS INTENDED (TRIAGE SEC-ACT-002/003/004):
///
///      - **Revival on repurchase is free.** A holder who sells and later buys the same Noun
///        back has their tier restored at no cost, even if the table has risen. The "top up
///        the difference" alternative cannot be built without either deactivating continuous
///        holders on a price rise or adding a transfer hook this design deliberately avoids —
///        and the exploit is bounded to selling your own Noun and buying that exact token
///        back. Revival is bound to the original activator, so a tier can never be sold with
///        the Noun.
///      - **Upgrading credits the current table's lower tier**, not what was actually paid,
///        so an early adopter upgrades more cheaply after a price rise. Deliberate: the
///        alternative penalises early activation, which is the behaviour being rewarded.
///      - **Registering a custodian is immediate.** Its blast radius is bounded to tokens
///        physically held by that custodian, and it is not timelocked because
///        `setCustodian` is already the single most forgettable call in the deploy runbook —
///        splitting it into two transactions 48 hours apart would make the one step that
///        fails silently harder to complete, not safer.
///
///      COSTS AND WEIGHTS ARE CONFIGURATION, BEHIND A 48H TIMELOCK. Denominations are set at
///      token launch and nothing about them is hardcoded. Both the per-collection cost table
///      and the tier weight curve move only through queue -> 48h -> execute, each step
///      emitting an event, so a change is public long before it binds. This is deliberately
///      stricter than the retired adapter, which let the multisig retune tier weights in one
///      transaction: the weight curve decides what everybody earns, and it should not be
///      able to change without notice. Registering a collection for the first time uses the
///      same path — it costs 48h once, and keeps one code path instead of two.
contract ChipActivation is IActivationSource, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Tier indices 0..4.
    uint256 public constant TIER_COUNT = 5;

    /// @notice Notice period on every economic parameter. Same shape as the Furnace.
    uint64 public constant CONFIG_TIMELOCK = 48 hours;

    /// @notice Where activation costs go. Not a contract, so nothing is recoverable from it.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Gas cap on every call into a foreign collection or custodian.
    /// @dev A contract that reverts with an invalid opcode consumes every wei of gas handed
    ///      to it and would otherwise take a whole round down with it. See ASSUMPTIONS A-17.
    uint256 public constant PROBE_GAS = 100_000;

    /// @notice One activation. Absent when `ownerAtActivation` is zero.
    /// @dev `ownerAtActivation` is the address that paid, NOT a live owner. The live owner is
    ///      recomputed on every read; this is the value it is compared against.
    struct Activation {
        uint8 tier;
        address ownerAtActivation;
        uint64 activatedAt;
    }

    /// @notice $CHIP. Immutable: the burn asset is not a governance lever.
    IERC20 public immutable chipToken;

    mapping(address collection => mapping(uint256 tokenId => Activation)) internal _activations;

    /// @notice Whether a collection can be activated at all. False fails closed.
    mapping(address collection => bool) public collectionConfigured;

    /// @notice collection => cost in $CHIP to hold each tier outright. Non-decreasing.
    mapping(address collection => uint256[TIER_COUNT]) internal _tierCost;

    /// @notice Tier index => weight in basis points (10000 = 1.00x). Non-decreasing.
    uint32[TIER_COUNT] public tierBps;

    /// @notice Contracts allowed to hold a Noun without voiding its activation.
    mapping(address custodian => bool) public isCustodian;

    struct PendingCosts {
        bool queued;
        uint64 executableAt;
        uint256[TIER_COUNT] cost;
    }

    struct PendingTiers {
        bool queued;
        uint64 executableAt;
        uint32[TIER_COUNT] bps;
    }

    mapping(address collection => PendingCosts) internal _pendingCosts;
    PendingTiers internal _pendingTiers;

    /// @notice Running totals, for the site.
    uint256 public totalChipBurned;
    uint256 public totalActivations;
    uint256 public totalUpgrades;

    event Activated(
        address indexed collection, uint256 indexed tokenId, address indexed owner, uint8 tier, uint256 chipBurned
    );
    event Upgraded(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed owner,
        uint8 fromTier,
        uint8 toTier,
        uint256 chipBurned
    );
    event CostsQueued(address indexed collection, uint256[TIER_COUNT] cost, uint64 executableAt);
    event CostsExecuted(address indexed collection, uint256[TIER_COUNT] cost);
    event CostsCancelled(address indexed collection);
    event TiersQueued(uint32[TIER_COUNT] bps, uint64 executableAt);
    event TiersExecuted(uint32[TIER_COUNT] bps);
    event TiersCancelled();
    event CustodianSet(address indexed custodian, bool allowed);
    event Recovered(address indexed token, address indexed to, uint256 amount);
    event RecoveredNFT(address indexed collection, uint256 indexed tokenId, address indexed to);

    error ZeroAddress();
    error BadTier(uint256 tier);
    error BadConfig();
    error CollectionNotConfigured(address collection);
    error NotEffectiveOwner(address collection, uint256 tokenId, address caller);
    error AlreadyActive(address collection, uint256 tokenId);
    error NotActive(address collection, uint256 tokenId);
    error NotAnUpgrade(uint8 currentTier, uint8 requestedTier);
    error NothingQueued();
    error TimelockNotElapsed(uint64 nowTs, uint64 executableAt);
    error ChipBurnShortfall(uint256 delivered, uint256 required);

    /// @param multisig   Owner. Two-step ownership transfer.
    /// @param chipToken_ $CHIP.
    /// @param tierBps_   Weight curve, basis points. Chipworks ships 1.00 / 1.25 / 1.60 /
    ///                   2.00 / 3.33 as `[10000, 12500, 16000, 20000, 33300]`.
    /// @dev Collections are registered after deploy through the timelocked cost path, so a
    ///      freshly deployed ChipActivation accepts no activations at all until the multisig
    ///      configures at least one. That is the intended failure mode: forgetting a
    ///      collection makes it earn nothing rather than earn for free.
    constructor(address multisig, address chipToken_, uint32[TIER_COUNT] memory tierBps_) Ownable(multisig) {
        if (multisig == address(0) || chipToken_ == address(0)) revert ZeroAddress();
        chipToken = IERC20(chipToken_);
        _validateTiers(tierBps_);
        tierBps = tierBps_;
        emit TiersExecuted(tierBps_);
    }

    /* ------------------------------------------------------------------ */
    /*                             ACTIVATION                               */
    /* ------------------------------------------------------------------ */

    /// @notice Activate `tokenId` at `tier`, burning the tier's full cost in $CHIP.
    /// @dev The caller must be the EFFECTIVE owner, so a borrower whose Noun sits in a
    ///      registered custodian can activate it without withdrawing — "chip while
    ///      collateralised".
    ///
    ///      A token whose previous activation has lapsed (it changed hands) is simply
    ///      activated afresh at full price by its new owner. There is nothing to clear
    ///      first: the old record is dead the moment the owner check fails, and it is
    ///      overwritten here.
    function activate(address collection, uint256 tokenId, uint8 tier) external nonReentrant {
        if (!collectionConfigured[collection]) revert CollectionNotConfigured(collection);
        if (tier >= TIER_COUNT) revert BadTier(tier);

        address effective = _effectiveOwner(collection, tokenId);
        if (effective == address(0) || effective != msg.sender) {
            revert NotEffectiveOwner(collection, tokenId, msg.sender);
        }

        // A live activation is upgraded, never re-bought: paying full price for a tier you
        // already hold would be a silent loss.
        Activation storage a = _activations[collection][tokenId];
        if (a.ownerAtActivation == effective) revert AlreadyActive(collection, tokenId);

        uint256 cost = _tierCost[collection][tier];

        // ---- effects, before the burn ----
        a.tier = tier;
        a.ownerAtActivation = effective;
        a.activatedAt = uint64(block.timestamp);
        totalActivations += 1;

        _burnChip(cost);

        emit Activated(collection, tokenId, effective, tier, cost);
    }

    /// @notice Raise a live activation to `newTier`, paying only the difference.
    /// @dev Requires a live activation held by the caller. Tiers only ever go up: a
    ///      downgrade would owe a refund out of tokens that are already burned.
    function upgrade(address collection, uint256 tokenId, uint8 newTier) external nonReentrant {
        if (!collectionConfigured[collection]) revert CollectionNotConfigured(collection);
        if (newTier >= TIER_COUNT) revert BadTier(newTier);

        Activation storage a = _activations[collection][tokenId];
        address recorded = a.ownerAtActivation;
        if (recorded == address(0)) revert NotActive(collection, tokenId);

        address effective = _effectiveOwner(collection, tokenId);
        if (effective == address(0) || effective != recorded) revert NotActive(collection, tokenId);
        if (effective != msg.sender) revert NotEffectiveOwner(collection, tokenId, msg.sender);

        uint8 current = a.tier;
        if (newTier <= current) revert NotAnUpgrade(current, newTier);

        // Non-decreasing costs are enforced on every accepted table, so this cannot underflow.
        uint256 cost = _tierCost[collection][newTier] - _tierCost[collection][current];

        a.tier = newTier;
        totalUpgrades += 1;

        _burnChip(cost);

        emit Upgraded(collection, tokenId, effective, current, newTier, cost);
    }

    /// @dev Moves $CHIP from the caller straight to `0xdead` and MEASURES what arrived.
    ///      A $CHIP that taxes transfers, or lies about them, would otherwise buy an
    ///      activation under-paid. Failing closed is the right direction: the whole call
    ///      reverts and nothing is recorded.
    function _burnChip(uint256 amount) internal {
        if (amount == 0) return;
        uint256 before = chipToken.balanceOf(BURN_ADDRESS);
        chipToken.safeTransferFrom(msg.sender, BURN_ADDRESS, amount);
        uint256 delivered = chipToken.balanceOf(BURN_ADDRESS) - before;
        if (delivered < amount) revert ChipBurnShortfall(delivered, amount);
        totalChipBurned += amount;
    }

    /* ------------------------------------------------------------------ */
    /*                        $CHIP BURN VISIBILITY                         */
    /* ------------------------------------------------------------------ */

    /// @notice Every $CHIP ever sent to `0xdead`, by anyone, for any reason.
    ///
    /// @dev THIS IS THE AUTHORITATIVE NUMBER, and it is deliberately not our own counter.
    ///      {totalChipBurned} on this contract counts only what THIS contract burned;
    ///      `ChipRounds` and `Furnace` keep their own. Summing three counters would miss a
    ///      fourth contract added later, and would miss anyone who burned $CHIP by sending it
    ///      to `0xdead` directly. The dead address's balance misses nothing.
    function chipBurnedToDead() public view returns (uint256) {
        return chipToken.balanceOf(BURN_ADDRESS);
    }

    /// @notice $CHIP actually in circulation: total supply less everything burned.
    ///
    /// @dev **$CHIP CANNOT BE TRULY BURNED, AND THIS IS THE WORKAROUND.** Bankr's Doppler
    ///      token exposes no `burn`, so `totalSupply()` does not fall when the protocol burns
    ///      — the tokens sit at `0xdead` forever, unreachable but still counted. That is a
    ///      limitation of a contract we do not own, not a shortcut in this one.
    ///
    ///      So the honest circulating figure is this subtraction, and it has to be surfaced
    ///      deliberately: by the site, and by filing `0x…dEaD` with CoinGecko and CMC as an
    ///      excluded burn address after launch. Until that filing lands, aggregators will
    ///      overstate $CHIP supply by exactly {chipBurnedToDead}. See README and DEPLOY.
    ///
    ///      Contrast the Furnace's fuel, which IS truly burned: Chiplets is `ERC721Burnable`,
    ///      so forging genuinely reduces that collection's supply.
    function effectiveChipSupply() external view returns (uint256) {
        uint256 supply = chipToken.totalSupply();
        uint256 burned = chipBurnedToDead();
        return burned >= supply ? 0 : supply - burned;
    }

    /* ------------------------------------------------------------------ */
    /*                          IActivationSource                           */
    /* ------------------------------------------------------------------ */

    /// @inheritdoc IActivationSource
    /// @dev NEVER REVERTS. An unconfigured collection, a token that has changed hands, a
    ///      collection or custodian that fails any probe — all report as simply inactive, so
    ///      one broken entry can never take a whole round down.
    ///
    ///      This is where the lazy reset happens. There is no stored "active" flag to go
    ///      stale: the answer is recomputed from the live owner every single time.
    function activation(address collection, uint256 tokenId)
        external
        view
        override
        returns (bool active, uint32 tierBps_, address owner)
    {
        Activation storage a = _activations[collection][tokenId];
        address recorded = a.ownerAtActivation;
        if (recorded == address(0)) return (false, 0, address(0));

        address effective = _effectiveOwner(collection, tokenId);
        if (effective == address(0) || effective != recorded) return (false, 0, address(0));

        uint32 bps = tierBps[a.tier];
        if (bps == 0) return (false, 0, address(0));

        return (true, bps, recorded);
    }

    /// @inheritdoc IActivationSource
    function isSupportedCollection(address collection) external view override returns (bool) {
        return collectionConfigured[collection];
    }

    /* ------------------------------------------------------------------ */
    /*                          EFFECTIVE OWNER                             */
    /* ------------------------------------------------------------------ */

    /// @notice Who really owns `tokenId` for activation purposes.
    /// @dev `ownerOf`, except that a registered custodian is asked who it holds the token
    ///      for. Both calls are gas-capped staticcalls and any failure returns zero, which
    ///      reads as "no effective owner" and resets the activation.
    ///
    ///      A custodian is only ever consulted about tokens `ownerOf` says it holds, so a
    ///      hostile custodian's blast radius is exactly its own custody — it cannot name a
    ///      beneficiary for a Noun it does not hold, in this collection or any other.
    function effectiveOwner(address collection, uint256 tokenId) external view override returns (address) {
        return _effectiveOwner(collection, tokenId);
    }

    function _effectiveOwner(address collection, uint256 tokenId) internal view returns (address) {
        (bool ok, bytes memory ret) = collection.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC721.ownerOf, (tokenId)));
        if (!ok || ret.length < 32) return address(0);
        address holder = abi.decode(ret, (address));
        if (holder == address(0)) return address(0);

        if (!isCustodian[holder]) return holder;

        (bool okB, bytes memory retB) =
            holder.staticcall{gas: PROBE_GAS}(abi.encodeCall(IActivationCustodian.beneficiaryOf, (collection, tokenId)));
        if (!okB || retB.length < 32) return address(0);
        return abi.decode(retB, (address));
    }

    /* ------------------------------------------------------------------ */
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    /// @notice The raw stored record, whether or not it is still live.
    /// @dev For the site's "this used to be active" display and for debugging. Do NOT use it
    ///      to decide whether a Noun earns — use {activation}, which applies the owner check.
    function activationOf(address collection, uint256 tokenId) external view returns (Activation memory) {
        return _activations[collection][tokenId];
    }

    function isActive(address collection, uint256 tokenId) external view returns (bool) {
        address recorded = _activations[collection][tokenId].ownerAtActivation;
        if (recorded == address(0)) return false;
        return _effectiveOwner(collection, tokenId) == recorded;
    }

    /// @notice Live tier, or zero weight if the activation has reset.
    function tierBpsOf(address collection, uint256 tokenId) external view returns (uint32) {
        Activation storage a = _activations[collection][tokenId];
        address recorded = a.ownerAtActivation;
        if (recorded == address(0)) return 0;
        if (_effectiveOwner(collection, tokenId) != recorded) return 0;
        return tierBps[a.tier];
    }

    /// @notice Cost in $CHIP to hold `tier` outright.
    function costOf(address collection, uint8 tier) external view returns (uint256) {
        if (tier >= TIER_COUNT) revert BadTier(tier);
        return _tierCost[collection][tier];
    }

    function tierCosts(address collection) external view returns (uint256[TIER_COUNT] memory) {
        return _tierCost[collection];
    }

    function allTierBps() external view returns (uint32[TIER_COUNT] memory) {
        return tierBps;
    }

    /// @notice What an upgrade to `newTier` would cost right now. Reverts exactly where
    ///         {upgrade} would, so the site can surface the reason instead of a failed tx.
    function upgradeCost(address collection, uint256 tokenId, uint8 newTier) external view returns (uint256) {
        if (newTier >= TIER_COUNT) revert BadTier(newTier);
        Activation storage a = _activations[collection][tokenId];
        address recorded = a.ownerAtActivation;
        if (recorded == address(0) || _effectiveOwner(collection, tokenId) != recorded) {
            revert NotActive(collection, tokenId);
        }
        if (newTier <= a.tier) revert NotAnUpgrade(a.tier, newTier);
        return _tierCost[collection][newTier] - _tierCost[collection][a.tier];
    }

    function pendingCosts(address collection) external view returns (PendingCosts memory) {
        return _pendingCosts[collection];
    }

    function pendingTiers() external view returns (PendingTiers memory) {
        return _pendingTiers;
    }

    /* ------------------------------------------------------------------ */
    /*                      GOVERNANCE: CUSTODIANS                          */
    /* ------------------------------------------------------------------ */

    /// @notice Allow or forbid a contract to hold Nouns without voiding their activations.
    ///
    /// @dev NOT TIMELOCKED, IN BOTH DIRECTIONS, AND THAT IS DELIBERATE. De-registering is a
    ///      safety action — a custodian discovered to be lying must stop being believed now,
    ///      not in 48 hours — and the same switch is what makes registering a new one
    ///      symmetric. The blast radius of registering is bounded by {IActivationCustodian}'s
    ///      trust model: a custodian can only speak for tokens it already holds.
    ///
    ///      REVOKING RESETS. Once de-registered, the custodian's own address becomes the
    ///      effective owner of everything it holds, which never matches an `ownerAtActivation`
    ///      that was set to a beneficiary — so every activation it was carrying goes inactive
    ///      immediately. Depositors re-activate after withdrawing. That is the correct
    ///      direction for a custodian that has gone bad, and the cost of the emergency stop.
    function setCustodian(address custodian, bool allowed) external onlyOwner {
        if (custodian == address(0)) revert ZeroAddress();
        isCustodian[custodian] = allowed;
        emit CustodianSet(custodian, allowed);
    }

    /* ------------------------------------------------------------------ */
    /*                    GOVERNANCE: COSTS (48h TIMELOCK)                  */
    /* ------------------------------------------------------------------ */

    /// @notice Queue a collection's cost table. Also how a collection is registered.
    /// @dev Costs must be non-decreasing across tiers, so an upgrade always costs something
    ///      and the difference can never underflow. Zero is allowed, including all zeros for
    ///      a free-activation collection.
    function queueCosts(address collection, uint256[TIER_COUNT] calldata cost) external onlyOwner {
        if (collection == address(0)) revert ZeroAddress();
        _validateCosts(cost);
        uint64 executableAt = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingCosts[collection] = PendingCosts({queued: true, executableAt: executableAt, cost: cost});
        emit CostsQueued(collection, cost, executableAt);
    }

    /// @notice Apply a queued cost table once its notice period has elapsed.
    /// @dev Executing also marks the collection configured, so registering a collection and
    ///      pricing it are the same action and a collection can never be live at zero cost
    ///      by accident.
    function executeCosts(address collection) external onlyOwner {
        PendingCosts memory p = _pendingCosts[collection];
        if (!p.queued) revert NothingQueued();
        if (block.timestamp < p.executableAt) revert TimelockNotElapsed(uint64(block.timestamp), p.executableAt);

        _tierCost[collection] = p.cost;
        collectionConfigured[collection] = true;
        delete _pendingCosts[collection];

        emit CostsExecuted(collection, p.cost);
    }

    function cancelCosts(address collection) external onlyOwner {
        if (!_pendingCosts[collection].queued) revert NothingQueued();
        delete _pendingCosts[collection];
        emit CostsCancelled(collection);
    }

    /* ------------------------------------------------------------------ */
    /*                    GOVERNANCE: TIERS (48h TIMELOCK)                  */
    /* ------------------------------------------------------------------ */

    /// @notice Queue a change to the weight curve. Multisig only, 48h notice.
    /// @dev Stricter than the retired Clutch adapter on purpose: this table decides what
    ///      every activated Noun earns, and it should not be able to move without notice.
    function queueTierBps(uint32[TIER_COUNT] calldata bps) external onlyOwner {
        _validateTiers(bps);
        uint64 executableAt = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingTiers = PendingTiers({queued: true, executableAt: executableAt, bps: bps});
        emit TiersQueued(bps, executableAt);
    }

    function executeTierBps() external onlyOwner {
        PendingTiers memory p = _pendingTiers;
        if (!p.queued) revert NothingQueued();
        if (block.timestamp < p.executableAt) revert TimelockNotElapsed(uint64(block.timestamp), p.executableAt);

        tierBps = p.bps;
        delete _pendingTiers;

        emit TiersExecuted(p.bps);
    }

    function cancelTierBps() external onlyOwner {
        if (!_pendingTiers.queued) revert NothingQueued();
        delete _pendingTiers;
        emit TiersCancelled();
    }

    /// @dev Non-decreasing and never zero. A zero would read as inactive in {activation},
    ///      silently un-chipping every Noun at that tier.
    function _validateTiers(uint32[TIER_COUNT] memory bps) internal pure {
        for (uint256 i; i < TIER_COUNT; ++i) {
            if (bps[i] == 0) revert BadConfig();
            if (i != 0 && bps[i] < bps[i - 1]) revert BadConfig();
        }
    }

    function _validateCosts(uint256[TIER_COUNT] memory cost) internal pure {
        for (uint256 i = 1; i < TIER_COUNT; ++i) {
            if (cost[i] < cost[i - 1]) revert BadConfig();
        }
    }

    /* ------------------------------------------------------------------ */
    /*                              RESCUE                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Sweep a token that ended up here. Multisig only.
    ///
    /// @dev NO EXCLUSION LIST IS NEEDED, BECAUSE THERE IS NOTHING TO EXCLUDE. This contract
    ///      holds no user asset at any point: activation costs go straight to `0xdead` inside
    ///      the same call, and it never takes custody of a Noun. Its $CHIP balance is zero
    ///      between transactions, which `test_theContractNeverHoldsChip` asserts across every
    ///      operation, so sweeping $CHIP can only ever move a stray donation.
    ///      That is a stronger guarantee than an exclusion list, not a weaker one: an
    ///      exclusion list protects a balance that exists, and here none does.
    function recoverExcess(address token, address to) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) {
            IERC20(token).safeTransfer(to, amount);
            emit Recovered(token, to, amount);
        }
    }

    /// @notice Return an NFT that was pushed here. Multisig only.
    /// @dev Soft staking means this contract is never the legitimate owner of a Noun. There
    ///      is no `onERC721Received`, so `safeTransferFrom` into it reverts; a bare
    ///      `transferFrom` can still strand one, and this returns it. Nothing is protected
    ///      from this call because nothing here is supposed to exist — and a Noun sitting at
    ///      this address has already lost its activation, since this contract is not a
    ///      registered custodian of itself.
    function recoverNFT(address collection, uint256 tokenId, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        IERC721(collection).transferFrom(address(this), to, tokenId);
        emit RecoveredNFT(collection, tokenId, to);
    }
}
