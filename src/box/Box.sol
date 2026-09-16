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
///      FEE SPLIT IS STRUCTURAL. 5% (`FEE_BPS`) of every payment is forwarded to
///      {treasury} (a Safe, once the address is known) and 95% to {vault} in the same
///      token, in the same transaction. The Box holds no USDC or $CHIP between calls.
///      {treasury} is constructor-set and retargeted only through a 48h timelock.
///
///      RTP IS THE TABLE. {oddsTable} is the only source of prize weights. The UI MUST
///      render that table and {previewDraw}, not a parallel copy. Constructor table is
///      91.00% EV of face price; 5% is the treasury cut; ~4% is vault buffer against
///      empty stock, cap and price move. Changing the table is timelocked.
///
///      RANDOMNESS IS PYTH ENTROPY V2. {open} is payable. It reads {getFeeV2} for the
///      configured callback gas limit, forwards that fee, and refunds any excess ETH.
///      The Entropy contract later calls {_entropyCallback}. That callback must not
///      revert: a failing {IPrizeVault.settle} is recorded as a shortfall and the box
///      is still burned. Basescan sees {BoxOpeningRequested} then {BoxOpened}.
///
///      $CHIP AND THE SAFE. Both addresses are constructor arguments with TODOs until
///      launch config is known. `chip == address(0)` or a SKU `chipPrice == 0` disables
///      the CHIP path without affecting USDC.
contract Box is IBox, ERC721, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    uint16 public constant override FEE_BPS = 500;
    uint16 public constant override WEIGHT_DENOM = 10_000;
    uint8 public constant MAX_SKUS = 4;
    uint8 public constant MAX_TIERS = 8;
    uint8 public constant STATE_SEALED = 1;
    uint8 public constant STATE_OPENING = 2;
    uint256 public constant MAX_BATCH = 20;
    uint64 public constant CONFIG_TIMELOCK = 48 hours;
    uint64 public constant CONFIG_GRACE = 14 days;
    uint64 public constant REVEAL_TIMEOUT = 3 days;
    uint32 public constant MIN_CALLBACK_GAS = 100_000;
    uint32 public constant MAX_CALLBACK_GAS = 2_000_000;

    uint8 public constant SKU_ONE_USD = 0;
    uint8 public constant SKU_FIVE_USD = 1;
    uint8 public constant SKU_TEN_USD = 2;
    uint8 public constant SKU_TWENTY_FIVE_USD = 3;

    address public immutable override usdc;
    address public immutable override chip;
    address public immutable override vault;
    address public immutable override entropy;

    address public override treasury;
    uint32 public override callbackGasLimit = 500_000;
    bool public paused;
    string public baseURI;
    uint256 public nextId = 1;

    mapping(uint8 => Sku) internal _skus;
    mapping(uint8 => uint256) public override sealedSupply;
    mapping(uint256 => BoxView) internal _info;
    mapping(uint64 => uint256) internal _tokenIdOfSequence;

    PrizeTier[MAX_TIERS] internal _tiers;
    uint8 internal _tierCount;

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
        uint256 paidUsd,
        bool capped,
        bool shortfall,
        bool emptyStockFallback
    );
    event OrphanCallback(uint64 indexed sequence, address indexed provider);
    event PausedSet(bool paused);
    event SkuPaused(uint8 indexed skuId, bool paused);
    event TreasuryQueued(address indexed treasury, uint64 executableAt);
    event TreasurySet(address indexed previous, address indexed current);
    event TreasuryCancelled();
    event SkuQueued(uint8 indexed skuId, uint96 usdcPrice, uint128 chipPrice, uint64 executableAt);
    event SkuExecuted(uint8 indexed skuId, uint96 usdcPrice, uint128 chipPrice);
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
    error RevealNotTimedOut(uint64 nowTs, uint64 readyAt);
    error BoxLocked(uint256 tokenId);
    error Underpaid(uint256 sent, uint256 required);
    error RefundFailed();
    error OnlyEntropy();
    error BatchTooLarge(uint256 n);
    error NothingQueued();
    error TimelockNotElapsed(uint64 nowTs, uint64 executableAt);
    error TimelockExpired(uint64 nowTs, uint64 expiredAt);

    /// @param multisig       Owner. Two-step.
    /// @param usdc_          USDC on Base. 6 decimals.
    /// @param chip_          $CHIP token. TODO: pass the live address at deploy; `address(0)`
    ///                       disables {buyWithChip} until a new deployment.
    /// @param treasury_      5% recipient. TODO: Chipworks Safe once known; a placeholder is
    ///                       fine in tests. Retarget is 48h-timelocked.
    /// @param vault_         PrizeVault. 95% of payment and all B20 payouts.
    /// @param entropy_       Pyth Entropy v2. Base: 0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb.
    /// @param chipPrice1     $CHIP charged for the $1 SKU. 0 disables CHIP on that SKU.
    /// @param chipPrice5     $CHIP charged for the $5 SKU. 0 disables CHIP on that SKU.
    constructor(
        address multisig,
        address usdc_,
        address chip_,
        address treasury_,
        address vault_,
        address entropy_,
        uint128 chipPrice1,
        uint128 chipPrice5
    ) ERC721("ChipWorks Box", "CBOX") Ownable(multisig) {
        if (multisig == address(0) || usdc_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        if (vault_ == address(0) || entropy_ == address(0)) revert ZeroAddress();
        usdc = usdc_;
        chip = chip_;
        treasury = treasury_;
        vault = vault_;
        entropy = entropy_;

        _skus[SKU_ONE_USD] = Sku({exists: true, paused: false, usdcPrice: 1_000_000, chipPrice: chipPrice1});
        _skus[SKU_FIVE_USD] = Sku({exists: true, paused: false, usdcPrice: 5_000_000, chipPrice: chipPrice5});
        // $10 / $25 slots exist as ids 2 and 3 but start `exists = false`. Enable via {queueSku}.

        _loadLaunchOdds();
        emit TreasurySet(address(0), treasury_);
        emit SkuExecuted(SKU_ONE_USD, 1_000_000, chipPrice1);
        emit SkuExecuted(SKU_FIVE_USD, 5_000_000, chipPrice5);
        emit OddsExecuted(_tierCount, rtpBps());
    }

    /* ------------------------------------------------------------------ */
    /*                               BUY                                    */
    /* ------------------------------------------------------------------ */

    function buyWithUsdc(uint8 skuId, address to) external override nonReentrant returns (uint256 tokenId) {
        tokenId = _buy(skuId, to, usdc, _liveSku(skuId).usdcPrice);
    }

    function buyWithChip(uint8 skuId, address to) external override nonReentrant returns (uint256 tokenId) {
        if (chip == address(0)) revert ChipDisabled();
        uint128 price = _liveSku(skuId).chipPrice;
        if (price == 0) revert ChipDisabled();
        tokenId = _buy(skuId, to, chip, price);
    }

    function buyWithUsdcBatch(uint8 skuId, address to, uint256 n)
        external
        override
        nonReentrant
        returns (uint256 firstId)
    {
        if (n == 0 || n > MAX_BATCH) revert BatchTooLarge(n);
        Sku memory s = _liveSku(skuId);
        firstId = nextId;
        for (uint256 i; i < n; ++i) {
            _buy(skuId, to, usdc, s.usdcPrice);
        }
    }

    function buyWithChipBatch(uint8 skuId, address to, uint256 n)
        external
        override
        nonReentrant
        returns (uint256 firstId)
    {
        if (chip == address(0)) revert ChipDisabled();
        if (n == 0 || n > MAX_BATCH) revert BatchTooLarge(n);
        Sku memory s = _liveSku(skuId);
        if (s.chipPrice == 0) revert ChipDisabled();
        firstId = nextId;
        for (uint256 i; i < n; ++i) {
            _buy(skuId, to, chip, s.chipPrice);
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

    /// @notice Re-request entropy if the original callback has not arrived after {REVEAL_TIMEOUT}.
    function retryOpen(uint256 tokenId) external payable override nonReentrant {
        if (paused) revert PausedError();
        BoxView storage b = _info[tokenId];
        if (b.state != STATE_OPENING) revert NotOpening(tokenId);
        if (b.opener != msg.sender) revert NotOwner();
        uint64 readyAt = b.openingStartedAt + REVEAL_TIMEOUT;
        if (block.timestamp < readyAt) revert RevealNotTimedOut(uint64(block.timestamp), readyAt);
        delete _tokenIdOfSequence[b.sequence];
        _requestEntropy(tokenId, b);
    }

    /// @notice Pyth Entropy v2 callback. ABI-compatible with IEntropyConsumer._entropyCallback.
    /// @dev Never reverts on a failed payout. A revert here would stall the keeper.
    function _entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) external {
        if (msg.sender != entropy) revert OnlyEntropy();
        _fulfill(sequence, provider, randomNumber);
    }

    /* ------------------------------------------------------------------ */
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    function sku(uint8 id) public view override returns (Sku memory) {
        return _skus[id];
    }

    function oddsTierCount() public view override returns (uint256) {
        return _tierCount;
    }

    function oddsTable() public view override returns (PrizeTier[] memory tiers) {
        uint256 n = _tierCount;
        tiers = new PrizeTier[](n);
        for (uint256 i; i < n; ++i) {
            tiers[i] = _tiers[i];
        }
    }

    /// @notice Player RTP of the published table, in bps. Launch table is 9100 (91.00%).
    function rtpBps() public view override returns (uint256 acc) {
        uint256 n = _tierCount;
        for (uint256 i; i < n; ++i) {
            acc += uint256(_tiers[i].weight) * _tiers[i].prizeBps;
        }
        acc /= WEIGHT_DENOM;
    }

    function expectedValueUsd(uint8 skuId) public view override returns (uint256) {
        Sku memory s = _skus[skuId];
        if (!s.exists) revert UnknownSku(skuId);
        return uint256(s.usdcPrice) * rtpBps() / WEIGHT_DENOM;
    }

    function outstandingLiabilityUsd() public view override returns (uint256 usd) {
        for (uint8 i; i < MAX_SKUS; ++i) {
            uint256 n = sealedSupply[i];
            if (n == 0) continue;
            usd += n * expectedValueUsd(i);
        }
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
        (tierId, weight, prizeBps, prizeUsd) = _draw(randomNumber, s.usdcPrice);
    }

    function boxInfo(uint256 tokenId) external view override returns (BoxView memory) {
        return _info[tokenId];
    }

    function tokenIdOfSequence(uint64 sequence) external view override returns (uint256) {
        return _tokenIdOfSequence[sequence];
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

    /// @notice Queue a SKU price (and whether it exists). Use this to turn on $10 / $25.
    function queueSku(uint8 id, bool exists, uint96 usdcPrice, uint128 chipPrice) external onlyOwner {
        if (id >= MAX_SKUS) revert UnknownSku(id);
        if (exists && usdcPrice == 0) revert BadConfig();
        uint64 executableAt = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingSku = PendingSku({
            queued: true,
            executableAt: executableAt,
            id: id,
            sku: Sku({exists: exists, paused: _skus[id].paused, usdcPrice: usdcPrice, chipPrice: chipPrice})
        });
        emit SkuQueued(id, usdcPrice, chipPrice, executableAt);
    }

    function executeSku() external onlyOwner {
        PendingSku memory p = _pendingSku;
        if (!p.queued) revert NothingQueued();
        _requireInWindow(p.executableAt);
        _skus[p.id] = p.sku;
        emit SkuExecuted(p.id, p.sku.usdcPrice, p.sku.chipPrice);
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
        _tierCount = q.count;
        for (uint256 i; i < q.count; ++i) {
            _tiers[i] = q.tiers[i];
        }
        delete _pendingOdds;
        emit OddsExecuted(_tierCount, rtpBps());
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

    function _buy(uint8 skuId, address to, address token, uint256 price) internal returns (uint256 tokenId) {
        if (to == address(0)) revert ZeroAddress();
        if (price == 0) revert BadConfig();

        uint256 fee = price * FEE_BPS / WEIGHT_DENOM;
        uint256 toVault = price - fee;
        IERC20(token).safeTransferFrom(msg.sender, address(this), price);
        IERC20(token).safeTransfer(treasury, fee);
        IERC20(token).safeTransfer(vault, toVault);

        tokenId = nextId++;
        _info[tokenId] =
            BoxView({skuId: skuId, state: STATE_SEALED, opener: address(0), sequence: 0, openingStartedAt: 0});
        unchecked {
            ++sealedSupply[skuId];
        }
        _safeMint(to, tokenId);
        emit BoxPurchased(msg.sender, to, tokenId, skuId, token, price, fee, toVault);
    }

    function _requestEntropy(uint256 tokenId, BoxView storage b) internal {
        uint32 gasLimit = callbackGasLimit;
        uint128 fee = IEntropyV2(entropy).getFeeV2(gasLimit);
        if (msg.value < fee) revert Underpaid(msg.value, fee);

        uint64 sequence = IEntropyV2(entropy).requestV2{value: fee}(gasLimit);
        b.state = STATE_OPENING;
        b.opener = msg.sender;
        b.sequence = sequence;
        b.openingStartedAt = uint64(block.timestamp);
        _tokenIdOfSequence[sequence] = tokenId;

        uint256 excess = msg.value - fee;
        if (excess != 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            if (!ok) revert RefundFailed();
        }

        emit BoxOpeningRequested(msg.sender, tokenId, sequence, b.skuId, fee);
    }

    function _fulfill(uint64 sequence, address provider, bytes32 randomNumber) internal {
        uint256 tokenId = _tokenIdOfSequence[sequence];
        if (tokenId == 0) {
            emit OrphanCallback(sequence, provider);
            return;
        }
        BoxView memory b = _info[tokenId];
        if (b.state != STATE_OPENING || b.sequence != sequence) {
            emit OrphanCallback(sequence, provider);
            return;
        }

        address opener = b.opener;
        uint8 skuId = b.skuId;
        uint96 price = _skus[skuId].usdcPrice;
        (uint8 tierId,, uint32 prizeBps, uint256 prizeUsd) = _draw(randomNumber, price);

        IPrizeVault.Payout memory payout;
        try IPrizeVault(vault).settle(opener, prizeUsd, randomNumber) returns (IPrizeVault.Payout memory paid) {
            payout = paid;
        } catch {
            payout.requestedUsd = prizeUsd;
            payout.shortfall = true;
        }

        delete _tokenIdOfSequence[sequence];
        delete _info[tokenId];
        if (sealedSupply[skuId] != 0) {
            unchecked {
                --sealedSupply[skuId];
            }
        }
        _burn(tokenId);
        _emitOpened(opener, tokenId, sequence, skuId, tierId, prizeBps, prizeUsd, payout);
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
            payout.paidUsd,
            payout.capped,
            payout.shortfall,
            payout.fallbackStock
        );
    }

    /// @dev Published mapping: `roll = uint256(randomNumber) % 10_000`, then the first
    ///      tier whose cumulative weight exceeds `roll`. The UI must use this exact rule.
    function _draw(bytes32 randomNumber, uint256 usdcPrice)
        internal
        view
        returns (uint8 tierId, uint16 weight, uint32 prizeBps, uint256 prizeUsd)
    {
        uint256 roll = uint256(randomNumber) % WEIGHT_DENOM;
        uint256 acc;
        uint256 n = _tierCount;
        for (uint256 i; i < n; ++i) {
            PrizeTier memory t = _tiers[i];
            acc += t.weight;
            if (roll < acc) {
                prizeUsd = usdcPrice * t.prizeBps / WEIGHT_DENOM;
                return (uint8(i), t.weight, t.prizeBps, prizeUsd);
            }
        }
        PrizeTier memory last = _tiers[n - 1];
        prizeUsd = usdcPrice * last.prizeBps / WEIGHT_DENOM;
        return (uint8(n - 1), last.weight, last.prizeBps, prizeUsd);
    }

    function _loadLaunchOdds() internal {
        // weight, prizeBps. EV = sum(w * prizeBps) / 10_000 = 9_100 bps = 91.00% RTP.
        _tiers[0] = PrizeTier({weight: 4_500, prizeBps: 2_000}); // 45% → 0.20×
        _tiers[1] = PrizeTier({weight: 3_000, prizeBps: 5_000}); // 30% → 0.50×
        _tiers[2] = PrizeTier({weight: 1_500, prizeBps: 10_000}); // 15% → 1.00×
        _tiers[3] = PrizeTier({weight: 700, prizeBps: 20_000}); //  7% → 2.00×
        _tiers[4] = PrizeTier({weight: 250, prizeBps: 80_000}); // 2.5% → 8.00×
        _tiers[5] = PrizeTier({weight: 50, prizeBps: 360_000}); // 0.5% → 36.00×
        _tierCount = 6;
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && _info[tokenId].state == STATE_OPENING) {
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
