// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBox
/// @notice Frontend surface for the ChipWorks Box gacha. A Next.js `/box` page should
///         read these views and send users to {buyWithUsdc}, {buyWithChip} and {open}.
/// @dev UNAUDITED. Isolated from Anvil / ChipRounds. Odds the UI renders MUST come from
///      {oddsTable} / {previewDraw} on chain, never from a hardcoded copy.
interface IBox {
    struct Sku {
        bool exists;
        bool paused;
        uint96 usdcPrice;
        uint128 chipPrice;
    }

    struct PrizeTier {
        uint16 weight;
        uint32 prizeBps;
    }

    struct BoxView {
        uint8 skuId;
        uint8 state;
        address opener;
        uint64 sequence;
        uint64 openingStartedAt;
        /// @notice Face USDC price snapshotted at mint. Open/payout ignore later {executeSku}.
        uint96 faceUsd;
        /// @notice Odds-table version snapshotted at mint. Open/payout ignore later {executeOdds}.
        uint64 oddsVersion;
        /// @notice EV (USDC, 6 dp) snapshotted at mint. Surplus liability uses this, not live RTP.
        uint256 mintEvUsd;
    }

    function usdc() external view returns (address);
    function chip() external view returns (address);
    function treasury() external view returns (address);
    /// @notice Alias of {treasury}. The 5% fee recipient.
    function feeRecipient() external view returns (address);
    function vault() external view returns (address);
    function entropy() external view returns (address);

    function FEE_BPS() external view returns (uint16);
    function WEIGHT_DENOM() external view returns (uint16);
    function callbackGasLimit() external view returns (uint32);

    function sku(uint8 id) external view returns (Sku memory);
    function oddsTable() external view returns (PrizeTier[] memory);
    function oddsTierCount() external view returns (uint256);
    function rtpBps() external view returns (uint256);
    function expectedValueUsd(uint8 skuId) external view returns (uint256);
    function sealedSupply(uint8 skuId) external view returns (uint256);
    function outstandingLiabilityUsd() external view returns (uint256);

    function quoteOpenFee() external view returns (uint128);
    function previewDraw(bytes32 randomNumber, uint8 skuId)
        external
        view
        returns (uint8 tierId, uint16 weight, uint32 prizeBps, uint256 prizeUsd);
    function boxInfo(uint256 tokenId) external view returns (BoxView memory);
    function tokenIdOfSequence(uint64 sequence) external view returns (uint256);

    function buyWithUsdc(uint8 skuId, address to) external returns (uint256 tokenId);
    function buyWithChip(uint8 skuId, address to) external returns (uint256 tokenId);
    function buyWithUsdcBatch(uint8 skuId, address to, uint256 n) external returns (uint256 firstId);
    function buyWithChipBatch(uint8 skuId, address to, uint256 n) external returns (uint256 firstId);
    function open(uint256 tokenId) external payable;
    function retryOpen(uint256 tokenId) external payable;
}
