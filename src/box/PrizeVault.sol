// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBox} from "../interfaces/IBox.sol";
import {IChipConverter} from "../interfaces/IChipConverter.sol";
import {IPrizeVault} from "../interfaces/IPrizeVault.sol";
import {IStockRegistry, Stock, Venue} from "../interfaces/IStockRegistry.sol";
import {ISlipstreamSwapRouter, IUniswapV3SwapRouter} from "../interfaces/ISwapRouters.sol";

/// @title PrizeVault
/// @notice The Box prize pool: USDC plus Coinbase B20 stocks. Box revenue accumulates here,
///         winners are paid from it, and the keeper keeps it stocked from that revenue.
///
/// @dev UNAUDITED. Shares no storage, inheritance or call path with Anvil, ChipRounds,
///      ChipClaims or the Pot; it only READS the StockRegistry and swaps through the same two
///      routers ChipRounds uses.
///
///      NEVER PAID SHORT. {settle} is all-or-nothing. A prize larger than {prizeCapUsd}
///      (`maxPrizeBps` of inventory, 25% at launch) or one nothing here can cover moves
///      NOTHING and returns `paid == false`; the Box then records it as owed at its exact
///      size and anyone can {IBox.claimOwed} it once the pool has grown. The Box also stops
///      selling a SKU whose top prize the pool could not pay ({IBox.isSkuCovered}).
///
///      CHIP IS NEVER INVENTORY (H-01). {addStock} refuses it and {settle} never pays it. The
///      vault never takes $CHIP in: box $CHIP goes to the ChipConverter, and a CHIP-tier prize
///      leaves here as USDC escrowed on the converter for that winner. A stray $CHIP transfer
///      is an ordinary stray token and {rescue} can return it.
///
///      PRICES ARE THE REGISTRY'S. Stock marks come from {IStockRegistry.priceUsd} — the same
///      Chainlink feeds ChipRounds buys against — not from feeds this contract's owner sets.
///      A stale mark (older than {maxFeedAge}) is skipped everywhere: not counted in
///      inventory, not paid out, not bought.
///
///      AUTOMATIC RESTOCK. {restock} lets the KEEPER swap vault USDC into a registered stock,
///      output straight back into the vault, with the minimum out set by the Chainlink mark
///      less {restockSlippageBps} (exactly ChipRounds' `_buy` bound), per-call and per-day
///      caps, and a USDC share ({minUsdcBps}) it may not spend below — CHIP-tier prizes and
///      the USDC fallback are paid in USDC. The keeper cannot withdraw anything.
///
///      HOUSE TAKE -> FEE RECIPIENT. {sweepSurplus} is permissionless and pays only the Box's
///      fee recipient (the FeeSplitter at launch: 80% Pot / 20% ops). It sends only USDC that
///      clears ALL THREE floors: USDC >= 110% of outstanding liability; inventory >= the size
///      needed to pay the largest prize on sale in full ({jackpotReserveUsd}); and USDC >=
///      {minUsdcBps} of what remains (the share CHIP-tier prizes and the fallback draw on).
contract PrizeVault is IPrizeVault, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint32 public constant BPS = 10_000;
    uint256 public constant MAX_STOCKS = 16;
    uint64 public constant CONFIG_TIMELOCK = 48 hours;
    uint64 public constant CONFIG_GRACE = 14 days;
    uint32 public constant MAX_PRIZE_BPS_CEILING = 5_000;
    uint32 public constant SURPLUS_BUFFER_BPS = 11_000;
    uint32 public constant MAX_RESTOCK_SLIPPAGE_BPS = 500;
    /// @notice The kept USDC share must leave room for stock, or restock could never run.
    uint32 public constant MAX_MIN_USDC_BPS = 9_000;
    /// @notice Floor on {maxFeedAge}. B20 feeds hold the last close over a weekend.
    uint64 public constant MIN_FEED_AGE = 1 hours;

    /// @notice $CHIP on Base. Refused as stock even if a constructor was passed another CHIP.
    address public constant DEFAULT_CHIP = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;

    address public immutable override usdc;
    address public immutable override chip;
    uint8 public immutable usdcDecimals;
    IStockRegistry public immutable registry;
    IUniswapV3SwapRouter public immutable uniswapRouter;
    ISlipstreamSwapRouter public immutable slipstreamRouter;

    address public override box;
    address public keeper;
    uint32 public override maxPrizeBps;
    uint64 public maxFeedAge = 5 days;

    uint256 public maxRestockPerCall;
    uint256 public maxRestockPerDay;
    uint32 public restockSlippageBps = 200;
    uint32 public minUsdcBps = 5_000;
    mapping(uint256 day => uint256) public restockedOnDay;

    struct PrizeStock {
        bool registered;
        bool enabled;
        uint8 tokenDecimals;
    }

    mapping(address token => PrizeStock) internal _stocks;
    address[] internal _stockList;

    struct PendingBps {
        bool queued;
        uint64 executableAt;
        uint32 bps;
    }

    struct PendingSurplus {
        bool queued;
        uint64 executableAt;
        address token;
        address to;
        uint256 amount;
    }

    PendingBps internal _pendingMaxPrizeBps;
    PendingSurplus internal _pendingSurplus;

    event BoxSet(address indexed box);
    event KeeperSet(address indexed keeper);
    event RestockParamsSet(uint256 perCall, uint256 perDay, uint32 slippageBps, uint32 minUsdcBps);
    event MaxFeedAgeSet(uint64 maxFeedAge);
    event StockAdded(address indexed token, uint8 tokenDecimals);
    event StockEnabled(address indexed token, bool enabled);
    event MaxPrizeBpsQueued(uint32 bps, uint64 executableAt);
    event MaxPrizeBpsExecuted(uint32 previous, uint32 bps);
    event MaxPrizeBpsCancelled();
    event SurplusQueued(address indexed token, address indexed to, uint256 amount, uint64 executableAt);
    event SurplusWithdrawn(address indexed token, address indexed to, uint256 amount);
    event SurplusCancelled();
    event SurplusSwept(address indexed to, uint256 usdcAmount);
    event Restocked(address indexed stock, uint256 usdcIn, uint256 stockOut, uint256 minOut);
    event Deposited(address indexed token, address indexed from, uint256 amount);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event StockSkipped(address indexed token, bytes32 indexed reason);
    event PrizePaid(
        address indexed to,
        uint256 requestedUsd,
        uint256 paidUsd,
        address indexed stock,
        uint256 stockAmount,
        uint256 usdcAmount,
        uint256 chipPrizeId,
        bool fallbackStock,
        bool usdcFallback
    );
    event PrizeNotPaid(address indexed to, uint256 requestedUsd, uint256 capUsd, bool capped);

    error ZeroAddress();
    error BadConfig();
    error AlreadyWired();
    error OnlyBox();
    error NotKeeper(address caller);
    error AlreadyRegistered(address token);
    error NotRegistered(address token);
    error TooManyStocks();
    error ProtectedAsset(address token);
    error InsufficientSurplus(uint256 leftUsd, uint256 requiredUsd);
    error BoxUnset();
    error NothingQueued();
    error NothingToSweep();
    error TimelockNotElapsed(uint64 nowTs, uint64 executableAt);
    error TimelockExpired(uint64 nowTs, uint64 expiredAt);
    error OverCap(uint256 amount, uint256 cap);
    error OverDailyCap(uint256 wouldBe, uint256 cap);
    error StockNotBuyable(address token, bytes32 reason);
    error UsdcShareTooLow(uint256 usdcUsd, uint256 requiredUsd);
    error RestockShort(uint256 got, uint256 minOut);

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper(msg.sender);
        _;
    }

    /// @param multisig          Owner. Two-step.
    /// @param usdc_             USDC on Base (6 dp). Must be the registry's quote token.
    /// @param chip_             $CHIP. Only ever used to REFUSE it as stock.
    /// @param registry_         Live StockRegistry (the source of stock pools, venues and marks).
    /// @param uniswapRouter_    Uniswap v3 SwapRouter02, for `Venue.UniswapV3` stocks.
    /// @param slipstreamRouter_ The factory-B Slipstream router, for `Venue.Slipstream` stocks.
    /// @param maxPrizeBps_      Largest single prize vs inventory. Launch at 2_500 (25%).
    constructor(
        address multisig,
        address usdc_,
        address chip_,
        address registry_,
        address uniswapRouter_,
        address slipstreamRouter_,
        uint32 maxPrizeBps_
    ) Ownable(multisig) {
        if (
            multisig == address(0) || usdc_ == address(0) || registry_ == address(0)
                || uniswapRouter_ == address(0) || slipstreamRouter_ == address(0)
        ) revert ZeroAddress();
        if (maxPrizeBps_ == 0 || maxPrizeBps_ > MAX_PRIZE_BPS_CEILING) revert BadConfig();
        if (chip_ == usdc_) revert BadConfig();
        if (IStockRegistry(registry_).quoteToken() != usdc_) revert BadConfig();
        usdc = usdc_;
        chip = chip_;
        usdcDecimals = IERC20Metadata(usdc_).decimals();
        registry = IStockRegistry(registry_);
        uniswapRouter = IUniswapV3SwapRouter(uniswapRouter_);
        slipstreamRouter = ISlipstreamSwapRouter(slipstreamRouter_);
        maxPrizeBps = maxPrizeBps_;
    }

    /* ------------------------------------------------------------------ */
    /*                              WIRING                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Point at the Box. Allowed ONCE, while unset. A new Box is a new vault:
    ///         retargeting the settler would be a drain.
    function setBox(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        if (box != address(0)) revert AlreadyWired();
        if (IBox(v).usdc() != usdc || IBox(v).chip() != chip || IBox(v).vault() != address(this)) {
            revert BadConfig();
        }
        box = v;
        emit BoxSet(v);
    }

    /// @notice Immediate. The keeper can only restock within the caps, never withdraw.
    function setKeeper(address v) external onlyOwner {
        keeper = v;
        emit KeeperSet(v);
    }

    function setRestockParams(uint256 perCall, uint256 perDay, uint32 slippageBps, uint32 minUsdcBps_)
        external
        onlyOwner
    {
        if (slippageBps > MAX_RESTOCK_SLIPPAGE_BPS || minUsdcBps_ > MAX_MIN_USDC_BPS) revert BadConfig();
        maxRestockPerCall = perCall;
        maxRestockPerDay = perDay;
        restockSlippageBps = slippageBps;
        minUsdcBps = minUsdcBps_;
        emit RestockParamsSet(perCall, perDay, slippageBps, minUsdcBps_);
    }

    function setMaxFeedAge(uint64 v) external onlyOwner {
        if (v < MIN_FEED_AGE) revert BadConfig();
        maxFeedAge = v;
        emit MaxFeedAgeSet(v);
    }

    /* ------------------------------------------------------------------ */
    /*                             DEPOSITS                                 */
    /* ------------------------------------------------------------------ */

    /// @notice Permissionless top-up in USDC or a registered stock. Never $CHIP.
    function deposit(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert BadConfig();
        if (token != usdc && !_stocks[token].registered) revert NotRegistered(token);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(token, msg.sender, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                               SETTLE                                 */
    /* ------------------------------------------------------------------ */

    /// @inheritdoc IPrizeVault
    /// @dev Called from inside the Pyth callback via Box, so it must not revert on a bad
    ///      stock or a thin pool — it skips. It returns `paid == false` (nothing moved)
    ///      rather than ever paying part of a prize.
    function settle(address to, uint256 prizeUsd, bytes32 entropy, bool payInChip)
        external
        override
        nonReentrant
        returns (Payout memory p)
    {
        if (msg.sender != box) revert OnlyBox();
        p.requestedUsd = prizeUsd;
        if (prizeUsd == 0) {
            p.paid = true;
            return p;
        }
        uint256 cap = _prizeCapUsd();
        if (prizeUsd > cap) {
            p.capped = true;
            emit PrizeNotPaid(to, prizeUsd, cap, true);
            return p;
        }

        if (payInChip && _payInChip(to, prizeUsd, p)) {
            _emitPaid(to, p);
            return p;
        }
        if (_payInStock(to, prizeUsd, entropy, p)) {
            p.fallbackStock = p.fallbackStock || payInChip;
            _emitPaid(to, p);
            return p;
        }
        if (_payInUsdc(to, prizeUsd, p)) {
            _emitPaid(to, p);
            return p;
        }
        emit PrizeNotPaid(to, prizeUsd, cap, false);
    }

    function _payInChip(address to, uint256 prizeUsd, Payout memory p) internal returns (bool) {
        address conv = IBox(box).converter();
        if (conv == address(0)) return false;
        uint256 amount = _usdToUsdc(prizeUsd);
        if (IERC20(usdc).balanceOf(address(this)) < amount) return false;
        // Transfer + queue as ONE external call so a failed queue unwinds the transfer.
        try this.extQueueChipPrize(conv, to, amount) returns (uint256 id) {
            p.paid = true;
            p.chipPrizeId = id;
            p.usdcAmount = amount;
            p.paidUsd = prizeUsd;
            return true;
        } catch {
            emit StockSkipped(chip, bytes32("chip-queue"));
            return false;
        }
    }

    /// @notice Self-call only. Escrows a CHIP-tier prize on the converter atomically.
    function extQueueChipPrize(address conv, address to, uint256 amount) external returns (uint256) {
        if (msg.sender != address(this)) revert OnlyBox();
        IERC20(usdc).safeTransfer(conv, amount);
        return IChipConverter(conv).queueChipPrize(to, amount);
    }

    function _payInStock(address to, uint256 prizeUsd, bytes32 entropy, Payout memory p) internal returns (bool) {
        uint256 n = _stockList.length;
        if (n == 0) return false;
        uint256 start = uint256(entropy) % n;
        for (uint256 i; i < n; ++i) {
            address token = _stockList[_wrap(start + i, n)];
            (bool ok, uint256 amount) = _canPayStock(token, prizeUsd);
            if (!ok) continue;
            if (!_tryTransfer(token, to, amount)) {
                emit StockSkipped(token, bytes32("transfer"));
                continue;
            }
            p.paid = true;
            p.stock = token;
            p.stockAmount = amount;
            p.paidUsd = prizeUsd;
            p.fallbackStock = i != 0;
            return true;
        }
        return false;
    }

    function _payInUsdc(address to, uint256 prizeUsd, Payout memory p) internal returns (bool) {
        uint256 need = _usdToUsdc(prizeUsd);
        if (need == 0 || IERC20(usdc).balanceOf(address(this)) < need) return false;
        if (!_tryTransfer(usdc, to, need)) return false;
        p.paid = true;
        p.usdcAmount = need;
        p.paidUsd = prizeUsd;
        p.usdcFallback = true;
        return true;
    }

    function _emitPaid(address to, Payout memory p) internal {
        emit PrizePaid(
            to, p.requestedUsd, p.paidUsd, p.stock, p.stockAmount, p.usdcAmount, p.chipPrizeId, p.fallbackStock, p.usdcFallback
        );
    }

    /* ------------------------------------------------------------------ */
    /*                         KEEPER: RESTOCK                              */
    /* ------------------------------------------------------------------ */

    /// @notice Swap `usdcIn` of pool USDC into `stock`. The stock lands in this vault.
    /// @dev The bound is ChipRounds' own: Chainlink mark from the registry less
    ///      {restockSlippageBps}, a stale mark refused, and the venue the registry names.
    function restock(address stock, uint256 usdcIn) external nonReentrant onlyKeeper returns (uint256 got) {
        PrizeStock memory ps = _stocks[stock];
        if (!ps.registered || !ps.enabled) revert NotRegistered(stock);
        if (usdcIn == 0) revert BadConfig();
        if (usdcIn > maxRestockPerCall) revert OverCap(usdcIn, maxRestockPerCall);
        uint256 day = block.timestamp / 1 days;
        uint256 spent = restockedOnDay[day] + usdcIn;
        if (spent > maxRestockPerDay) revert OverDailyCap(spent, maxRestockPerDay);
        restockedOnDay[day] = spent;

        Stock memory s = registry.getStock(stock);
        if (!s.enabled) revert StockNotBuyable(stock, "registry-disabled");
        uint256 price = _freshPrice(stock);
        if (price == 0) revert StockNotBuyable(stock, "no-fresh-price");
        uint256 fair = Math.mulDiv(_usdcToUsd(usdcIn) * 1e12, 10 ** uint256(ps.tokenDecimals), price);
        uint256 minOut = fair * (BPS - restockSlippageBps) / BPS;
        if (minOut == 0) revert StockNotBuyable(stock, "dust");

        uint256 before = IERC20(stock).balanceOf(address(this));
        if (s.venue == Venue.Slipstream) {
            IERC20(usdc).forceApprove(address(slipstreamRouter), usdcIn);
            slipstreamRouter.exactInputSingle(
                ISlipstreamSwapRouter.ExactInputSingleParams({
                    tokenIn: usdc,
                    tokenOut: stock,
                    tickSpacing: s.tickSpacing,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: usdcIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
            IERC20(usdc).forceApprove(address(slipstreamRouter), 0);
        } else if (s.venue == Venue.UniswapV3) {
            IERC20(usdc).forceApprove(address(uniswapRouter), usdcIn);
            uniswapRouter.exactInputSingle(
                IUniswapV3SwapRouter.ExactInputSingleParams({
                    tokenIn: usdc,
                    tokenOut: stock,
                    fee: s.fee,
                    recipient: address(this),
                    amountIn: usdcIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
            IERC20(usdc).forceApprove(address(uniswapRouter), 0);
        } else {
            revert StockNotBuyable(stock, "no-venue");
        }
        got = IERC20(stock).balanceOf(address(this)) - before;
        if (got < minOut) revert RestockShort(got, minOut);

        // CHIP-tier prizes and the fallback pay USDC: keep a USDC share of the pool.
        uint256 usdcUsd = _usdcToUsd(IERC20(usdc).balanceOf(address(this)));
        uint256 required = inventoryUsd() * minUsdcBps / BPS;
        if (usdcUsd < required) revert UsdcShareTooLow(usdcUsd, required);

        emit Restocked(stock, usdcIn, got, minOut);
    }

    /* ------------------------------------------------------------------ */
    /*                   HOUSE TAKE: SURPLUS SWEEP                          */
    /* ------------------------------------------------------------------ */

    /// @notice Pool size needed to pay the largest prize on sale in full.
    function jackpotReserveUsd() public view returns (uint256) {
        address b = box;
        if (b == address(0)) revert BoxUnset();
        return Math.mulDiv(IBox(b).maxLivePrizeUsd(), BPS, maxPrizeBps, Math.Rounding.Ceil);
    }

    /// @notice USDC {sweepSurplus} would send right now. Fails closed to 0 on a bad read.
    function sweepableUsdc() public view returns (uint256) {
        address b = box;
        if (b == address(0)) return 0;
        uint256 liability;
        try IBox(b).outstandingLiabilityUsd() returns (uint256 l) {
            liability = l;
        } catch {
            return 0;
        }
        uint256 usdcUsd = _usdcToUsd(IERC20(usdc).balanceOf(address(this)));
        uint256 liabilityFloor = Math.mulDiv(liability, SURPLUS_BUFFER_BPS, BPS, Math.Rounding.Ceil);
        if (usdcUsd <= liabilityFloor) return 0;
        uint256 byLiability = usdcUsd - liabilityFloor;

        uint256 reserve;
        try this.jackpotReserveUsd() returns (uint256 r) {
            reserve = r;
        } catch {
            return 0;
        }
        uint256 inv = inventoryUsd();
        if (inv <= reserve) return 0;
        uint256 byReserve = inv - reserve;

        // Keep the same USDC share {restock} keeps: CHIP-tier prizes and the fallback pay
        // USDC. Solve usdc - x >= m * (inv - x) for x, with m = minUsdcBps / BPS < 1.
        uint256 m = minUsdcBps;
        if (usdcUsd * BPS <= m * inv) return 0;
        uint256 byShare = (usdcUsd * BPS - m * inv) / (BPS - m);

        uint256 x = byLiability < byReserve ? byLiability : byReserve;
        return _usdToUsdc(x < byShare ? x : byShare);
    }

    /// @notice Send the pool's surplus USDC to the Box's fee recipient. Permissionless: the
    ///         destination is fixed and the amount is whatever both floors leave spare.
    function sweepSurplus() external nonReentrant returns (uint256 amount) {
        amount = sweepableUsdc();
        if (amount == 0) revert NothingToSweep();
        address to = IBox(box).treasury();
        IERC20(usdc).safeTransfer(to, amount);
        emit SurplusSwept(to, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    /// @notice USDC plus every enabled stock with a fresh registry mark, in 6-dp USD.
    function inventoryUsd() public view override returns (uint256 usd) {
        usd = _usdcToUsd(IERC20(usdc).balanceOf(address(this)));
        uint256 n = _stockList.length;
        for (uint256 i; i < n; ++i) {
            address token = _stockList[i];
            PrizeStock memory st = _stocks[token];
            if (!st.enabled) continue;
            uint256 price = _freshPrice(token);
            if (price == 0) continue;
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal == 0) continue;
            usd += _tokensToUsd(bal, price, st.tokenDecimals);
        }
    }

    function prizeCapUsd() public view override returns (uint256) {
        return _prizeCapUsd();
    }

    function stockCount() external view override returns (uint256) {
        return _stockList.length;
    }

    function stockAt(uint256 index) external view override returns (address) {
        return _stockList[index];
    }

    function getStock(address token) external view returns (PrizeStock memory) {
        return _stocks[token];
    }

    /* ------------------------------------------------------------------ */
    /*                           ADMIN: STOCKS                              */
    /* ------------------------------------------------------------------ */

    /// @notice List a registry stock as a prize. Pool, venue, feed and decimals all come
    ///         from the registry; nothing here is owner-priced.
    function addStock(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (_isChip(token) || token == usdc) revert ProtectedAsset(token);
        if (_stocks[token].registered) revert AlreadyRegistered(token);
        if (_stockList.length >= MAX_STOCKS) revert TooManyStocks();
        Stock memory s = registry.getStock(token);
        if (!s.registered || s.tokenDecimals == 0 || s.tokenDecimals > 18) revert NotRegistered(token);
        _stocks[token] = PrizeStock({registered: true, enabled: true, tokenDecimals: s.tokenDecimals});
        _stockList.push(token);
        emit StockAdded(token, s.tokenDecimals);
    }

    function setStockEnabled(address token, bool enabled) external onlyOwner {
        if (!_stocks[token].registered) revert NotRegistered(token);
        _stocks[token].enabled = enabled;
        emit StockEnabled(token, enabled);
    }

    /* ------------------------------------------------------------------ */
    /*                        ADMIN: PRIZE CAP (48h)                        */
    /* ------------------------------------------------------------------ */

    function queueMaxPrizeBps(uint32 bps) external onlyOwner {
        if (bps == 0 || bps > MAX_PRIZE_BPS_CEILING) revert BadConfig();
        uint64 executableAt = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingMaxPrizeBps = PendingBps({queued: true, executableAt: executableAt, bps: bps});
        emit MaxPrizeBpsQueued(bps, executableAt);
    }

    function executeMaxPrizeBps() external onlyOwner {
        PendingBps memory p = _pendingMaxPrizeBps;
        if (!p.queued) revert NothingQueued();
        _requireInWindow(p.executableAt);
        emit MaxPrizeBpsExecuted(maxPrizeBps, p.bps);
        maxPrizeBps = p.bps;
        delete _pendingMaxPrizeBps;
    }

    function cancelMaxPrizeBps() external onlyOwner {
        if (!_pendingMaxPrizeBps.queued) revert NothingQueued();
        delete _pendingMaxPrizeBps;
        emit MaxPrizeBpsCancelled();
    }

    /* ------------------------------------------------------------------ */
    /*                  ADMIN: WIND-DOWN WITHDRAW (48h)                     */
    /* ------------------------------------------------------------------ */

    /// @notice Owner withdraw of USDC or a stock, for winding the product down. 48h notice.
    ///         Execution checks the same two floors {sweepSurplus} does, so it can never take
    ///         the pool below what sold boxes are owed.
    function queueSurplusWithdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0) || token == address(0) || amount == 0) revert BadConfig();
        if (token != usdc && !_stocks[token].registered) revert NotRegistered(token);
        uint64 executableAt = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingSurplus =
            PendingSurplus({queued: true, executableAt: executableAt, token: token, to: to, amount: amount});
        emit SurplusQueued(token, to, amount, executableAt);
    }

    function executeSurplusWithdraw() external onlyOwner nonReentrant {
        PendingSurplus memory p = _pendingSurplus;
        if (!p.queued) revert NothingQueued();
        _requireInWindow(p.executableAt);
        delete _pendingSurplus;

        address b = box;
        if (b == address(0)) revert BoxUnset();
        // H-03: fail closed. A reverting liability query reverts the withdraw.
        uint256 liabilityFloor =
            Math.mulDiv(IBox(b).outstandingLiabilityUsd(), SURPLUS_BUFFER_BPS, BPS, Math.Rounding.Ceil);
        uint256 reserve = jackpotReserveUsd();
        IERC20(p.token).safeTransfer(p.to, p.amount);
        // H-02: the liability floor is USDC only.
        uint256 left = _usdcToUsd(IERC20(usdc).balanceOf(address(this)));
        if (left < liabilityFloor) revert InsufficientSurplus(left, liabilityFloor);
        uint256 inv = inventoryUsd();
        if (inv < reserve) revert InsufficientSurplus(inv, reserve);
        emit SurplusWithdrawn(p.token, p.to, p.amount);
    }

    function cancelSurplusWithdraw() external onlyOwner {
        if (!_pendingSurplus.queued) revert NothingQueued();
        delete _pendingSurplus;
        emit SurplusCancelled();
    }

    /// @notice Stray tokens only: never USDC, never a registered stock. $CHIP is a stray
    ///         here — the vault has no $CHIP flow — so it CAN be returned.
    function rescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0) || token == address(0)) revert ZeroAddress();
        if (token == usdc || _stocks[token].registered) revert ProtectedAsset(token);
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                              INTERNAL                                */
    /* ------------------------------------------------------------------ */

    function _prizeCapUsd() internal view returns (uint256) {
        return inventoryUsd() * maxPrizeBps / BPS;
    }

    function _isChip(address token) internal view returns (bool) {
        if (token == address(0)) return false;
        if (token == DEFAULT_CHIP) return true;
        if (chip != address(0) && token == chip) return true;
        return false;
    }

    /// @dev Registry mark, 1e18 USD per whole token, or 0 when missing, reverting or stale.
    function _freshPrice(address token) internal view returns (uint256) {
        try registry.priceUsd(token) returns (uint256 p, uint256 updatedAt) {
            if (p == 0 || updatedAt == 0 || block.timestamp > updatedAt + maxFeedAge) return 0;
            return p;
        } catch {
            return 0;
        }
    }

    function _canPayStock(address token, uint256 prizeUsd) internal returns (bool ok, uint256 amount) {
        if (_isChip(token)) {
            emit StockSkipped(token, bytes32("chip"));
            return (false, 0);
        }
        PrizeStock memory st = _stocks[token];
        if (!st.enabled) {
            emit StockSkipped(token, bytes32("disabled"));
            return (false, 0);
        }
        uint256 price = _freshPrice(token);
        if (price == 0) {
            emit StockSkipped(token, bytes32("price"));
            return (false, 0);
        }
        amount = Math.mulDiv(prizeUsd * 1e12, 10 ** uint256(st.tokenDecimals), price);
        if (amount == 0) {
            emit StockSkipped(token, bytes32("dust"));
            return (false, 0);
        }
        if (amount > IERC20(token).balanceOf(address(this))) {
            emit StockSkipped(token, bytes32("thin"));
            return (false, 0);
        }
        return (true, amount);
    }

    /// @dev 6-dp USD value of `amount` at a 1e18 mark.
    function _tokensToUsd(uint256 amount, uint256 price, uint8 tokenDecimals) internal pure returns (uint256) {
        return Math.mulDiv(amount, price, 10 ** uint256(tokenDecimals) * 1e12);
    }

    function _usdcToUsd(uint256 amount) internal view returns (uint256) {
        uint8 d = usdcDecimals;
        if (d == 6) return amount;
        if (d > 6) return amount / (10 ** uint256(d - 6));
        return amount * (10 ** uint256(6 - d));
    }

    function _usdToUsdc(uint256 usd) internal view returns (uint256) {
        uint8 d = usdcDecimals;
        if (d == 6) return usd;
        if (d > 6) return usd * (10 ** uint256(d - 6));
        return usd / (10 ** uint256(6 - d));
    }

    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool) {
        try this.extTransfer(token, to, amount) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Self-call only, so {settle} can try/catch a SafeERC20 transfer.
    function extTransfer(address token, address to, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlyBox();
        IERC20(token).safeTransfer(to, amount);
    }

    function _wrap(uint256 i, uint256 n) internal pure returns (uint256) {
        return i < n ? i : i - n;
    }

    function _requireInWindow(uint64 executableAt) internal view {
        if (block.timestamp < executableAt) revert TimelockNotElapsed(uint64(block.timestamp), executableAt);
        uint64 expiresAt = executableAt + CONFIG_GRACE;
        if (block.timestamp > expiresAt) revert TimelockExpired(uint64(block.timestamp), expiresAt);
    }
}
