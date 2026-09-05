// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Uniswap v3 factory, keyed by fee tier.
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @notice Aerodrome Slipstream (concentrated liquidity) factory, keyed by tick spacing.
interface ISlipstreamFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address pool);
}

/// @notice Aerodrome's Voter, the registry that says which gauge is canonical for a pool.
/// @dev This is the discriminator H-01 turns on. A gauge address by itself proves nothing —
///      anyone can deploy a contract with a `deposit(uint256)`. `voter.gauges(pool)` is the
///      only on-chain statement that a given gauge is *the* gauge for a given pool, and the
///      pool in turn is derived from the position, not from the caller.
interface IAerodromeVoter {
    function gauges(address pool) external view returns (address);
}

/// @notice The one field of a concentrated-liquidity pool's `slot0` we need: its price.
/// @dev Read by staticcall and decoded as a single word rather than through this interface,
///      because Uniswap v3 and Slipstream disagree about the later fields of the tuple and
///      agree about the first. Declared here for documentation.
interface IPoolPrice {
    function slot0() external view returns (uint160 sqrtPriceX96);
}
