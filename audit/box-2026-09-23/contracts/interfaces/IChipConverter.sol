// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IChipConverter
/// @notice Where the $CHIP boxes are paid in becomes prize-pool USDC: sold through the live
///         $CHIP/WETH Uniswap v4 pool and the WETH/USDC v3 pool, 5% of the USDC to the Box's
///         fee recipient and 95% to the vault. Prizes are never paid in $CHIP.
interface IChipConverter {
    function chip() external view returns (address);
    function usdc() external view returns (address);
    function box() external view returns (address);
}
