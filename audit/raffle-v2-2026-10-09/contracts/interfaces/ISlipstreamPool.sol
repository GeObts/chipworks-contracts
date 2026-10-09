// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The Aerodrome Slipstream (concentrated liquidity) pool surface the Raffle reads.
/// @dev    Checked against the live Base pools 2026-10-09 (e.g. NVDAc/USDC
///         0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9): `slot0` returns SIX words — Slipstream
///         has no `feeProtocol` field, unlike Uniswap v3's seven — and `observe` is Uniswap
///         v3's oracle (tick cumulatives, one write per block on the first swap/LP change).
interface ISlipstreamPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        );

    /// @dev Reverts ("OLD") when the observation buffer does not reach `secondsAgos[i]` back.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @notice Slipstream CL factory: pools are keyed by (tokenA, tokenB, tickSpacing).
interface ISlipstreamFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address pool);
}

/// @notice The factory a Slipstream router swaps in (its `factory()` immutable).
interface ISlipstreamRouterFactory {
    function factory() external view returns (address);
}
