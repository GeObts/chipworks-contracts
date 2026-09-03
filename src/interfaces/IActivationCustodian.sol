// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IActivationCustodian
/// @notice What a contract must expose to hold a Noun on someone's behalf without that Noun
///         losing its activation.
///
/// @dev THIS IS THE WHOLE REASON CHIPWORKS RUNS ITS OWN ACTIVATION VAULT.
///
///      Soft staking means the NFT never leaves the owner's wallet, and the activation is
///      void the moment it does. That rule is correct for a sale and wrong for a deposit:
///      an owner who locks their Noun as loan collateral has not sold it, and should not
///      stop earning. A third-party vault cannot tell the two apart, because from the
///      collection's point of view both are just `ownerOf` changing.
///
///      {ChipActivation} resolves it with an allowlist. When `ownerOf` is a registered
///      custodian, the effective owner is whatever that custodian names as the beneficiary,
///      and the activation survives. When it is anything else — a buyer, an unregistered
///      contract, a marketplace escrow — the activation resets.
///
///      TRUST MODEL. A custodian is trusted, but only over the tokens it actually holds:
///      {ChipActivation} asks the address `ownerOf` returned and no other, so a hostile
///      custodian can only misdirect rewards for Nouns already in its own custody, which it
///      could withhold anyway. It cannot name a beneficiary for a token it does not hold,
///      and it cannot affect any other collection. Registration is multisig-only and
///      revocable immediately; revoking resets every activation that custodian was holding.
interface IActivationCustodian {
    /// @notice Who is the real owner of `tokenId`, for a token this contract holds.
    /// @dev MUST return the address the deposit is held for. MUST return the zero address
    ///      for a token this contract does not hold on anyone's behalf — that reads as "no
    ///      effective owner" and resets the activation, which is the safe direction.
    ///      MUST NOT revert; {ChipActivation} gas-caps the call and treats a failure as zero.
    function beneficiaryOf(address collection, uint256 tokenId) external view returns (address);
}
