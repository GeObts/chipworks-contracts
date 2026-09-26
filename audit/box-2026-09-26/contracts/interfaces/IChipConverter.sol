// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IChipConverter
/// @notice Swaps a box buyer's $CHIP to the box's exact USDC price inside the buy, through the
///         live $CHIP/WETH Uniswap v4 pool and the WETH/USDC v3 pool. Holds nothing between calls.
interface IChipConverter {
    function chip() external view returns (address);
    function usdc() external view returns (address);
    function box() external view returns (address);

    /// @notice Box-only. The Box has already moved `maxChipIn` $CHIP here from the payer. Sends
    ///         exactly `usdcOut` USDC to the Box and every unspent $CHIP and WETH back to `payer`.
    /// @param wethNeeded WETH the USDC leg needs, quoted off chain; a bound, the rest is refunded.
    /// @return chipSpent $CHIP actually spent, measured.
    function swapToUsdc(uint256 usdcOut, uint256 wethNeeded, uint256 maxChipIn, address payer)
        external
        returns (uint256 chipSpent);
}
