// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISoftStakingVault} from "../../src/interfaces/ISoftStakingVault.sol";

/// @title MockSoftStakingVault
/// @notice Test double for the Clutch Anvil soft-staking vault.
/// @dev Behavioural model, mirroring the documented Clutch semantics:
///        - `activate` records (tier, ownerOfRecord = msg.sender) for a tokenId.
///        - re-`activate` at a higher tier is an upgrade; downgrades revert.
///        - `kick` clears the activation IFF the NFT has left the owner of record.
///        - `claim` pays out whatever reward tokens the test has seeded.
///      One vault instance per collection, matching ASSUMPTIONS.md A-3.
contract MockSoftStakingVault is ISoftStakingVault {
    using SafeERC20 for IERC20;

    struct Activation {
        bool active;
        uint8 tier;
        address ownerOfRecord;
        uint64 activatedAt;
    }

    IERC721 public immutable collection;

    mapping(uint256 tokenId => Activation) internal _activations;
    mapping(uint256 tokenId => address[]) internal _rewardTokens;
    mapping(uint256 tokenId => mapping(address token => uint256)) internal _rewardAmounts;

    event Activated(uint256 indexed tokenId, uint8 tier, address indexed ownerOfRecord);
    event Kicked(uint256 indexed tokenId, address indexed by);
    event Claimed(uint256 indexed tokenId, address indexed to);

    error NotOwner();
    error InvalidTier();
    error NotADowngrade();
    error StillHeld();
    error NotActive();

    constructor(IERC721 collection_) {
        collection = collection_;
    }

    /* ------------------------------ ISoftStakingVault ----------------------------- */

    function activate(uint256 tokenId, uint8 tier) external override {
        if (tier > 4) revert InvalidTier();
        if (collection.ownerOf(tokenId) != msg.sender) revert NotOwner();

        Activation storage a = _activations[tokenId];
        if (a.active && a.ownerOfRecord == msg.sender && tier <= a.tier) revert NotADowngrade();

        a.active = true;
        a.tier = tier;
        a.ownerOfRecord = msg.sender;
        a.activatedAt = uint64(block.timestamp);
        emit Activated(tokenId, tier, msg.sender);
    }

    function claim(uint256 tokenId) external override {
        Activation storage a = _activations[tokenId];
        if (!a.active) revert NotActive();
        address to = a.ownerOfRecord;

        address[] storage toks = _rewardTokens[tokenId];
        for (uint256 i; i < toks.length; ++i) {
            uint256 amt = _rewardAmounts[tokenId][toks[i]];
            if (amt != 0) {
                _rewardAmounts[tokenId][toks[i]] = 0;
                IERC20(toks[i]).safeTransfer(to, amt);
            }
        }
        delete _rewardTokens[tokenId];
        emit Claimed(tokenId, to);
    }

    function kick(uint256 tokenId) external override {
        Activation storage a = _activations[tokenId];
        if (!a.active) revert NotActive();
        if (collection.ownerOf(tokenId) == a.ownerOfRecord) revert StillHeld();
        delete _activations[tokenId];
        emit Kicked(tokenId, msg.sender);
    }

    function pendingRewards(uint256 tokenId)
        external
        view
        override
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        tokens = _rewardTokens[tokenId];
        amounts = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            amounts[i] = _rewardAmounts[tokenId][tokens[i]];
        }
    }

    function isActive(uint256 tokenId) external view override returns (bool) {
        return _activations[tokenId].active;
    }

    function tierOf(uint256 tokenId) external view override returns (uint8) {
        return _activations[tokenId].tier;
    }

    function ownerOfRecord(uint256 tokenId) external view override returns (address) {
        return _activations[tokenId].ownerOfRecord;
    }

    /* --------------------------------- test hooks --------------------------------- */

    /// @notice Force an activation into any shape a test needs, bypassing the rules.
    function setActivation(uint256 tokenId, bool active, uint8 tier, address ownerOfRecord_) external {
        _activations[tokenId] = Activation({
            active: active, tier: tier, ownerOfRecord: ownerOfRecord_, activatedAt: uint64(block.timestamp)
        });
    }

    /// @notice Seed claimable Clutch-side rewards. Caller must fund this contract with `token`.
    function setPendingReward(uint256 tokenId, address token, uint256 amount) external {
        address[] storage toks = _rewardTokens[tokenId];
        bool found;
        for (uint256 i; i < toks.length; ++i) {
            if (toks[i] == token) {
                found = true;
                break;
            }
        }
        if (!found) toks.push(token);
        _rewardAmounts[tokenId][token] = amount;
    }

    function activationOf(uint256 tokenId) external view returns (Activation memory) {
        return _activations[tokenId];
    }
}
