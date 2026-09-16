// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPrizeVault
/// @notice B20 / USDC inventory that settles a Box draw. The Next.js /box page reads
///         {inventoryUsd} and {prizeCapUsd}; only {Box} may call {settle}.
interface IPrizeVault {
    /// @notice Result of one attempt to pay a drawn USD prize.
    /// @dev `requestedUsd` is the odds-table draw. `payableUsd` is after the vault cap.
    ///      `paidUsd` is what actually left. `shortfall` means we could not pay `payableUsd`.
    struct Payout {
        uint256 requestedUsd;
        uint256 payableUsd;
        uint256 paidUsd;
        address stock;
        uint256 stockAmount;
        uint256 usdcAmount;
        bool capped;
        bool shortfall;
        bool fallbackStock;
        bool usdcFallback;
    }

    function usdc() external view returns (address);
    function box() external view returns (address);
    function maxPrizeBps() external view returns (uint32);
    function inventoryUsd() external view returns (uint256);
    function prizeCapUsd() external view returns (uint256);
    function stockCount() external view returns (uint256);
    function stockAt(uint256 index) external view returns (address);
    function quoteTokenAmount(address token, uint256 prizeUsd) external view returns (uint256);

    function settle(address to, uint256 prizeUsd, bytes32 entropy) external returns (Payout memory);
}
