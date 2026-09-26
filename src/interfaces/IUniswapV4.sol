// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * Minimal Uniswap v4 surface — only what a single-pool exact-output swap needs.
 *
 * WRITTEN LOCALLY RATHER THAN VENDORED. v4-core pulls a large dependency tree
 * (solmate, permit2, forge-gas-snapshot) into a repo whose remappings are already
 * load-bearing for every other contract here. The five functions below are the
 * whole of what this codebase touches, and a wrong shape fails loudly in the fork
 * tests rather than silently — the v4 delta accounting reverts `CurrencyNotSettled`
 * if anything is left unbalanced, so there is no "confidently wrong number" path
 * of the kind a mis-declared view return would give.
 */

/// @notice A v4 pool's identity. `poolId = keccak256(abi.encode(PoolKey))`.
/// @dev `currency0 < currency1` is enforced by the PoolManager at initialise time, and
///      `fee` carries the dynamic-fee flag 0x800000 for hook-priced pools like $CHIP's.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/**
 * @dev FIELD ORDER IS LOAD-BEARING AND IS NOT THE OBVIOUS ONE.
 *
 *      v4-core declares `zeroForOne` FIRST. Written the intuitive way round -
 *      amount, then direction - the struct encodes as (int256,bool,uint160) and the
 *      selector for `swap` changes, so the PoolManager's dispatcher finds nothing
 *      and reverts in ~790 gas with no reason string. That looks exactly like a
 *      rejected swap and is actually a typo. Confirmed against v4-core.
 */
struct SwapParams {
    bool zeroForOne;
    /// @dev NEGATIVE is exact-input, POSITIVE is exact-output. This contract only ever
    ///      passes a positive value: the price (a lottery ticket, a Box) is an exact number of micro-USDC, so
    ///      the swap is specified by what must come OUT, never by what goes in.
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    /// @notice Take the lock and call back into `msg.sender.unlockCallback(data)`.
    function unlock(bytes calldata data) external returns (bytes memory);

    /// @notice Swap inside an unlocked callback. Returns the caller's balance delta:
    ///         packed (int128 amount0, int128 amount1), negative = owed TO the pool.
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);

    /// @notice Snapshot a currency's reserves before paying it in. The v4 settle pattern is
    ///         sync -> transfer -> settle; skipping sync makes the pool credit nothing.
    function sync(address currency) external;

    /// @notice Credit whatever arrived since {sync} against the caller's negative delta.
    function settle() external payable returns (uint256 paid);

    /// @notice Withdraw a positive delta to `to`.
    function take(address currency, address to, uint256 amount) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @notice Uniswap v3 SwapRouter02 exact-output-single, for the WETH -> USDC leg.
/// @dev Deliberately the OUTPUT form. The USDC price is exact, so the last leg is
///      specified by its output and the leg before it by that leg's input.
interface IUniswapV3ExactOutput {
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}
