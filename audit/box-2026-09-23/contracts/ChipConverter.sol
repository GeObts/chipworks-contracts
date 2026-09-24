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
/// @notice Turns the $CHIP boxes were paid in into prize-pool USDC: 5% to the Box's fee
///         recipient, 95% to the vault — the same split a USDC buy gets in the Box itself.
///
/// @dev UNAUDITED. ─── READ THIS BEFORE AUDITING ANYTHING ELSE IN THE BOX ───
///
///      $CHIP HAS NO ON-CHAIN PRICE. Its only market is a Uniswap v4 pool behind a Doppler
///      hook that exposes no oracle and no cumulatives, and there is no Chainlink feed. So
///      the $CHIP -> WETH leg of {sellChip} is bounded by a KEEPER-SUPPLIED minimum, not by
///      an oracle. A compromised keeper key could sell box $CHIP too cheap, and nothing on
///      chain can tell. What bounds that loss:
///
///        - the keeper can only SELL. Output goes to the fee recipient and the vault, read
///          live from the Box. There is no path from here to the keeper.
///        - per-call and per-day caps, owner-set.
///        - an optional owner-set price floor ({minUsdcPerMillionChip}) that no keeper
///          number can go under. 0 disables it.
///        - the WETH -> USDC leg IS oracle-bounded (Chainlink ETH/USD), so the unbounded part
///          is the $CHIP/WETH leg only.
///
///      WHY THIS EXISTS (H-01, redone). The first Box sent 95% of a $CHIP payment to the
///      vault and then refused to let $CHIP leave the vault by any path — so every $CHIP
///      box was funded by USDC buyers and the $CHIP sat there forever. Now a $CHIP payment
///      lands HERE, whole, and leaves only as USDC via {sellChip}, or via a 48h owner
///      recovery if the pool route ever breaks. Prizes are never paid in $CHIP.
contract ChipConverter is IChipConverter, IUnlockCallback, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint32 public constant BPS = 10_000;
    uint64 public constant RECOVERY_TIMELOCK = 48 hours;
    uint64 public constant RECOVERY_GRACE = 14 days;
    uint32 public constant MAX_ETH_SLIPPAGE_BPS = 300;
    /// @dev 1e6 CHIP in wei — the unit the price floor is quoted in.
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
    /// @notice Owner price floor, USDC (6 dp) per 1,000,000 $CHIP. 0 disables it.
    uint256 public minUsdcPerMillionChip;
    /// @notice ETH/USD leg: slippage below the Chainlink mark, and the oldest mark accepted.
    uint32 public ethSlippageBps = 100;
    uint64 public maxEthFeedAge = 1 hours;

    mapping(uint256 day => uint256) public chipSoldOnDay;

    struct PendingRecovery {
        bool queued;
        uint64 executableAt;
        address to;
    }

    PendingRecovery internal _pendingRecovery;

    event BoxSet(address indexed box);
    event KeeperSet(address indexed keeper);
    event LimitsSet(uint256 maxChipPerSell, uint256 maxChipSoldPerDay);
    event PriceFloorSet(uint256 minUsdcPerMillionChip);
    event EthLegSet(uint32 slippageBps, uint64 maxFeedAge);
    event ChipSold(uint256 chipIn, uint256 usdcOut, uint256 toFeeRecipient, uint256 toVault, address indexed feeRecipient);
    event RecoveryQueued(address indexed to, uint64 executableAt);
    event RecoveryExecuted(address indexed to, uint256 chipAmount);
    event RecoveryCancelled();
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error BadConfig();
    error AlreadyWired();
    error NotKeeper(address caller);
    error NotPoolManager(address caller);
    error KeyIsNotChipWeth();
    error DeadlinePassed(uint256 nowTs, uint256 deadline);
    error OverCap(uint256 amount, uint256 cap);
    error OverDailyCap(uint256 wouldBe, uint256 cap);
    error BelowMinOut(uint256 out, uint256 minOut);
    error BelowPriceFloor(uint256 usdcPerMillionChip, uint256 floor);
    error NothingSwapped();
    error BadEthPrice();
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
        // Same guard as ChipLottery: the swap direction below is derived from this boolean.
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

    /// @notice Immediate: the keeper can only sell within the caps, never withdraw.
    function setKeeper(address v) external onlyOwner {
        keeper = v;
        emit KeeperSet(v);
    }

    function setLimits(uint256 chipPerSell, uint256 chipPerDay) external onlyOwner {
        maxChipPerSell = chipPerSell;
        maxChipSoldPerDay = chipPerDay;
        emit LimitsSet(chipPerSell, chipPerDay);
    }

    function setPriceFloor(uint256 minPerMillion) external onlyOwner {
        minUsdcPerMillionChip = minPerMillion;
        emit PriceFloorSet(minPerMillion);
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
    ///         Box's fee recipient, 95% to the vault.
    /// @param minUsdcOut  The keeper's floor for the whole trade. With the owner floor, the
    ///                    only bound on the $CHIP leg. See the contract header.
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
        uint256 wethBefore = IERC20(weth).balanceOf(address(this));
        uint256 chipSpent = _sellChipForWeth(chipIn);
        uint256 wethIn = IERC20(weth).balanceOf(address(this)) - wethBefore;
        _wethToUsdc(wethIn);
        usdcOut = IERC20(usdc).balanceOf(address(this)) - usdcBefore;

        if (usdcOut < minUsdcOut) revert BelowMinOut(usdcOut, minUsdcOut);
        _checkFloorAndPay(chipSpent, usdcOut);
    }

    /// @dev The owner floor, then 5% to the Box's fee recipient and 95% to the vault.
    function _checkFloorAndPay(uint256 chipSpent, uint256 usdcOut) internal {
        uint256 floor = minUsdcPerMillionChip;
        if (floor != 0) {
            uint256 px = usdcOut * MILLION_CHIP / chipSpent;
            if (px < floor) revert BelowPriceFloor(px, floor);
        }
        address b = box;
        address feeTo = IBox(b).treasury();
        uint256 fee = usdcOut * IBox(b).FEE_BPS() / BPS;
        IERC20(usdc).safeTransfer(feeTo, fee);
        IERC20(usdc).safeTransfer(IBox(b).vault(), usdcOut - fee);
        emit ChipSold(chipSpent, usdcOut, fee, usdcOut - fee, feeTo);
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

    /// @notice Stray tokens. Never $CHIP (see {queueChipRecovery}). Nothing else is ever held
    ///         here between calls: {sellChip} forwards every unit of USDC it produces.
    function rescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == chip) revert ProtectedAsset(token);
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                             SWAPS                                    */
    /* ------------------------------------------------------------------ */

    /// @dev WETH -> USDC on v3 with the minimum set by Chainlink ETH/USD less {ethSlippageBps}.
    function _wethToUsdc(uint256 wethIn) internal {
        (, int256 answer,, uint256 updatedAt,) = ethUsdFeed.latestRoundData();
        if (answer <= 0 || updatedAt == 0 || block.timestamp > updatedAt + maxEthFeedAge) revert BadEthPrice();
        // 18-dp WETH x 8-dp price -> 6-dp USDC.
        uint256 fair = wethIn * uint256(answer) / (10 ** (12 + uint256(_ethFeedDecimals)));
        uint256 minOut = fair * (BPS - ethSlippageBps) / BPS;

        IERC20(weth).forceApprove(address(v3Router), wethIn);
        v3Router.exactInputSingle(
            IUniswapV3SwapRouter.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: usdc,
                fee: v3Fee,
                recipient: address(this),
                amountIn: wethIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(weth).forceApprove(address(v3Router), 0);
    }

    /// @dev Exact-input $CHIP -> WETH on the v4 pool. Returns the $CHIP actually paid, measured.
    function _sellChipForWeth(uint256 chipIn) internal returns (uint256 paid) {
        uint256 before = IERC20(chip).balanceOf(address(this));
        poolManager.unlock(abi.encode(chipIn));
        paid = before - IERC20(chip).balanceOf(address(this));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager(msg.sender);
        uint256 chipIn = abi.decode(data, (uint256));

        // Selling $CHIP swaps $CHIP's side for the other.
        bool zeroForOne = chipIsCurrency0;
        // NEGATIVE amountSpecified is exact INPUT (v4-core). ChipLottery uses the positive,
        // exact-output form; test/fork/V4SignConvention.t.sol proves both signs live.
        int256 delta = poolManager.swap(
            PoolKey({currency0: currency0, currency1: currency1, fee: poolFee, tickSpacing: tickSpacing, hooks: hooks}),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(chipIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT
            }),
            ""
        );
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        int128 chipDelta = chipIsCurrency0 ? amount0 : amount1;
        int128 wethDelta = chipIsCurrency0 ? amount1 : amount0;
        if (chipDelta >= 0 || wethDelta <= 0) revert NothingSwapped();

        uint256 owed = uint256(uint128(-chipDelta));
        if (owed > chipIn) revert NothingSwapped();

        poolManager.sync(chip);
        IERC20(chip).safeTransfer(address(poolManager), owed);
        poolManager.settle();
        poolManager.take(weth, address(this), uint256(uint128(wethDelta)));
        return "";
    }
}
