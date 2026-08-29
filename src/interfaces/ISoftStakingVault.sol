// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISoftStakingVault
/// @notice Minimal, READ-MOSTLY view of a Clutch Anvil soft-staking vault.
///         Chipworks never writes to this contract; it only reads activation state.
///
/// @dev PROVENANCE — read ASSUMPTIONS.md before deploying against a real vault.
///      * The four mutating/reward functions below (`activate`, `claim`, `kick`,
///        `pendingRewards`) are quoted verbatim from the public Clutch docs at
///        https://anvil.clutch.market/docs (soft staking section).
///      * The three view functions below (`isActive`, `tierOf`, `ownerOfRecord`)
///        are NOT documented anywhere public. They are ASSUMED. Every one of them
///        is flagged in ASSUMPTIONS.md (A-4, A-5, A-6).
///      * Nothing in this interface has been checked against a deployed contract,
///        because as of 2026-08-27 Clutch publishes NO Base (8453) deployment —
///        only ApeChain (33139) and Robinhood Chain (4663). See ASSUMPTIONS.md A-1.
///
///      Chipworks contracts do NOT import this interface directly. They consume
///      {IActivationSource}, which an adapter implements on top of whatever the
///      real vault turns out to be. That way a wrong guess here costs one small
///      adapter redeploy, not a redeploy of ChipRewards.
interface ISoftStakingVault {
    /* ---------------------------------------------------------------------- */
    /*                    DOCUMENTED BY CLUTCH (verbatim)                     */
    /* ---------------------------------------------------------------------- */

    /// @notice Burn $CHIP to activate `tokenId` at `tier`; also upgrades, paying only the difference.
    function activate(uint256 tokenId, uint8 tier) external;

    /// @notice Claim all reward tokens accrued to `tokenId`. Any time, no lock.
    function claim(uint256 tokenId) external;

    /// @notice Anyone may void a transferred NFT's stale activation.
    function kick(uint256 tokenId) external;

    /// @notice Live view of unclaimed Clutch-side rewards for `tokenId`.
    function pendingRewards(uint256 tokenId) external view returns (address[] memory tokens, uint256[] memory amounts);

    /* ---------------------------------------------------------------------- */
    /*                      ASSUMED VIEWS (UNVERIFIED)                        */
    /* ---------------------------------------------------------------------- */

    /// @notice True if `tokenId` currently holds a live (non-kicked) activation.
    /// @dev ASSUMPTION A-4.
    function isActive(uint256 tokenId) external view returns (bool);

    /// @notice Activation tier of `tokenId`, as the raw Clutch tier index 0..4.
    /// @dev ASSUMPTION A-5. Chipworks treats an inactive token as weight zero
    ///      regardless of what this returns, so a stale tier cannot pay out.
    function tierOf(uint256 tokenId) external view returns (uint8);

    /// @notice The address recorded at activation time — Clutch's "owner of record".
    /// @dev ASSUMPTION A-6. This is NOT necessarily `IERC721.ownerOf(tokenId)`.
    function ownerOfRecord(uint256 tokenId) external view returns (address);
}
