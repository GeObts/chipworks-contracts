// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IActivationSource} from "../interfaces/IActivationSource.sol";
import {ISoftStakingVault} from "../interfaces/ISoftStakingVault.sol";

/// @title ClutchVaultAdapter
/// @notice Translates whatever the real Clutch Anvil soft-staking vault turns out to be
///         into the single small interface Chipworks consumes.
///
/// @dev THIS CONTRACT IS THE BLAST RADIUS. Every guess about Clutch's ABI lives here and
///      nowhere else, so if the real vault differs we redeploy this one small contract and
///      point ChipRewards at it — no migration of anyone's credits. See ASSUMPTIONS.md
///      A-3 through A-8.
///
///      Three things it normalises:
///
///      1. COLLECTIONS. The documented vault signatures take a bare tokenId with no
///         collection, but Chipworks runs two collections. One vault is registered per
///         collection here, so Based Noun #5 and Dark Noun #5 can never collide.
///
///      2. TIERS. Clutch tiers are an index 0..4; Chipworks needs a multiplier. The table
///         is configuration in basis points, not a constant, so a wrong guess about the
///         ordering is a multisig transaction rather than a redeploy.
///
///      3. STALE ACTIVATIONS — the important one. Clutch's docs say "anyone CAN void a
///         transferred NFT's stale activation", which reads as lazy: until somebody calls
///         `kick`, the vault may still report a sold Noun as active, earning for the
///         seller. Rather than trust that, this adapter independently checks the live
///         ERC-721 owner against the vault's owner of record and reports the Noun inactive
///         when they disagree. Costs one extra call, removes the whole class of bug, and
///         is correct whether or not Clutch voids eagerly.
contract ClutchVaultAdapter is IActivationSource, Ownable2Step {
    /// @notice Number of Clutch tiers (index 0..4).
    uint256 public constant TIER_COUNT = 5;

    /// @notice Gas cap on every call into the foreign vault.
    /// @dev A vault that reverts with an invalid opcode would otherwise consume the entire
    ///      gas budget and take the whole round down with it. See ASSUMPTIONS.md A-17.
    uint256 public constant VAULT_PROBE_GAS = 100_000;

    /// @notice collection => Clutch soft-staking vault for that collection.
    mapping(address collection => address vault) public vaultOf;

    /// @notice Tier index => multiplier in basis points. Defaults to Clutch's published
    ///         1.00 / 1.25 / 1.60 / 2.00 / 3.33.
    uint32[TIER_COUNT] public tierBps;

    event VaultSet(address indexed collection, address indexed previousVault, address indexed newVault);
    event TierBpsSet(uint256 indexed tier, uint32 previousBps, uint32 newBps);

    error ZeroAddress();
    error BadTier(uint256 tier);

    constructor(address multisig, uint32[TIER_COUNT] memory tierBps_) Ownable(multisig) {
        if (multisig == address(0)) revert ZeroAddress();
        for (uint256 i; i < TIER_COUNT; ++i) {
            tierBps[i] = tierBps_[i];
            emit TierBpsSet(i, 0, tierBps_[i]);
        }
    }

    /* ------------------------------------------------------------------ */
    /*                            GOVERNANCE                                */
    /* ------------------------------------------------------------------ */

    /// @notice Register (or replace) the Clutch vault for a collection. Multisig only.
    /// @dev Passing the zero vault de-registers the collection, which makes every Noun in
    ///      it score zero weight. That is the emergency switch if a vault misbehaves.
    function setVault(address collection, address vault) external onlyOwner {
        if (collection == address(0)) revert ZeroAddress();
        emit VaultSet(collection, vaultOf[collection], vault);
        vaultOf[collection] = vault;
    }

    /// @notice Correct the tier table once the real Clutch mapping is confirmed.
    function setTierBps(uint256 tier, uint32 bps) external onlyOwner {
        if (tier >= TIER_COUNT) revert BadTier(tier);
        emit TierBpsSet(tier, tierBps[tier], bps);
        tierBps[tier] = bps;
    }

    /* ------------------------------------------------------------------ */
    /*                          IActivationSource                           */
    /* ------------------------------------------------------------------ */

    function isSupportedCollection(address collection) external view override returns (bool) {
        return vaultOf[collection] != address(0);
    }

    /// @inheritdoc IActivationSource
    /// @dev Never reverts. An unregistered collection, a vault that fails any probe, or a
    ///      Noun whose live owner disagrees with the vault all report as simply inactive,
    ///      so one broken entry can never take a whole round down.
    function activation(address collection, uint256 tokenId)
        external
        view
        override
        returns (bool active, uint32 tierBps_, address owner)
    {
        address vault = vaultOf[collection];
        if (vault == address(0)) return (false, 0, address(0));

        (bool okActive, bytes memory activeRet) =
            vault.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(ISoftStakingVault.isActive, (tokenId)));
        if (!okActive || activeRet.length < 32 || abi.decode(activeRet, (uint256)) == 0) {
            return (false, 0, address(0));
        }

        (bool okOwner, bytes memory ownerRet) =
            vault.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(ISoftStakingVault.ownerOfRecord, (tokenId)));
        if (!okOwner || ownerRet.length < 32) return (false, 0, address(0));
        address ownerOfRecord = abi.decode(ownerRet, (address));
        if (ownerOfRecord == address(0)) return (false, 0, address(0));

        (bool okTier, bytes memory tierRet) =
            vault.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(ISoftStakingVault.tierOf, (tokenId)));
        if (!okTier || tierRet.length < 32) return (false, 0, address(0));
        uint256 tier = abi.decode(tierRet, (uint256));
        if (tier >= TIER_COUNT) return (false, 0, address(0));

        // ASSUMPTIONS A-8: do not trust the vault to have been kicked. A Noun that has
        // left its owner of record earns nothing, regardless of what the vault still says.
        if (!_stillHeldBy(collection, tokenId, ownerOfRecord)) return (false, 0, address(0));

        uint32 bps = tierBps[tier];
        if (bps == 0) return (false, 0, address(0));

        return (true, bps, ownerOfRecord);
    }

    /// @inheritdoc IActivationSource
    /// @dev Clutch has no notion of custody, so the effective owner is simply the live
    ///      ERC-721 owner. A Noun deposited anywhere — a loan escrow included — reads as
    ///      owned by that contract, which is exactly why Chipworks stopped using this
    ///      implementation. See {ChipActivation}.
    function effectiveOwner(address collection, uint256 tokenId) external view override returns (address) {
        (bool ok, bytes memory ret) =
            collection.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(IERC721.ownerOf, (tokenId)));
        if (!ok || ret.length < 32) return address(0);
        return abi.decode(ret, (address));
    }

    /// @dev Gas-capped so a hostile or broken collection cannot wedge a round.
    function _stillHeldBy(address collection, uint256 tokenId, address expected) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            collection.staticcall{gas: VAULT_PROBE_GAS}(abi.encodeCall(IERC721.ownerOf, (tokenId)));
        if (!ok || ret.length < 32) return false;
        return abi.decode(ret, (address)) == expected;
    }
}
