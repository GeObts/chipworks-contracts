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
