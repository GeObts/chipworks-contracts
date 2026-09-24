// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBox
/// @notice Frontend surface for the ChipWorks Box gacha. A Next.js `/box` page should
///         read these views and send users to {buyWithUsdc}, {buyWithChip}, {open} and
///         {claimOwed}.
/// @dev UNAUDITED. Isolated from Anvil / ChipRounds. Odds the UI renders MUST come from
///      {oddsTable} / {previewDraw} on chain, never from a hardcoded copy.
interface IBox {
    struct Sku {
        bool exists;
        bool paused;
        uint96 usdcPrice;
        /// @notice $CHIP accepted for this SKU (swapped to `usdcPrice` inside the buy).
        bool chipEnabled;
    }

    /// @notice One row of the odds table. Every tier pays a B20 stock (USDC if no stock can
    ///         cover it). Prizes are never paid in $CHIP.
    struct PrizeTier {
        uint16 weight;
        uint32 prizeBps;
    }

    struct BoxView {
        uint8 skuId;
        /// @notice 1 sealed, 2 opening (waiting for Entropy), 3 won but owed (see {claimOwed}).
        uint8 state;
        address opener;
        uint64 sequence;
        uint64 openingStartedAt;
        /// @notice Face USDC price snapshotted at mint. Open/payout ignore later {executeSku}.
        uint96 faceUsd;
        /// @notice Odds-table version snapshotted at mint. Open/payout ignore later {executeOdds}.
        uint64 oddsVersion;
        /// @notice EV (USDC, 6 dp) snapshotted at mint. Liability uses this until the draw.
        uint256 mintEvUsd;
        /// @notice The drawn prize, once drawn and not yet paid. Fixed: a claim pays exactly this.
        uint256 owedUsd;
    }

    function usdc() external view returns (address);
    function chip() external view returns (address);
    function treasury() external view returns (address);
    /// @notice Alias of {treasury}. The 5% fee recipient (the FeeSplitter at launch).
    function feeRecipient() external view returns (address);
    function vault() external view returns (address);
    function converter() external view returns (address);
    function entropy() external view returns (address);
    function FEE_BPS() external view returns (uint16);
    function WEIGHT_DENOM() external view returns (uint16);
    function callbackGasLimit() external view returns (uint32);
    function sku(uint8 id) external view returns (Sku memory);
    function oddsTable() external view returns (PrizeTier[] memory);
    function oddsTierCount() external view returns (uint256);
    function rtpBps() external view returns (uint256);
    function expectedValueUsd(uint8 skuId) external view returns (uint256);
    /// @notice Largest single prize a box of `skuId` can win under the current table.
    function maxPrizeUsd(uint8 skuId) external view returns (uint256);
    /// @notice Largest single prize across every SKU on sale or with boxes still outstanding.
    function maxLivePrizeUsd() external view returns (uint256);
    /// @notice True when the vault can pay this SKU's top prize in full right now.
    function isSkuCovered(uint8 skuId) external view returns (bool);
    function sealedSupply(uint8 skuId) external view returns (uint256);
    /// @notice EV of every sealed/opening box plus the exact size of every owed prize.
    function outstandingLiabilityUsd() external view returns (uint256);
    function quoteOpenFee() external view returns (uint128);
    function previewDraw(bytes32 randomNumber, uint8 skuId)
        external
        view
        returns (uint8 tierId, uint16 weight, uint32 prizeBps, uint256 prizeUsd);
    function boxInfo(uint256 tokenId) external view returns (BoxView memory);
    /// @notice The box an Entropy request belongs to. Requests are numbered per provider.
    function tokenIdOfRequest(address provider, uint64 sequence) external view returns (uint256);

    function buyWithUsdc(uint8 skuId, address to) external returns (uint256 tokenId);
    function buyWithChip(uint8 skuId, address to, uint256 wethNeeded, uint256 maxChipIn, uint256 deadline)
        external
        returns (uint256 tokenId);
    function buyWithUsdcBatch(uint8 skuId, address to, uint256 n) external returns (uint256 firstId);
    function buyWithChipBatch(
        uint8 skuId,
        address to,
        uint256 n,
        uint256 wethNeeded,
        uint256 maxChipIn,
        uint256 deadline
    ) external returns (uint256 firstId);
    function open(uint256 tokenId) external payable;
    function retryOpen(uint256 tokenId) external payable;
    function claimOwed(uint256 tokenId) external;
}
