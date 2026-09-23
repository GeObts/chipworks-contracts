// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {IBox} from "../interfaces/IBox.sol";
import {IChipConverter} from "../interfaces/IChipConverter.sol";
import {IUniswapV3SwapRouter} from "../interfaces/ISwapRouters.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "../interfaces/IUniswapV4.sol";

/// @title ChipConverter
/// @notice Turns $CHIP box payments into prize-pool USDC, and CHIP-tier prizes into $CHIP.
///
/// @dev UNAUDITED. ─── READ THIS BEFORE AUDITING ANYTHING ELSE IN THE BOX ───
///
///      $CHIP HAS NO ON-CHAIN PRICE. Its only market is a Uniswap v4 pool behind a Doppler
///      hook that exposes no oracle and no cumulatives, and there is no Chainlink feed. So
///      the $CHIP leg of every swap here is bounded by a KEEPER-SUPPLIED minimum, not by an
///      oracle. A compromised keeper key can therefore sell box $CHIP too cheap, or buy a
///      winner's $CHIP too dear, and nothing on chain can tell. What bounds that loss:
///
///        - the keeper can only SWAP. Output goes to the fee recipient + vault (sell) or
///          to the named winner (buy). There is no path from here to the keeper.
///        - per-call and per-day caps on both directions, owner-set.
///        - an optional owner-set price band (`minUsdcPerMillionChip` / `maxUsdcPerMillionChip`)
///          that no keeper number can cross. 0 disables a side.
///        - the WETH<->USDC leg IS oracle-bounded (Chainlink ETH/USD), so the unbounded part
///          is the $CHIP/WETH leg only.
///
///      WHY THIS EXISTS (H-01, redone). The first Box sent 95% of a $CHIP payment to the
///      vault and then refused to let $CHIP leave the vault by any path — so every $CHIP
///      box was funded by USDC buyers and the $CHIP sat there forever. Now a $CHIP payment
///      lands HERE, whole, and leaves only as USDC (5% fee recipient, 95% vault) via
///      {sellChip}, or via a 48h owner recovery if the pool route ever breaks.
///
///      CHIP PRIZES WITHOUT CHIP INVENTORY. A CHIP-tier prize arrives from the vault as the
///      exact USD prize in USDC ({queueChipPrize}), escrowed per winner. {deliverChipPrizes}
///      buys $CHIP with it and sends it to the winners in the same transaction. If nobody
///      delivers within {CHIP_PRIZE_TIMEOUT}, the winner is paid the USDC instead
///      ({claimChipPrizeAsUsdc}). Escrowed USDC is never touched by anything else here.
///      Nothing is swapped inside the Pyth callback.
contract ChipConverter is IChipConverter, IUnlockCallback, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint32 public constant BPS = 10_000;
    uint64 public constant CHIP_PRIZE_TIMEOUT = 1 days;
    uint64 public constant RECOVERY_TIMELOCK = 48 hours;
    uint64 public constant RECOVERY_GRACE = 14 days;
    uint32 public constant MAX_ETH_SLIPPAGE_BPS = 300;
    uint256 public constant MAX_BATCH = 50;
    /// @dev 1e6 CHIP in wei — the unit the price band is quoted in.
    uint256 internal constant MILLION_CHIP = 1e24;

    /// @dev TickMath.MAX_SQRT_PRICE - 1 / MIN_SQRT_PRICE + 1. Curve-end guards, not slippage.
    uint160 internal constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4295128740;

    address public immutable override chip;
    address public immutable weth;
    address public immutable override usdc;
    IPoolManager public immutable poolManager;
    IUniswapV3SwapRouter public immutable v3Router;
    IAggregatorV3 public immutable ethUsdFeed;
    uint24 public immutable v3Fee;
    uint8 internal immutable _ethFeedDecimals;

    address public immutable currency0;
    address public immutable currency1;
    uint24 public immutable poolFee;
    int24 public immutable tickSpacing;
    address public immutable hooks;
    bool public immutable chipIsCurrency0;

    address public override box;
    address public keeper;

    /// @notice Most $CHIP one {sellChip} may push through the pool, and per UTC day.
    uint256 public maxChipPerSell;
    uint256 public maxChipSoldPerDay;
    /// @notice Most USDC one {deliverChipPrizes} may spend, and per UTC day.
    uint256 public maxUsdcPerDelivery;
    uint256 public maxUsdcDeliveredPerDay;
    /// @notice Owner price band, USDC (6 dp) per 1,000,000 $CHIP. 0 disables that side.
    uint256 public minUsdcPerMillionChip;
    uint256 public maxUsdcPerMillionChip;
    /// @notice ETH/USD leg: slippage below the Chainlink mark, and the oldest mark accepted.
    uint32 public ethSlippageBps = 100;
    uint64 public maxEthFeedAge = 1 hours;

    mapping(uint256 day => uint256) public chipSoldOnDay;
    mapping(uint256 day => uint256) public usdcDeliveredOnDay;

    uint256 public override escrowedUsdc;
    uint256 public nextPrizeId = 1;
    mapping(uint256 => ChipPrize) internal _prizes;

    struct PendingRecovery {
        bool queued;
        uint64 executableAt;
        address to;
    }

    PendingRecovery internal _pendingRecovery;

    event BoxSet(address indexed box);
    event KeeperSet(address indexed keeper);
    event LimitsSet(uint256 maxChipPerSell, uint256 maxChipSoldPerDay, uint256 maxUsdcPerDelivery, uint256 maxUsdcDeliveredPerDay);
    event PriceBandSet(uint256 minUsdcPerMillionChip, uint256 maxUsdcPerMillionChip);
    event EthLegSet(uint32 slippageBps, uint64 maxFeedAge);
    event ChipSold(uint256 chipIn, uint256 usdcOut, uint256 toFeeRecipient, uint256 toVault, address indexed feeRecipient);
    event ChipPrizeQueued(uint256 indexed id, address indexed winner, uint256 usdcAmount);
    event ChipPrizeDelivered(uint256 indexed id, address indexed winner, uint256 usdcAmount, uint256 chipAmount);
    event ChipPrizePaidInUsdc(uint256 indexed id, address indexed winner, uint256 usdcAmount);
    event RecoveryQueued(address indexed to, uint64 executableAt);
    event RecoveryExecuted(address indexed to, uint256 chipAmount);
    event RecoveryCancelled();
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error BadConfig();
    error AlreadyWired();
    error NotKeeper(address caller);
    error NotVault(address caller);
    error NotPoolManager(address caller);
    error KeyIsNotChipWeth();
    error DeadlinePassed(uint256 nowTs, uint256 deadline);
    error OverCap(uint256 amount, uint256 cap);
    error OverDailyCap(uint256 wouldBe, uint256 cap);
    error BelowMinOut(uint256 out, uint256 minOut);
    error OutsidePriceBand(uint256 usdcPerMillionChip, uint256 min, uint256 max);
    error NothingSwapped();
    error BadEthPrice();
    error UnknownPrize(uint256 id);
    error PrizeSettled(uint256 id);
    error NotTimedOut(uint64 nowTs, uint64 readyAt);
    error EmptyBatch();
    error BatchTooLarge(uint256 n);
    error NothingQueued();
    error TimelockNotElapsed(uint64 nowTs, uint64 executableAt);
    error TimelockExpired(uint64 nowTs, uint64 expiredAt);
    error ProtectedAsset(address token);

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper(msg.sender);
        _;
    }

    constructor(
        address owner_,
        address chip_,
        address weth_,
        address usdc_,
        address poolManager_,
        address v3Router_,
        address ethUsdFeed_,
        uint24 v3Fee_,
        PoolKey memory poolKey_
    ) Ownable(owner_) {
        if (
            owner_ == address(0) || chip_ == address(0) || weth_ == address(0) || usdc_ == address(0)
                || poolManager_ == address(0) || v3Router_ == address(0) || ethUsdFeed_ == address(0)
        ) revert ZeroAddress();
        chip = chip_;
        weth = weth_;
        usdc = usdc_;
        poolManager = IPoolManager(poolManager_);
        v3Router = IUniswapV3SwapRouter(v3Router_);
        ethUsdFeed = IAggregatorV3(ethUsdFeed_);
        v3Fee = v3Fee_;
        uint8 fd = IAggregatorV3(ethUsdFeed_).decimals();
        if (fd == 0 || fd > 18) revert BadConfig();
        _ethFeedDecimals = fd;

        currency0 = poolKey_.currency0;
        currency1 = poolKey_.currency1;
        poolFee = poolKey_.fee;
        tickSpacing = poolKey_.tickSpacing;
        hooks = poolKey_.hooks;
        // Same guard as ChipLottery: every direction below is derived from this boolean.
        if (poolKey_.currency0 == chip_ && poolKey_.currency1 == weth_) {
            chipIsCurrency0 = true;
        } else if (poolKey_.currency0 == weth_ && poolKey_.currency1 == chip_) {
            chipIsCurrency0 = false;
        } else {
            revert KeyIsNotChipWeth();
        }
    }

    /* ------------------------------------------------------------------ */
    /*                              WIRING                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Point at the Box, once. The vault and fee recipient are read from it live.
    function setBox(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        if (box != address(0)) revert AlreadyWired();
        if (IBox(v).chip() != chip || IBox(v).usdc() != usdc || IBox(v).converter() != address(this)) {
            revert BadConfig();
        }
        box = v;
        emit BoxSet(v);
    }

    /// @notice Immediate: the keeper can only swap within the caps, never withdraw.
    function setKeeper(address v) external onlyOwner {
        keeper = v;
        emit KeeperSet(v);
    }

    function setLimits(uint256 chipPerSell, uint256 chipPerDay, uint256 usdcPerDelivery, uint256 usdcPerDay)
        external
        onlyOwner
    {
        maxChipPerSell = chipPerSell;
        maxChipSoldPerDay = chipPerDay;
        maxUsdcPerDelivery = usdcPerDelivery;
        maxUsdcDeliveredPerDay = usdcPerDay;
        emit LimitsSet(chipPerSell, chipPerDay, usdcPerDelivery, usdcPerDay);
    }

    function setPriceBand(uint256 minPerMillion, uint256 maxPerMillion) external onlyOwner {
        if (maxPerMillion != 0 && minPerMillion > maxPerMillion) revert BadConfig();
        minUsdcPerMillionChip = minPerMillion;
        maxUsdcPerMillionChip = maxPerMillion;
        emit PriceBandSet(minPerMillion, maxPerMillion);
    }

    function setEthLeg(uint32 slippageBps, uint64 maxFeedAge) external onlyOwner {
        if (slippageBps > MAX_ETH_SLIPPAGE_BPS || maxFeedAge == 0) revert BadConfig();
        ethSlippageBps = slippageBps;
        maxEthFeedAge = maxFeedAge;
        emit EthLegSet(slippageBps, maxFeedAge);
    }

    /* ------------------------------------------------------------------ */
    /*                      SELL: box $CHIP -> USDC                         */
    /* ------------------------------------------------------------------ */

    /// @notice Sell `chipIn` of the $CHIP boxes were paid in. 5% of the USDC goes to the
    ///         Box's fee recipient, 95% to the vault — the same split a USDC buy gets.
    /// @param minUsdcOut  The keeper's floor for the whole trade. The only bound on the
    ///                    $CHIP leg besides the owner band. See the contract header.
    function sellChip(uint256 chipIn, uint256 minUsdcOut, uint256 deadline)
        external
        nonReentrant
        onlyKeeper
        returns (uint256 usdcOut)
    {
        if (block.timestamp > deadline) revert DeadlinePassed(block.timestamp, deadline);
        if (chipIn == 0) revert BadConfig();
        if (chipIn > maxChipPerSell) revert OverCap(chipIn, maxChipPerSell);
        uint256 day = block.timestamp / 1 days;
        uint256 sold = chipSoldOnDay[day] + chipIn;
        if (sold > maxChipSoldPerDay) revert OverDailyCap(sold, maxChipSoldPerDay);
        chipSoldOnDay[day] = sold;

        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));
        uint256 chipSpent = _v4Swap(true, chipIn);
        uint256 wethIn = IERC20(weth).balanceOf(address(this));
        _v3Swap(weth, usdc, wethIn, _usdcForWeth(wethIn));
        usdcOut = IERC20(usdc).balanceOf(address(this)) - usdcBefore;

        if (usdcOut < minUsdcOut) revert BelowMinOut(usdcOut, minUsdcOut);
        _checkBand(usdcOut, chipSpent);

        address b = box;
        address feeTo = IBox(b).treasury();
        uint256 fee = usdcOut * IBox(b).FEE_BPS() / BPS;
        IERC20(usdc).safeTransfer(feeTo, fee);
        IERC20(usdc).safeTransfer(IBox(b).vault(), usdcOut - fee);
        emit ChipSold(chipSpent, usdcOut, fee, usdcOut - fee, feeTo);
    }

    /* ------------------------------------------------------------------ */
    /*                    BUY: CHIP-tier prizes                             */
    /* ------------------------------------------------------------------ */

    /// @inheritdoc IChipConverter
    function queueChipPrize(address winner, uint256 usdcAmount) external override returns (uint256 id) {
        address b = box;
        if (b == address(0) || msg.sender != IBox(b).vault()) revert NotVault(msg.sender);
        if (winner == address(0) || usdcAmount == 0 || usdcAmount > type(uint96).max) revert BadConfig();
        // The vault transfers first. Escrow can only ever be backed by USDC already here.
        if (IERC20(usdc).balanceOf(address(this)) < escrowedUsdc + usdcAmount) revert BadConfig();
        id = nextPrizeId++;
        _prizes[id] =
            ChipPrize({winner: winner, usdcAmount: uint96(usdcAmount), queuedAt: uint64(block.timestamp), settled: false});
        escrowedUsdc += usdcAmount;
        emit ChipPrizeQueued(id, winner, usdcAmount);
    }

    /// @notice Buy $CHIP for a batch of CHIP-tier winners in ONE swap, and send each their
    ///         share pro rata to the USDC they won. Nothing is left here: the rounding
    ///         remainder goes to the last winner in the batch.
    /// @param minChipOut  The keeper's floor for the whole batch. See the contract header.
    function deliverChipPrizes(uint256[] calldata ids, uint256 minChipOut, uint256 deadline)
        external
        nonReentrant
        onlyKeeper
        returns (uint256 chipOut)
    {
        if (block.timestamp > deadline) revert DeadlinePassed(block.timestamp, deadline);
        uint256 usdcIn = _markBatch(ids);
        chipOut = _buyChip(usdcIn);
        if (chipOut < minChipOut) revert BelowMinOut(chipOut, minChipOut);
        _checkBand(usdcIn, chipOut);
        _distribute(ids, chipOut, usdcIn);
    }

    /// @dev Validates the batch, marks every prize settled, applies the caps, releases escrow.
    function _markBatch(uint256[] calldata ids) internal returns (uint256 usdcIn) {
        uint256 n = ids.length;
        if (n == 0) revert EmptyBatch();
        if (n > MAX_BATCH) revert BatchTooLarge(n);
        for (uint256 i; i < n; ++i) {
            ChipPrize storage p = _prizes[ids[i]];
            if (p.winner == address(0)) revert UnknownPrize(ids[i]);
            if (p.settled) revert PrizeSettled(ids[i]);
            p.settled = true; // a duplicate id in the batch now reverts above
            usdcIn += p.usdcAmount;
        }
        if (usdcIn > maxUsdcPerDelivery) revert OverCap(usdcIn, maxUsdcPerDelivery);
        uint256 day = block.timestamp / 1 days;
        uint256 spent = usdcDeliveredOnDay[day] + usdcIn;
        if (spent > maxUsdcDeliveredPerDay) revert OverDailyCap(spent, maxUsdcDeliveredPerDay);
        usdcDeliveredOnDay[day] = spent;
        escrowedUsdc -= usdcIn;
    }

    /// @dev USDC -> WETH (Chainlink-bounded) -> $CHIP (keeper-bounded, checked by the caller).
    function _buyChip(uint256 usdcIn) internal returns (uint256 chipOut) {
        uint256 chipBefore = IERC20(chip).balanceOf(address(this));
        uint256 wethBefore = IERC20(weth).balanceOf(address(this));
        _v3Swap(usdc, weth, usdcIn, _wethForUsdc(usdcIn));
        _v4Swap(false, IERC20(weth).balanceOf(address(this)) - wethBefore);
        chipOut = IERC20(chip).balanceOf(address(this)) - chipBefore;
    }

    /// @dev Pro rata to USDC won; the rounding remainder goes to the last winner.
    function _distribute(uint256[] calldata ids, uint256 chipOut, uint256 usdcIn) internal {
        uint256 n = ids.length;
        uint256 left = chipOut;
        for (uint256 i; i < n; ++i) {
            ChipPrize memory p = _prizes[ids[i]];
            uint256 share = i == n - 1 ? left : chipOut * p.usdcAmount / usdcIn;
            left -= share;
            IERC20(chip).safeTransfer(p.winner, share);
            emit ChipPrizeDelivered(ids[i], p.winner, p.usdcAmount, share);
        }
    }

    /// @notice Pay a CHIP-tier prize in the USDC it was escrowed as, once nobody has
    ///         delivered it for {CHIP_PRIZE_TIMEOUT}. Permissionless; pays the winner only.
    function claimChipPrizeAsUsdc(uint256 id) external nonReentrant {
        ChipPrize storage p = _prizes[id];
        if (p.winner == address(0)) revert UnknownPrize(id);
        if (p.settled) revert PrizeSettled(id);
        uint64 readyAt = p.queuedAt + CHIP_PRIZE_TIMEOUT;
        if (block.timestamp < readyAt) revert NotTimedOut(uint64(block.timestamp), readyAt);
        p.settled = true;
        escrowedUsdc -= p.usdcAmount;
        IERC20(usdc).safeTransfer(p.winner, p.usdcAmount);
        emit ChipPrizePaidInUsdc(id, p.winner, p.usdcAmount);
    }

    function chipPrize(uint256 id) external view override returns (ChipPrize memory) {
        return _prizes[id];
    }

    /* ------------------------------------------------------------------ */
    /*                    RECOVERY (route broken)                           */
    /* ------------------------------------------------------------------ */

    /// @notice If the $CHIP pool route ever stops working, unsold box $CHIP must not be
    ///         stranded the way the first Box stranded it. 48h notice, then all of it to `to`.
    function queueChipRecovery(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint64 at = uint64(block.timestamp) + RECOVERY_TIMELOCK;
        _pendingRecovery = PendingRecovery({queued: true, executableAt: at, to: to});
        emit RecoveryQueued(to, at);
    }

    function executeChipRecovery() external onlyOwner nonReentrant {
        PendingRecovery memory p = _pendingRecovery;
        if (!p.queued) revert NothingQueued();
        if (block.timestamp < p.executableAt) revert TimelockNotElapsed(uint64(block.timestamp), p.executableAt);
        uint64 expiresAt = p.executableAt + RECOVERY_GRACE;
        if (block.timestamp > expiresAt) revert TimelockExpired(uint64(block.timestamp), expiresAt);
        delete _pendingRecovery;
        uint256 amount = IERC20(chip).balanceOf(address(this));
        IERC20(chip).safeTransfer(p.to, amount);
        emit RecoveryExecuted(p.to, amount);
    }

    function cancelChipRecovery() external onlyOwner {
        if (!_pendingRecovery.queued) revert NothingQueued();
        delete _pendingRecovery;
        emit RecoveryCancelled();
    }

    /// @notice Stray tokens. Never $CHIP (see {queueChipRecovery}) and never escrowed USDC.
    function rescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == chip) revert ProtectedAsset(token);
        if (token == usdc && IERC20(usdc).balanceOf(address(this)) < escrowedUsdc + amount) {
            revert ProtectedAsset(token);
        }
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                             SWAPS                                    */
    /* ------------------------------------------------------------------ */

    function _checkBand(uint256 usdcAmt, uint256 chipAmt) internal view {
        uint256 lo = minUsdcPerMillionChip;
        uint256 hi = maxUsdcPerMillionChip;
        if (lo == 0 && hi == 0) return;
        if (chipAmt == 0) revert NothingSwapped();
        uint256 px = usdcAmt * MILLION_CHIP / chipAmt;
        if ((lo != 0 && px < lo) || (hi != 0 && px > hi)) revert OutsidePriceBand(px, lo, hi);
    }

    function _ethPrice() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = ethUsdFeed.latestRoundData();
        if (answer <= 0 || updatedAt == 0 || block.timestamp > updatedAt + maxEthFeedAge) revert BadEthPrice();
        return uint256(answer);
    }

    /// @dev Chainlink-bounded minimum USDC for `wethIn`. 18 dp WETH, 6 dp USDC.
    function _usdcForWeth(uint256 wethIn) internal view returns (uint256) {
        uint256 fair = wethIn * _ethPrice() / (10 ** (12 + uint256(_ethFeedDecimals)));
        return fair * (BPS - ethSlippageBps) / BPS;
    }

    /// @dev Chainlink-bounded minimum WETH for `usdcIn`.
    function _wethForUsdc(uint256 usdcIn) internal view returns (uint256) {
        uint256 fair = usdcIn * (10 ** (12 + uint256(_ethFeedDecimals))) / _ethPrice();
        return fair * (BPS - ethSlippageBps) / BPS;
    }

    function _v3Swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut) internal {
        IERC20(tokenIn).forceApprove(address(v3Router), amountIn);
        v3Router.exactInputSingle(
            IUniswapV3SwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: v3Fee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(tokenIn).forceApprove(address(v3Router), 0);
    }

    /// @dev Exact-input swap on the $CHIP/WETH v4 pool. `sellChip` true = CHIP in, WETH out.
    ///      Returns the input actually paid, measured by balance.
    function _v4Swap(bool sellChip_, uint256 amountIn) internal returns (uint256 paid) {
        address tokenIn = sellChip_ ? chip : weth;
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        poolManager.unlock(abi.encode(sellChip_, amountIn));
        paid = before - IERC20(tokenIn).balanceOf(address(this));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager(msg.sender);
        (bool sellChip_, uint256 amountIn) = abi.decode(data, (bool, uint256));

        // Selling $CHIP swaps $CHIP's side for the other; buying swaps the other way.
        bool zeroForOne = sellChip_ ? chipIsCurrency0 : !chipIsCurrency0;
        // NEGATIVE amountSpecified is exact INPUT (v4-core). ChipLottery uses the positive,
        // exact-output form; test/fork/V4SignConvention.t.sol proves both signs live.
        int256 delta = poolManager.swap(
            PoolKey({currency0: currency0, currency1: currency1, fee: poolFee, tickSpacing: tickSpacing, hooks: hooks}),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT
            }),
            ""
        );
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        // Input side is negative (owed to the pool), output positive.
        int128 inDelta = zeroForOne ? amount0 : amount1;
        int128 outDelta = zeroForOne ? amount1 : amount0;
        if (inDelta >= 0 || outDelta <= 0) revert NothingSwapped();

        address tokenIn = sellChip_ ? chip : weth;
        address tokenOut = sellChip_ ? weth : chip;
        uint256 owed = uint256(uint128(-inDelta));
        if (owed > amountIn) revert NothingSwapped();

        poolManager.sync(tokenIn);
        IERC20(tokenIn).safeTransfer(address(poolManager), owed);
        poolManager.settle();
        poolManager.take(tokenOut, address(this), uint256(uint128(outDelta)));
        return "";
    }
}
