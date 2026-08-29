// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IActivationSource
/// @notice The ONLY activation-related surface Chipworks contracts depend on.
/// @dev This exists so that the entire risk of "we guessed Clutch's ABI wrong"
///      is concentrated in one small, swappable adapter contract instead of
///      being welded into ChipRewards.
///
///      Two things it normalises that a raw vault does not:
///        1. Collections. The Clutch market is multi-collection (Based Nouns +
///           DarkNOUNs) but the documented vault signatures take a bare
///           `tokenId`. Everything here is keyed by (collection, tokenId).
///           See ASSUMPTIONS.md A-3.
///        2. Tiers. Clutch tiers are an index 0..4; Chipworks needs the numeric
///           multiplier. The adapter returns basis points (10000 = 1.00x), so
///           the tier table is configuration, never a hardcoded constant.
interface IActivationSource {
    /// @notice Full activation state for one NFT, in one call.
    /// @param collection The ERC-721 contract address.
    /// @param tokenId    The token id within `collection`.
    /// @return active    Whether the token has a live activation right now.
    /// @return tierBps   Tier multiplier in basis points (10000 = 1.00x). Zero when inactive.
    /// @return owner     Address rewards should be booked to. Zero when inactive.
    function activation(address collection, uint256 tokenId)
        external
        view
        returns (bool active, uint32 tierBps, address owner);

    /// @notice True if `collection` is one this source can answer for.
    function isSupportedCollection(address collection) external view returns (bool);
}
