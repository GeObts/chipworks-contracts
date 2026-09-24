// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPrizeVault
/// @notice USDC + B20 pool that pays a Box draw. The Next.js /box page reads {inventoryUsd}
///         and {prizeCapUsd}; only {Box} may call {settle}.
interface IPrizeVault {
    /// @notice Result of one attempt to pay a drawn USD prize.
    /// @dev ALL OR NOTHING. `paid == false` means NOTHING moved and the Box records the prize
    ///      as owed (claimable later at the same size). A prize is never paid short.
    struct Payout {
        bool paid;
        uint256 requestedUsd;
        uint256 paidUsd;
        address stock;
        uint256 stockAmount;
        uint256 usdcAmount;
        bool capped;
        bool fallbackStock;
        bool usdcFallback;
    }

    function usdc() external view returns (address);
    /// @notice $CHIP. Held here only to be REFUSED as prize stock (H-01). The vault never takes CHIP in.
    function chip() external view returns (address);
    function box() external view returns (address);
    function maxPrizeBps() external view returns (uint32);
    function inventoryUsd() external view returns (uint256);
    function prizeCapUsd() external view returns (uint256);
    function stockCount() external view returns (uint256);
    function stockAt(uint256 index) external view returns (address);
    function settle(address to, uint256 prizeUsd, bytes32 entropy) external returns (Payout memory);
}
