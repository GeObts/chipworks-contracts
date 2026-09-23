// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IChipConverter
/// @notice The only place $CHIP and the Box meet. Both directions go through the live
///         $CHIP/WETH Uniswap v4 pool and the WETH/USDC v3 pool:
///           - SELL: $CHIP paid for boxes -> USDC, 5% to the fee recipient, 95% to the vault.
///           - BUY:  a CHIP-tier prize arrives as USDC escrow and leaves as $CHIP to the winner.
///         Neither direction leaves $CHIP sitting anywhere between transactions except the
///         unsold box payments, which only the keeper's {sellChip} (or a 48h recovery) moves.
interface IChipConverter {
    struct ChipPrize {
        address winner;
        uint96 usdcAmount;
        uint64 queuedAt;
        bool settled;
    }

    function chip() external view returns (address);
    function usdc() external view returns (address);
    function box() external view returns (address);
    function escrowedUsdc() external view returns (uint256);
    function chipPrize(uint256 id) external view returns (ChipPrize memory);

    /// @notice Vault-only. The vault has ALREADY transferred `usdcAmount` here.
    function queueChipPrize(address winner, uint256 usdcAmount) external returns (uint256 id);
}
