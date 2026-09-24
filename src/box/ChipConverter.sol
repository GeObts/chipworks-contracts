// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IBox} from "../interfaces/IBox.sol";
import {IChipConverter} from "../interfaces/IChipConverter.sol";
import {IPoolManager, IUnlockCallback, IUniswapV3ExactOutput, PoolKey, SwapParams} from "../interfaces/IUniswapV4.sol";

/// @title ChipConverter
/// @notice Pays for a box in $CHIP by swapping the buyer's $CHIP to the box's exact USDC price,
///         inside the buy. The Box receives exactly that USDC and splits it 5/95 like any USDC buy.
///
/// @dev UNAUDITED. THE SWAP IS LIFTED FROM THE DEPLOYED ChipLottery (0x2F68…70F0), which buys
///      Megapot tickets the same way: $CHIP -> WETH exact OUTPUT on the $CHIP/WETH Uniswap v4 pool,
///      then WETH -> USDC exact OUTPUT on the v3 pool. Only the recipient of the USDC differs.
///
///      WHY SWAP AT BUY (audit round 1, H-1 / H-2 / F-1). The previous design took a fixed $CHIP
///      price per box and let a keeper sell the $CHIP later. When $CHIP fell, a "$10" box cost $5
///      of $CHIP while its prizes stayed in dollars — measured: $4.75 into the pool for $9.10 of
///      liability, an arbitrage anyone could run. Swapping at buy funds the pool at face every
///      time, whatever $CHIP does, and removes the keeper sale, its trust point, the owner price
///      floor and the $CHIP recovery path with it.
///
///      THE BUYER CARRIES THE PRICE RISK, AND BOUNDS IT. `maxChipIn` is the most $CHIP they will
///      part with; `wethNeeded` (quoted off chain) bounds the ETH leg. A sandwich can only cost the
///      buyer up to their own `maxChipIn`; it can never short the pool, because the USDC leg is
///      exact output. The pool fee (~2.3% measured) is the buyer's: the UI must say so.
///
///      NOTHING STAYS HERE. Every call ends with this contract holding no $CHIP, WETH or USDC:
///      the USDC goes to the Box, and every unspent token goes back to the payer. So {rescue} can
///      only ever reach tokens sent here by mistake ({sweepZero} reads (0,0,0) between calls).
contract ChipConverter is IChipConverter, IUnlockCallback, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev TickMath.MAX_SQRT_PRICE - 1 / MIN_SQRT_PRICE + 1. Curve-end guards, not slippage:
    ///      `maxChipIn` is the bound.
    uint160 internal constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4295128740;

    address public immutable override chip;
    address public immutable weth;
    address public immutable override usdc;
    IPoolManager public immutable poolManager;
    IUniswapV3ExactOutput public immutable v3Router;
    /// @notice The v3 fee tier for the WETH -> USDC leg. 500 = 0.05%.
    uint24 public immutable v3Fee;

    address public immutable currency0;
    address public immutable currency1;
    uint24 public immutable poolFee;
    int24 public immutable tickSpacing;
    address public immutable hooks;
    bool public immutable chipIsCurrency0;

    address public override box;

    event BoxSet(address indexed box);
    event ChipSwapped(address indexed payer, uint256 chipSpent, uint256 usdcOut);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error BadConfig();
    error AlreadyWired();
    error NotBox(address caller);
    error NotPoolManager(address caller);
    error KeyIsNotChipWeth();
    error NothingSwapped();
    error ChipCostAboveMax(uint256 needed, uint256 max);
    error SwapAccountingMismatch(uint256 reported, uint256 measured);
    error UsdcShort(uint256 got, uint256 wanted);

    constructor(
        address owner_,
        address chip_,
        address weth_,
        address usdc_,
        address poolManager_,
        address v3Router_,
        uint24 v3Fee_,
        PoolKey memory poolKey_
    ) Ownable(owner_) {
        if (
            owner_ == address(0) || chip_ == address(0) || weth_ == address(0) || usdc_ == address(0)
                || poolManager_ == address(0) || v3Router_ == address(0)
        ) revert ZeroAddress();
        chip = chip_;
        weth = weth_;
        usdc = usdc_;
        poolManager = IPoolManager(poolManager_);
        v3Router = IUniswapV3ExactOutput(v3Router_);
        v3Fee = v3Fee_;

        currency0 = poolKey_.currency0;
        currency1 = poolKey_.currency1;
        poolFee = poolKey_.fee;
        tickSpacing = poolKey_.tickSpacing;
        hooks = poolKey_.hooks;
        // Same guard as ChipLottery: the swap direction and delta decode derive from this boolean.
        if (poolKey_.currency0 == chip_ && poolKey_.currency1 == weth_) {
            chipIsCurrency0 = true;
        } else if (poolKey_.currency0 == weth_ && poolKey_.currency1 == chip_) {
            chipIsCurrency0 = false;
        } else {
            revert KeyIsNotChipWeth();
        }
    }

    /// @notice Point at the Box, once. Only the Box can swap.
    function setBox(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        if (box != address(0)) revert AlreadyWired();
        if (IBox(v).chip() != chip || IBox(v).usdc() != usdc || IBox(v).converter() != address(this)) {
            revert BadConfig();
        }
        box = v;
        emit BoxSet(v);
    }

    /// @inheritdoc IChipConverter
    /// @dev The Box has ALREADY moved `maxChipIn` of the payer's $CHIP here. Steps, as ChipLottery:
    ///      1. $CHIP -> WETH, exact output `wethNeeded`, reverting if it costs more than `maxChipIn`;
    ///         the pool's reported cost is checked against the measured balance change.
    ///      2. WETH -> USDC, exact output `usdcOut`, straight to the Box, spending at most the WETH
    ///         step 1 bought.
    ///      3. Every unspent $CHIP and WETH goes back to `payer`.
    function swapToUsdc(uint256 usdcOut, uint256 wethNeeded, uint256 maxChipIn, address payer)
        external
        override
        nonReentrant
        returns (uint256 chipSpent)
    {
        address b = box;
        if (msg.sender != b) revert NotBox(msg.sender);
        if (usdcOut == 0 || wethNeeded == 0 || maxChipIn == 0 || payer == address(0)) revert BadConfig();

        uint256 chipBefore = IERC20(chip).balanceOf(address(this));
        uint256 reported = _swapChipForWeth(wethNeeded, maxChipIn);
        uint256 measured = chipBefore - IERC20(chip).balanceOf(address(this));
        if (reported != measured) revert SwapAccountingMismatch(reported, measured);

        _wethToUsdc(b, usdcOut);
        _refund(payer);

        chipSpent = measured;
        emit ChipSwapped(payer, chipSpent, usdcOut);
    }

    /// @dev WETH -> exactly `usdcOut` USDC to `to`, spending at most the WETH held.
    function _wethToUsdc(address to, uint256 usdcOut) internal {
        uint256 usdcBefore = IERC20(usdc).balanceOf(to);
        uint256 wethHeld = IERC20(weth).balanceOf(address(this));
        IERC20(weth).forceApprove(address(v3Router), wethHeld);
        v3Router.exactOutputSingle(
            IUniswapV3ExactOutput.ExactOutputSingleParams({
                tokenIn: weth,
                tokenOut: usdc,
                fee: v3Fee,
                recipient: to,
                amountOut: usdcOut,
                amountInMaximum: wethHeld,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(weth).forceApprove(address(v3Router), 0);
        // Exact output means exactly this: the Box must have received the whole price.
        uint256 got = IERC20(usdc).balanceOf(to) - usdcBefore;
        if (got != usdcOut) revert UsdcShort(got, usdcOut);
    }

    /// @dev Every unspent $CHIP and WETH back to whoever paid. Nothing stays here.
    function _refund(address payer) internal {
        uint256 chipLeft = IERC20(chip).balanceOf(address(this));
        if (chipLeft != 0) IERC20(chip).safeTransfer(payer, chipLeft);
        uint256 wethLeft = IERC20(weth).balanceOf(address(this));
        if (wethLeft != 0) IERC20(weth).safeTransfer(payer, wethLeft);
    }

    /// @notice What this contract holds. Expected to be (0,0,0) between calls.
    function sweepZero() external view returns (uint256 chipBal, uint256 wethBal, uint256 usdcBal) {
        return (IERC20(chip).balanceOf(address(this)), IERC20(weth).balanceOf(address(this)), IERC20(usdc).balanceOf(address(this)));
    }

    /// @notice Recover a token sent here by mistake. Safe because no call leaves anything behind:
    ///         there is never in-flight user money for the owner to take (same reasoning as
    ///         ChipLottery.rescue).
    function rescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                  THE V4 SWAP (as ChipLottery)                        */
    /* ------------------------------------------------------------------ */

    function _swapChipForWeth(uint256 wethOut, uint256 maxChipIn) internal returns (uint256 chipUsed) {
        bytes memory out = poolManager.unlock(abi.encode(wethOut, maxChipIn));
        chipUsed = abi.decode(out, (uint256));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager(msg.sender);
        (uint256 wethOut, uint256 maxChipIn) = abi.decode(data, (uint256, uint256));

        // Selling $CHIP for WETH: $CHIP's side for the other. Down-swaps are limited from below.
        bool zeroForOne = chipIsCurrency0;
        // POSITIVE amountSpecified is exact OUTPUT (v4-core) — proved both signs live in
        // test/fork/V4SignConvention.t.sol, for ChipLottery.
        int256 delta = poolManager.swap(
            PoolKey({currency0: currency0, currency1: currency1, fee: poolFee, tickSpacing: tickSpacing, hooks: hooks}),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(wethOut),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT
            }),
            ""
        );
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        int128 chipDelta = chipIsCurrency0 ? amount0 : amount1;
        int128 wethDelta = chipIsCurrency0 ? amount1 : amount0;
        if (chipDelta >= 0 || wethDelta <= 0) revert NothingSwapped();

        uint256 chipOwed = uint256(uint128(-chipDelta));
        uint256 wethGot = uint256(uint128(wethDelta));
        // Exact output means exactly this.
        if (wethGot != wethOut) revert NothingSwapped();
        if (chipOwed > maxChipIn) revert ChipCostAboveMax(chipOwed, maxChipIn);

        poolManager.sync(chip);
        IERC20(chip).safeTransfer(address(poolManager), chipOwed);
        poolManager.settle();
        poolManager.take(weth, address(this), wethGot);
        return abi.encode(chipOwed);
    }
}
