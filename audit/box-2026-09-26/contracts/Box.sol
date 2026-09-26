// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IBox} from "../interfaces/IBox.sol";
import {IChipConverter} from "../interfaces/IChipConverter.sol";
import {IEntropyV2} from "../interfaces/IEntropyV2.sol";
import {IPrizeVault} from "../interfaces/IPrizeVault.sol";

/// @title Box
/// @notice Sealed, giftable ERC-721 ChipWorks boxes. Buy with USDC or $CHIP; open for a
///         random Coinbase B20 prize sized by a published on-chain odds table.
///
/// @dev UNAUDITED. Do not treat this as part of the Anvil / rounds review surface.
///
///      THIS IS A NEW PRODUCT FAMILY. It shares no storage, no inheritance and no call
///      path with Anvil. Anvil's {buyNext} is a FIFO shelf of known Nouns; this is a
///      gacha. The two must not be bolted together — a bug in the draw cannot touch the
///      Noun shelf, and a bug on the shelf cannot mint a Box.
///
///      FEE SPLIT IS STRUCTURAL. Every sale arrives as the box's exact USDC price and is split
///      in the same transaction: 5% (`FEE_BPS`) to {feeRecipient} / {treasury}, 95% to {vault}.
///      A $CHIP buy is swapped to that USDC price INSIDE the buy by the {converter} (the
///      deployed ChipLottery's swap), so the pool is funded at face whatever $CHIP does. The
///      earlier fixed-$CHIP-price, sell-later design let a buyer pay $4.75 into the pool for a
///      "$10" box when $CHIP halved (audit round 1, H-1). The Box holds no USDC or $CHIP between calls. Launch recipient is the FeeSplitter
///      ({DEFAULT_FEE_RECIPIENT}: 80% Pot / 20% ops); retarget is 48h-timelocked.
///
///      RTP IS THE TABLE. {oddsTable} is the only source of prize weights. The UI MUST
///      render that table and {previewDraw}, not a parallel copy. Constructor table is
///      91.00% EV of face price. The house take is 9% of face: the 5% fee, plus ~4% that
///      stays in the vault and reaches the fee recipient through {PrizeVault.sweepSurplus}.
///      Every tier pays a B20 stock, or USDC when no stock can cover it; never $CHIP.
///      Changing the table is timelocked.
///
///      HONEST ODDS: NEVER PAID SHORT. A SKU cannot be bought while the vault could not pay
///      its top prize in full ({isSkuCovered}). If a drawn prize still cannot be paid at
///      callback time (the pool shrank between buy and open), NOTHING is paid and the box
///      becomes OWED at exactly the drawn size; anyone can {claimOwed} it later and it is
///      paid to the opener in full. It is never re-rolled.
///
///      RANDOMNESS IS PYTH ENTROPY V2. {open} is payable. It reads {getFeeV2} for the
///      configured callback gas limit, forwards that exact fee, and refunds any excess
///      ETH (M-08). {buy*}/{open}/{retryOpen} revert unless {IPrizeVault.box} == this
///      (H-04 / H-01: no payment into an unwired vault).
///      The Entropy contract later calls {_entropyCallback}. That callback must not
///      revert: an unpaid or reverting {IPrizeVault.settle} leaves the NFT OWED with the
///      drawn prize fixed (no silent burn, no re-roll). Basescan sees
///      {BoxOpeningRequested}, then {BoxOpened} (paid) or {PrizeOwed}.
///
///      MINT TERMS ARE SNAPSHOTTED (H-05). Each box stores face USDC, odds version and
///      EV at mint. {executeSku}/{executeOdds} cannot rewrite a sealed ticket. Retiring
///      a SKU ({exists: false}) while {sealedSupply} > 0 reverts (H-03).
///
///      $CHIP AND USDC ARE BOTH LIVE PAYMENT ASSETS. Launch token is {DEFAULT_CHIP} on Base.
///      {IPrizeVault.chip} and the converter's chip MUST equal {chip} at construct.
///      `chip == address(0)` (with `converter == address(0)`) or a SKU with `chipEnabled` false
///      disables the CHIP path without affecting USDC. {buy*} revert unless the vault is
///      wired to this Box. $CHIP is a payment asset only: it is never a prize.
contract Box is IBox, ERC721, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    uint16 public constant override FEE_BPS = 500;
    uint16 public constant override WEIGHT_DENOM = 10_000;
    uint8 public constant MAX_SKUS = 3;
    uint8 public constant MAX_TIERS = 8;
    uint8 public constant STATE_SEALED = 1;
    uint8 public constant STATE_OPENING = 2;
    uint8 public constant STATE_OWED = 3;
    uint256 public constant MAX_BATCH = 20;
    uint64 public constant CONFIG_TIMELOCK = 48 hours;
    uint64 public constant CONFIG_GRACE = 14 days;
    /// @notice How long an open must go completely unrevealed before {retryOpen}. See there.
    uint64 public constant REVEAL_TIMEOUT = 30 days;
    /// @dev EntropyStatusConstants.CALLBACK_NOT_STARTED: requested, never revealed.
    uint8 internal constant CALLBACK_NOT_STARTED = 1;
    /// @notice The owner cannot set the callback gas below what a payout needs with the vault's
    ///         maximum stock list ({PrizeVault.MAX_STOCKS} = 16). Measured with real B20s on the
    ///         live node (tools/box/box-callback-sim.cjs): ~36k gas per listed stock, 573k with 13
    ///         listed, so ~683k at 16. 900k keeps ~30% over that; the 1M default keeps ~46%.
    uint32 public constant MIN_CALLBACK_GAS = 900_000;
    uint32 public constant MAX_CALLBACK_GAS = 2_000_000;

    uint8 public constant SKU_ONE_USD = 0;
    uint8 public constant SKU_TEN_USD = 1;
    uint8 public constant SKU_TWENTY_FIVE_USD = 2;

    /// @notice Default fee recipient: the live FeeSplitter (80% Pot / 20% ops). It splits any
    ///        ERC-20 permissionlessly; the Pot's round currency is USDC, which is why every
    ///        fee reaches it as USDC and never as $CHIP (the Pot has no $CHIP route).
    /// @dev Constructor still takes `treasury_` so a deploy can override. Changing a live
    ///      recipient is {queueTreasury}.
    address public constant DEFAULT_FEE_RECIPIENT = 0xb9b76e1835afE05e5A73065FE01A19B14869F8A3;

    /// @notice $CHIP on Base. Scripts default the constructor `chip_` to this.
    address public constant DEFAULT_CHIP = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;

    /// @notice USDC on Base (6 decimals). Scripts default `usdc_` to this.
    address public constant DEFAULT_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address public immutable override usdc;
    address public immutable override chip;
    address public immutable override vault;
    address public immutable override converter;
    address public immutable override entropy;

    address public override treasury;
    /// @dev 1M, not 500k: with real B20s and ten stocks listed the callback measured 529k before
    ///      {PrizeVault._snapshot} (tools/box/box-callback-sim.cjs). Pyth charges little for the
    ///      headroom: 0.000020 ETH at 1M against 0.000015 at 500k.
    uint32 public override callbackGasLimit = 1_000_000;
    bool public paused;
    /// @notice Stops {buyWithChip} alone, at once (audit round 2, BOX-L1). The converter and its pool
    ///         are immutable, so if the $CHIP pool graduates, drains or changes hook, $CHIP sales stop
    ///         here without the 48h SKU queue and without stopping USDC sales.
    bool public chipPaused;
    string public baseURI;
    uint256 public nextId = 1;

    mapping(uint8 => Sku) internal _skus;
    mapping(uint8 => uint256) public override sealedSupply;
    mapping(uint256 => BoxView) internal _info;
    /// @dev Keyed by (provider, sequence), not sequence alone: Entropy numbers requests PER
    ///      PROVIDER, so after a default-provider change two opens can share a sequence number
    ///      (audit round 1, F-2). See {_requestKey}.
    mapping(bytes32 => uint256) internal _tokenIdOfRequest;
    /// @dev The Entropy provider each open was requested from.
    mapping(uint256 => address) internal _providerOf;

    /// @notice Largest single prize any box ever sold can win (6 dp). Only ever rises; see
    ///         {maxLivePrizeUsd}. Conservative on purpose: after the last such box is opened it
    ///         keeps the sweep's reserve higher than it needs to be, never lower.
    uint256 public maxSoldPrizeUsd;

    /// @notice USD EV of every sealed + opening box, snapshotted at mint (6 decimals).
    uint256 public override outstandingLiabilityUsd;

    /// @notice Current odds-table version. Mint snapshots this onto each box (H-05).
    uint64 public oddsVersion;

    struct OddsSnapshot {
        uint8 count;
        PrizeTier[MAX_TIERS] tiers;
    }

    mapping(uint64 => OddsSnapshot) internal _oddsSnapshots;

    struct PendingAddress {
        bool queued;
        uint64 executableAt;
        address target;
    }

    struct PendingSku {
        bool queued;
        uint64 executableAt;
        uint8 id;
        Sku sku;
    }

    struct PendingOdds {
        bool queued;
        uint64 executableAt;
        uint8 count;
        PrizeTier[MAX_TIERS] tiers;
    }

    PendingAddress internal _pendingTreasury;
    PendingSku internal _pendingSku;
    PendingOdds internal _pendingOdds;

    event BoxPurchased(
        address indexed buyer,
        address indexed to,
        uint256 indexed tokenId,
        uint8 skuId,
        address paymentToken,
        uint256 price,
        uint256 fee,
        uint256 toVault
    );
    /// @notice A $CHIP buy: `chipSpent` of the buyer's $CHIP bought exactly `usdc` for the Box.
    event PaidInChip(address indexed buyer, uint256 chipSpent, uint256 usdc);
    event BoxOpeningRequested(
        address indexed opener, uint256 indexed tokenId, uint64 indexed sequence, uint8 skuId, uint128 entropyFee
    );
    event BoxOpened(
        address indexed opener,
        uint256 indexed tokenId,
        uint64 indexed sequence,
        uint8 skuId,
        uint8 tierId,
        uint32 prizeBps,
        uint256 prizeUsd,
        address stock,
        uint256 stockAmount,
        uint256 usdcAmount,
        bool fallbackStock,
        bool usdcFallback
    );
    event OrphanCallback(uint64 indexed sequence, address indexed provider);
    /// @notice Drawn but not paid: the pool could not cover it in full. Fixed at `prizeUsd`;
    ///         {claimOwed} pays exactly this to `opener` once the pool can.
    event PrizeOwed(
        address indexed opener, uint256 indexed tokenId, uint8 tierId, uint256 prizeUsd, bool capped
    );
    event PausedSet(bool paused);
    event ChipPausedSet(bool paused);
    event SkuPaused(uint8 indexed skuId, bool paused);
    event TreasuryQueued(address indexed treasury, uint64 executableAt);
    event TreasurySet(address indexed previous, address indexed current);
    event TreasuryCancelled();
    event SkuQueued(uint8 indexed skuId, uint96 usdcPrice, bool chipEnabled, uint64 executableAt);
    event SkuExecuted(uint8 indexed skuId, uint96 usdcPrice, bool chipEnabled);
    event SkuCancelled();
    event OddsQueued(uint8 count, uint64 executableAt);
    event OddsExecuted(uint8 count, uint256 rtpBps);
    event OddsCancelled();
    event CallbackGasLimitSet(uint32 gasLimit);
    event BaseURISet(string baseURI);

    error ZeroAddress();
    error BadConfig();
    error PausedError();
    error SkuPausedError(uint8 skuId);
    error UnknownSku(uint8 skuId);
    error ChipDisabled();
    error NotOwner();
    error NotSealed(uint256 tokenId);
    error NotOpening(uint256 tokenId);
    error NotOwed(uint256 tokenId);
    error StillUnpayable(uint256 tokenId, uint256 prizeUsd);
    error SkuNotCovered(uint8 skuId, uint256 topPrizeUsd, uint256 prizeCapUsd);
    error RevealNotTimedOut(uint64 nowTs, uint64 readyAt);
    error RevealAlreadyPublic(uint256 tokenId, uint8 callbackStatus);
    error BoxLocked(uint256 tokenId);
    error Underpaid(uint256 sent, uint256 required);
    error RefundFailed();
    error OnlyEntropy();
    error VaultNotWired();
    error ConverterNotWired();
    error SealedSupplyOutstanding(uint8 skuId);
    error BatchTooLarge(uint256 n);
    error DeadlinePassed(uint256 nowTs, uint256 deadline);
    error NothingQueued();
    error TimelockNotElapsed(uint64 nowTs, uint64 executableAt);
    error TimelockExpired(uint64 nowTs, uint64 expiredAt);

    /// @param multisig       Owner. Two-step.
    /// @param usdc_          USDC on Base. 6 decimals. Launch default {DEFAULT_USDC}.
    /// @param chip_          $CHIP token. Launch default {DEFAULT_CHIP}. `address(0)`
    ///                       disables {buyWithChip} without affecting USDC.
    /// @param treasury_      5% recipient ({feeRecipient}). Launch default is
    ///                       {DEFAULT_FEE_RECIPIENT} (the FeeSplitter). Retarget is 48h-timelocked.
    /// @param vault_         PrizeVault. 95% of a USDC payment; every payout.
    /// @param converter_     ChipConverter. Swaps a $CHIP buyer's $CHIP to the exact USDC price.
    ///                       `address(0)` only together with `chip_ == address(0)`.
    /// @param entropy_       Pyth Entropy v2. Base: 0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb.
    constructor(
        address multisig,
        address usdc_,
        address chip_,
        address treasury_,
        address vault_,
        address converter_,
        address entropy_
    ) ERC721("ChipWorks Box", "CBOX") Ownable(multisig) {
        if (multisig == address(0) || usdc_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        if (vault_ == address(0) || entropy_ == address(0)) revert ZeroAddress();
        if (chip_ == usdc_) revert BadConfig();
        // The vault refuses {chip} as stock, so it must know which token that is.
        if (IPrizeVault(vault_).chip() != chip_) revert BadConfig();
        if (IPrizeVault(vault_).usdc() != usdc_) revert BadConfig();
        // A CHIP path needs a converter for the same CHIP and USDC; no CHIP path, no converter.
        if ((chip_ == address(0)) != (converter_ == address(0))) revert BadConfig();
        if (converter_ != address(0)) {
            if (IChipConverter(converter_).chip() != chip_ || IChipConverter(converter_).usdc() != usdc_) {
                revert BadConfig();
            }
        }
        usdc = usdc_;
        chip = chip_;
        treasury = treasury_;
        vault = vault_;
        converter = converter_;
        entropy = entropy_;

        bool chipOn = converter_ != address(0);
        _skus[SKU_ONE_USD] = Sku({exists: true, paused: false, usdcPrice: 1_000_000, chipEnabled: chipOn});
        _skus[SKU_TEN_USD] = Sku({exists: true, paused: false, usdcPrice: 10_000_000, chipEnabled: chipOn});
        _skus[SKU_TWENTY_FIVE_USD] = Sku({exists: true, paused: false, usdcPrice: 25_000_000, chipEnabled: chipOn});

        _loadLaunchOdds();
        emit TreasurySet(address(0), treasury_);
        emit SkuExecuted(SKU_ONE_USD, 1_000_000, chipOn);
        emit SkuExecuted(SKU_TEN_USD, 10_000_000, chipOn);
        emit SkuExecuted(SKU_TWENTY_FIVE_USD, 25_000_000, chipOn);
        emit OddsExecuted(_oddsSnapshots[0].count, rtpBps());
    }

    /* ------------------------------------------------------------------ */
    /*                               BUY                                    */
    /* ------------------------------------------------------------------ */

    function buyWithUsdc(uint8 skuId, address to) external override nonReentrant returns (uint256 tokenId) {
        uint256 price = _liveSku(skuId).usdcPrice;
        _gate(skuId);
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), price);
        tokenId = _buy(skuId, to, usdc, price);
    }

    /// @notice Buy with $CHIP. The $CHIP is swapped to the box's exact USDC price inside this call;
    ///         the buyer pays the pool's swap cost (~2.3% measured) and gets back whatever $CHIP
    ///         and WETH the swap did not need.
    /// @param wethNeeded WETH the USDC leg needs, quoted off chain (a bound; the rest is refunded).
    /// @param maxChipIn  The most $CHIP the buyer will spend. Approve the Box for this much.
    function buyWithChip(uint8 skuId, address to, uint256 wethNeeded, uint256 maxChipIn, uint256 deadline)
        external
        override
        nonReentrant
        returns (uint256 tokenId)
    {
        uint256 price = _liveChipSku(skuId).usdcPrice;
        _gate(skuId);
        _payInChip(price, wethNeeded, maxChipIn, deadline);
        tokenId = _buy(skuId, to, chip, price);
    }

    function buyWithUsdcBatch(uint8 skuId, address to, uint256 n)
        external
        override
        nonReentrant
        returns (uint256 firstId)
    {
        if (n == 0 || n > MAX_BATCH) revert BatchTooLarge(n);
        uint256 price = _liveSku(skuId).usdcPrice;
        _gate(skuId);
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), price * n);
        firstId = nextId;
        for (uint256 i; i < n; ++i) {
            _buy(skuId, to, usdc, price);
        }
    }

    /// @notice `n` boxes for $CHIP in one swap of `n` times the price. See {buyWithChip}.
    function buyWithChipBatch(
        uint8 skuId,
        address to,
        uint256 n,
        uint256 wethNeeded,
        uint256 maxChipIn,
        uint256 deadline
    ) external override nonReentrant returns (uint256 firstId) {
        if (n == 0 || n > MAX_BATCH) revert BatchTooLarge(n);
        uint256 price = _liveChipSku(skuId).usdcPrice;
        _gate(skuId);
        _payInChip(price * n, wethNeeded, maxChipIn, deadline);
        firstId = nextId;
        for (uint256 i; i < n; ++i) {
            _buy(skuId, to, chip, price);
        }
    }

    /* ------------------------------------------------------------------ */
    /*                               OPEN                                   */
    /* ------------------------------------------------------------------ */

    /// @notice Burn the seal: request Entropy, pay the Pyth fee in ETH, wait for the callback.
    /// @dev Reads {getFeeV2} for `callbackGasLimit` on every call. Excess ETH is refunded;
    ///      Entropy itself does not refund. The box is locked (not transferable) until the
    ///      callback burns it.
    function open(uint256 tokenId) external payable override nonReentrant {
        if (paused) revert PausedError();
        if (ownerOf(tokenId) != msg.sender) revert NotOwner();
        BoxView storage b = _info[tokenId];
        if (b.state != STATE_SEALED) revert NotSealed(tokenId);
        if (_skus[b.skuId].paused) revert SkuPausedError(b.skuId);
        _requestEntropy(tokenId, b);
    }

    /// @notice Last resort: ask Entropy for NEW randomness, only if the original request was never
    ///         revealed at all within {REVEAL_TIMEOUT} (the provider is gone).
    /// @dev NOT A RE-ROLL. When a callback fails, Pyth publishes the random number in
    ///      `CallbackFailed` and marks the request CALLBACK_FAILED; the fix for that is Pyth's own
    ///      permissionless `revealWithCallback`, which re-runs this Box's callback with the SAME
    ///      number (the keeper does it). Allowing fresh randomness there would let a holder read a
    ///      bad draw and roll again, so this refuses anything but CALLBACK_NOT_STARTED. The 30-day
    ///      timeout covers the remaining case: Fortuna serves revelations over HTTP, so an
    ///      unrevealed draw is computable off chain, and the keeper completes stuck reveals long
    ///      before any holder could wait out the clock.
    function retryOpen(uint256 tokenId) external payable override nonReentrant {
        if (paused) revert PausedError();
        BoxView storage b = _info[tokenId];
        if (b.state != STATE_OPENING) revert NotOpening(tokenId);
        if (b.opener != msg.sender) revert NotOwner();
        uint64 readyAt = b.openingStartedAt + REVEAL_TIMEOUT;
        if (block.timestamp < readyAt) revert RevealNotTimedOut(uint64(block.timestamp), readyAt);
        IEntropyV2.RequestV2 memory r = IEntropyV2(entropy).getRequestV2(_providerOf[tokenId], b.sequence);
        if (r.sequenceNumber != b.sequence || r.callbackStatus != CALLBACK_NOT_STARTED) {
            revert RevealAlreadyPublic(tokenId, r.callbackStatus);
        }
        delete _tokenIdOfRequest[_requestKey(_providerOf[tokenId], b.sequence)];
        _requestEntropy(tokenId, b);
    }

    /// @notice Pay an OWED box its drawn prize, in full, to the address that opened it.
    ///         Permissionless: the recipient is fixed, so anyone may push it through once
    ///         the pool can cover it. Reverts (moving nothing) while it still cannot.
    function claimOwed(uint256 tokenId) external override nonReentrant {
        BoxView memory b = _info[tokenId];
        if (b.state != STATE_OWED) revert NotOwed(tokenId);
        IPrizeVault.Payout memory payout =
            IPrizeVault(vault).settle(b.opener, b.owedUsd, keccak256(abi.encode(tokenId, b.sequence)));
        if (!payout.paid) revert StillUnpayable(tokenId, b.owedUsd);
        outstandingLiabilityUsd -= b.owedUsd;
        _retire(tokenId, b.skuId);
        _emitOpened(b.opener, tokenId, b.sequence, b.skuId, type(uint8).max, 0, b.owedUsd, payout);
    }

    /// @notice Pyth Entropy v2 callback body. Entropy itself calls {_entropyCallback}
    ///         (IEntropyConsumer._entropyCallback, read from the verified Base implementation).
    /// @dev Never reverts on a failed payout. A revert here would stall the keeper.
    function entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) public {
        if (msg.sender != entropy) revert OnlyEntropy();
        _fulfill(sequence, provider, randomNumber);
    }

    /// @dev THE SELECTOR PYTH CALLS: Entropy.revealWithCallback invokes this on
    ///      the requester, gas-capped at the request's limit. On failure Pyth publishes the number
    ///      and marks the request CALLBACK_FAILED; re-running revealWithCallback calls this again
    ///      with the SAME number and all remaining gas. See {retryOpen}.
    function _entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) external {
        entropyCallback(sequence, provider, randomNumber);
    }

    /* ------------------------------------------------------------------ */
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    function feeRecipient() public view override returns (address) {
        return treasury;
    }

    function sku(uint8 id) public view override returns (Sku memory) {
        return _skus[id];
    }

    function oddsTierCount() public view override returns (uint256) {
        return _oddsSnapshots[oddsVersion].count;
    }

    function oddsTable() public view override returns (PrizeTier[] memory tiers) {
        OddsSnapshot storage snap = _oddsSnapshots[oddsVersion];
        uint256 n = snap.count;
        tiers = new PrizeTier[](n);
        for (uint256 i; i < n; ++i) {
            tiers[i] = snap.tiers[i];
        }
    }

    /// @notice Player RTP of the published table, in bps. Launch table is 9100 (91.00%).
    function rtpBps() public view override returns (uint256) {
        return _rtpBpsAt(oddsVersion);
    }

    function expectedValueUsd(uint8 skuId) public view override returns (uint256) {
        Sku memory s = _skus[skuId];
        if (!s.exists) revert UnknownSku(skuId);
        return uint256(s.usdcPrice) * rtpBps() / WEIGHT_DENOM;
    }

    /// @inheritdoc IBox
    function maxPrizeUsd(uint8 skuId) public view override returns (uint256) {
        Sku memory s = _skus[skuId];
        if (!s.exists) revert UnknownSku(skuId);
        return uint256(s.usdcPrice) * _maxTierBpsAt(oddsVersion) / WEIGHT_DENOM;
    }

    /// @inheritdoc IBox
    /// @dev Two sources, the larger wins. (1) Every SKU on sale, at the current table: what the
    ///      next sale could owe. (2) {maxSoldPrizeUsd}: the largest prize any box ALREADY SOLD
    ///      can win. A sold box keeps its mint face and odds version (H-05), so pausing a SKU,
    ///      cutting its price or lowering the top tier must not shrink the reserve under it.
    function maxLivePrizeUsd() public view override returns (uint256 m) {
        m = maxSoldPrizeUsd;
        uint32 top = _maxTierBpsAt(oddsVersion);
        for (uint8 i; i < MAX_SKUS; ++i) {
            Sku memory s = _skus[i];
            if (!s.exists || s.paused) continue;
            uint256 p = uint256(s.usdcPrice) * top / WEIGHT_DENOM;
            if (p > m) m = p;
        }
    }

    /// @inheritdoc IBox
    function isSkuCovered(uint8 skuId) public view override returns (bool) {
        return IPrizeVault(vault).prizeCapUsd() >= maxPrizeUsd(skuId);
    }

    function quoteOpenFee() public view override returns (uint128) {
        return IEntropyV2(entropy).getFeeV2(callbackGasLimit);
    }

    function previewDraw(bytes32 randomNumber, uint8 skuId)
        public
        view
        override
        returns (uint8 tierId, uint16 weight, uint32 prizeBps, uint256 prizeUsd)
    {
        Sku memory s = _skus[skuId];
        if (!s.exists) revert UnknownSku(skuId);
        (tierId, weight, prizeBps, prizeUsd) = _drawAt(randomNumber, s.usdcPrice, oddsVersion);
    }

    function boxInfo(uint256 tokenId) external view override returns (BoxView memory) {
        return _info[tokenId];
    }

    /// @notice The Entropy provider an opening box was requested from. The keeper needs it to
    ///         complete a stuck reveal through Entropy.revealWithCallback.
    function openingProvider(uint256 tokenId) external view returns (address) {
        return _providerOf[tokenId];
    }

    function tokenIdOfRequest(address provider, uint64 sequence) external view override returns (uint256) {
        return _tokenIdOfRequest[_requestKey(provider, sequence)];
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return string.concat(baseURI, tokenId.toString());
    }

    /* ------------------------------------------------------------------ */
    /*                          ADMIN: SAFETY                               */
    /* ------------------------------------------------------------------ */

    function setPaused(bool v) external onlyOwner {
        paused = v;
        emit PausedSet(v);
    }

    function setChipPaused(bool v) external onlyOwner {
        chipPaused = v;
        emit ChipPausedSet(v);
    }

    function setSkuPaused(uint8 skuId, bool v) external onlyOwner {
        if (!_skus[skuId].exists) revert UnknownSku(skuId);
        _skus[skuId].paused = v;
        emit SkuPaused(skuId, v);
    }

    function setCallbackGasLimit(uint32 gasLimit) external onlyOwner {
        if (gasLimit < MIN_CALLBACK_GAS || gasLimit > MAX_CALLBACK_GAS) revert BadConfig();
        callbackGasLimit = gasLimit;
        emit CallbackGasLimitSet(gasLimit);
    }

    function setBaseURI(string calldata v) external onlyOwner {
        baseURI = v;
        emit BaseURISet(v);
    }

    /* ------------------------------------------------------------------ */
    /*                     ADMIN: TREASURY (48h)                            */
    /* ------------------------------------------------------------------ */

    /// @notice Queue a change of the 5% recipient. 48h notice, 14d grace.
    /// @dev Redirects protocol take. Immediate pause is the safety lever while this matures.
    function queueTreasury(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        uint64 executableAt = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingTreasury = PendingAddress({queued: true, executableAt: executableAt, target: v});
        emit TreasuryQueued(v, executableAt);
    }

    function executeTreasury() external onlyOwner {
        PendingAddress memory p = _pendingTreasury;
        if (!p.queued) revert NothingQueued();
        _requireInWindow(p.executableAt);
        emit TreasurySet(treasury, p.target);
        treasury = p.target;
        delete _pendingTreasury;
    }

    function cancelTreasury() external onlyOwner {
        if (!_pendingTreasury.queued) revert NothingQueued();
        delete _pendingTreasury;
        emit TreasuryCancelled();
    }

    /* ------------------------------------------------------------------ */
    /*                       ADMIN: SKUS / ODDS                             */
    /* ------------------------------------------------------------------ */

    /// @notice Queue a SKU price (and whether it exists). Launch SKUs are $1 / $10 / $25.
    function queueSku(uint8 id, bool exists, uint96 usdcPrice, bool chipEnabled) external onlyOwner {
        if (id >= MAX_SKUS) revert UnknownSku(id);
        if (exists && usdcPrice == 0) revert BadConfig();
        if (chipEnabled && converter == address(0)) revert BadConfig();
        uint64 executableAt = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingSku = PendingSku({
            queued: true,
            executableAt: executableAt,
            id: id,
            sku: Sku({exists: exists, paused: _skus[id].paused, usdcPrice: usdcPrice, chipEnabled: chipEnabled})
        });
        emit SkuQueued(id, usdcPrice, chipEnabled, executableAt);
    }

    function executeSku() external onlyOwner {
        PendingSku memory p = _pendingSku;
        if (!p.queued) revert NothingQueued();
        _requireInWindow(p.executableAt);
        // H-03: retiring a SKU while tickets remain would make live EV revert and, before
        // mint snapshots, zero the surplus floor / pay a $0 prize.
        if (!p.sku.exists && sealedSupply[p.id] != 0) revert SealedSupplyOutstanding(p.id);
        _skus[p.id] = p.sku;
        emit SkuExecuted(p.id, p.sku.usdcPrice, p.sku.chipEnabled);
        delete _pendingSku;
    }

    function cancelSku() external onlyOwner {
        if (!_pendingSku.queued) revert NothingQueued();
        delete _pendingSku;
        emit SkuCancelled();
    }

    /// @notice Queue a replacement odds table. Weights must sum to {WEIGHT_DENOM}.
    function queueOdds(PrizeTier[] calldata tiers) external onlyOwner {
        uint8 n = uint8(tiers.length);
        if (n == 0 || n > MAX_TIERS) revert BadConfig();
        uint256 w;
        for (uint256 i; i < n; ++i) {
            if (tiers[i].weight == 0 || tiers[i].prizeBps == 0) revert BadConfig();
            w += tiers[i].weight;
        }
        if (w != WEIGHT_DENOM) revert BadConfig();
        uint64 executableAt = uint64(block.timestamp) + CONFIG_TIMELOCK;
        PendingOdds storage q = _pendingOdds;
        q.queued = true;
        q.executableAt = executableAt;
        q.count = n;
        for (uint256 i; i < n; ++i) {
            q.tiers[i] = tiers[i];
        }
        emit OddsQueued(n, executableAt);
    }

    function executeOdds() external onlyOwner {
        PendingOdds storage q = _pendingOdds;
        if (!q.queued) revert NothingQueued();
        _requireInWindow(q.executableAt);
        uint64 v = oddsVersion + 1;
        OddsSnapshot storage snap = _oddsSnapshots[v];
        snap.count = q.count;
        for (uint256 i; i < q.count; ++i) {
            snap.tiers[i] = q.tiers[i];
        }
        oddsVersion = v;
        delete _pendingOdds;
        emit OddsExecuted(snap.count, rtpBps());
    }

    function cancelOdds() external onlyOwner {
        if (!_pendingOdds.queued) revert NothingQueued();
        delete _pendingOdds;
        emit OddsCancelled();
    }

    /* ------------------------------------------------------------------ */
    /*                              INTERNAL                                */
    /* ------------------------------------------------------------------ */

    function _liveSku(uint8 skuId) internal view returns (Sku memory s) {
        if (paused) revert PausedError();
        s = _skus[skuId];
        if (!s.exists) revert UnknownSku(skuId);
        if (s.paused) revert SkuPausedError(skuId);
    }

    /// @dev Before ANY payment moves: the vault is wired (H-04), and the pool can pay this SKU's top
    ///      prize in full (honest odds). Buying only grows the pool, so one check covers a batch.
    function _gate(uint8 skuId) internal view {
        if (IPrizeVault(vault).box() != address(this)) revert VaultNotWired();
        uint256 top = maxPrizeUsd(skuId);
        uint256 cap = IPrizeVault(vault).prizeCapUsd();
        if (cap < top) revert SkuNotCovered(skuId, top, cap);
    }

    function _liveChipSku(uint8 skuId) internal view returns (Sku memory s) {
        if (converter == address(0) || chipPaused) revert ChipDisabled();
        s = _liveSku(skuId);
        if (!s.chipEnabled) revert ChipDisabled();
    }

    /// @dev The buyer's $CHIP goes straight to the converter (never through the Box), which sends
    ///      exactly `usdcOut` here and returns every unspent $CHIP and WETH to the buyer.
    function _payInChip(uint256 usdcOut, uint256 wethNeeded, uint256 maxChipIn, uint256 deadline) internal {
        if (block.timestamp > deadline) revert DeadlinePassed(block.timestamp, deadline);
        if (IChipConverter(converter).box() != address(this)) revert ConverterNotWired();
        IERC20(chip).safeTransferFrom(msg.sender, converter, maxChipIn);
        uint256 spent = IChipConverter(converter).swapToUsdc(usdcOut, wethNeeded, maxChipIn, msg.sender);
        emit PaidInChip(msg.sender, spent, usdcOut);
    }

    /// @dev The price is already HERE in USDC: pulled from the buyer, or swapped from their $CHIP.
    ///      `token` only labels how it was paid.
    function _buy(uint8 skuId, address to, address token, uint256 price) internal returns (uint256 tokenId) {
        if (to == address(0)) revert ZeroAddress();
        if (price == 0) revert BadConfig();
        {
            uint256 top = maxPrizeUsd(skuId);
            if (top > maxSoldPrizeUsd) maxSoldPrizeUsd = top;
        }

        uint256 fee = price * FEE_BPS / WEIGHT_DENOM;
        uint256 toVault = price - fee;
        IERC20(usdc).safeTransfer(treasury, fee);
        IERC20(usdc).safeTransfer(vault, toVault);

        uint96 faceUsd = _skus[skuId].usdcPrice;
        uint64 ver = oddsVersion;
        uint256 ev = uint256(faceUsd) * _rtpBpsAt(ver) / WEIGHT_DENOM;
        outstandingLiabilityUsd += ev;

        tokenId = nextId++;
        _info[tokenId] = BoxView({
            skuId: skuId,
            state: STATE_SEALED,
            opener: address(0),
            sequence: 0,
            openingStartedAt: 0,
            faceUsd: faceUsd,
            oddsVersion: ver,
            mintEvUsd: ev,
            owedUsd: 0
        });
        unchecked {
            ++sealedSupply[skuId];
        }
        _safeMint(to, tokenId);
        emit BoxPurchased(msg.sender, to, tokenId, skuId, token, price, fee, toVault);
    }

    function _requestEntropy(uint256 tokenId, BoxView storage b) internal {
        // H-04: do not request Entropy (and later silently burn) if this Box cannot settle.
        if (IPrizeVault(vault).box() != address(this)) revert VaultNotWired();

        uint32 gasLimit = callbackGasLimit;
        // The provider is named explicitly and remembered: {retryOpen} must ask Entropy about
        // THIS request, even if the default provider has changed since.
        address provider = IEntropyV2(entropy).getDefaultProvider();
        uint128 fee = IEntropyV2(entropy).getFeeV2(provider, gasLimit);
        if (msg.value < fee) revert Underpaid(msg.value, fee);

        uint64 sequence = IEntropyV2(entropy).requestV2{value: fee}(provider, gasLimit);
        _providerOf[tokenId] = provider;
        b.state = STATE_OPENING;
        b.opener = msg.sender;
        b.sequence = sequence;
        b.openingStartedAt = uint64(block.timestamp);
        _tokenIdOfRequest[_requestKey(provider, sequence)] = tokenId;

        uint256 excess = msg.value - fee;
        if (excess != 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            if (!ok) revert RefundFailed();
        }

        emit BoxOpeningRequested(msg.sender, tokenId, sequence, b.skuId, fee);
    }

    function _requestKey(address provider, uint64 sequence) internal pure returns (bytes32) {
        return keccak256(abi.encode(provider, sequence));
    }

    function _fulfill(uint64 sequence, address provider, bytes32 randomNumber) internal {
        bytes32 key = _requestKey(provider, sequence);
        uint256 tokenId = _tokenIdOfRequest[key];
        if (tokenId == 0) {
            emit OrphanCallback(sequence, provider);
            return;
        }
        BoxView memory b = _info[tokenId];
        if (b.state != STATE_OPENING || b.sequence != sequence || _providerOf[tokenId] != provider) {
            emit OrphanCallback(sequence, provider);
            return;
        }

        // H-05: mint snapshot, not live SKU price or live odds table.
        (uint8 tierId,, uint32 prizeBps, uint256 prizeUsd) = _drawAt(randomNumber, b.faceUsd, b.oddsVersion);

        IPrizeVault.Payout memory payout;
        try IPrizeVault(vault).settle(b.opener, prizeUsd, randomNumber) returns (
            IPrizeVault.Payout memory paid
        ) {
            payout = paid;
        } catch {}

        delete _tokenIdOfRequest[key];
        outstandingLiabilityUsd -= b.mintEvUsd;

        if (!payout.paid) {
            // Never paid short, never re-rolled, never silently burned (H-04): the drawn
            // prize is now owed at exactly this size and counts in full toward liability.
            BoxView storage s = _info[tokenId];
            s.state = STATE_OWED;
            s.owedUsd = prizeUsd;
            outstandingLiabilityUsd += prizeUsd;
            emit PrizeOwed(b.opener, tokenId, tierId, prizeUsd, payout.capped);
            return;
        }

        _retire(tokenId, b.skuId);
        _emitOpened(b.opener, tokenId, sequence, b.skuId, tierId, prizeBps, prizeUsd, payout);
    }

    function _retire(uint256 tokenId, uint8 skuId) internal {
        delete _info[tokenId];
        delete _providerOf[tokenId];
        if (sealedSupply[skuId] != 0) {
            unchecked {
                --sealedSupply[skuId];
            }
        }
        _burn(tokenId);
    }

    function _emitOpened(
        address opener,
        uint256 tokenId,
        uint64 sequence,
        uint8 skuId,
        uint8 tierId,
        uint32 prizeBps,
        uint256 prizeUsd,
        IPrizeVault.Payout memory payout
    ) internal {
        emit BoxOpened(
            opener,
            tokenId,
            sequence,
            skuId,
            tierId,
            prizeBps,
            prizeUsd,
            payout.stock,
            payout.stockAmount,
            payout.usdcAmount,
            payout.fallbackStock,
            payout.usdcFallback
        );
    }

    /// @dev Published mapping: `roll = uint256(randomNumber) % 10_000`, then the first
    ///      tier whose cumulative weight exceeds `roll`. The UI must use this exact rule.
    function _drawAt(bytes32 randomNumber, uint256 usdcPrice, uint64 version)
        internal
        view
        returns (uint8 tierId, uint16 weight, uint32 prizeBps, uint256 prizeUsd)
    {
        OddsSnapshot storage snap = _oddsSnapshots[version];
        uint256 roll = uint256(randomNumber) % WEIGHT_DENOM;
        uint256 acc;
        uint256 n = snap.count;
        for (uint256 i; i < n; ++i) {
            PrizeTier memory t = snap.tiers[i];
            acc += t.weight;
            if (roll < acc) {
                prizeUsd = usdcPrice * t.prizeBps / WEIGHT_DENOM;
                return (uint8(i), t.weight, t.prizeBps, prizeUsd);
            }
        }
        PrizeTier memory last = snap.tiers[n - 1];
        prizeUsd = usdcPrice * last.prizeBps / WEIGHT_DENOM;
        return (uint8(n - 1), last.weight, last.prizeBps, prizeUsd);
    }

    function _maxTierBpsAt(uint64 version) internal view returns (uint32 top) {
        OddsSnapshot storage snap = _oddsSnapshots[version];
        uint256 n = snap.count;
        for (uint256 i; i < n; ++i) {
            if (snap.tiers[i].prizeBps > top) top = snap.tiers[i].prizeBps;
        }
    }

    function _rtpBpsAt(uint64 version) internal view returns (uint256 acc) {
        OddsSnapshot storage snap = _oddsSnapshots[version];
        uint256 n = snap.count;
        for (uint256 i; i < n; ++i) {
            acc += uint256(snap.tiers[i].weight) * snap.tiers[i].prizeBps;
        }
        acc /= WEIGHT_DENOM;
    }

    function _loadLaunchOdds() internal {
        // weight, prizeBps. EV = sum(w * prizeBps) / 10_000 = 9_100 bps = 91.00% RTP.
        OddsSnapshot storage s = _oddsSnapshots[0];
        s.tiers[0] = PrizeTier({weight: 4_500, prizeBps: 2_000}); // 45% → 0.20×
        s.tiers[1] = PrizeTier({weight: 3_000, prizeBps: 5_000}); // 30% → 0.50×
        s.tiers[2] = PrizeTier({weight: 1_500, prizeBps: 10_000}); // 15% → 1.00×
        s.tiers[3] = PrizeTier({weight: 700, prizeBps: 20_000}); //  7% → 2.00×
        s.tiers[4] = PrizeTier({weight: 250, prizeBps: 80_000}); // 2.5% → 8.00×
        s.tiers[5] = PrizeTier({weight: 50, prizeBps: 360_000}); // 0.5% → 36.00×
        s.count = 6;
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        // Opening and owed boxes are bound to the opener, who is who the prize is paid to.
        uint8 st = _info[tokenId].state;
        if (from != address(0) && to != address(0) && (st == STATE_OPENING || st == STATE_OWED)) {
            revert BoxLocked(tokenId);
        }
        return super._update(to, tokenId, auth);
    }

    function _requireInWindow(uint64 executableAt) internal view {
        if (block.timestamp < executableAt) revert TimelockNotElapsed(uint64(block.timestamp), executableAt);
        uint64 expiresAt = executableAt + CONFIG_GRACE;
        if (block.timestamp > expiresAt) revert TimelockExpired(uint64(block.timestamp), expiresAt);
    }
}
