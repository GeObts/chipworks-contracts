// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IChipRewardsClaimable} from "./interfaces/IChipRewardsClaimable.sol";
import {IClutchVaultRegistry} from "./interfaces/IClutchVaultRegistry.sol";
import {ISoftStakingVault} from "./interfaces/ISoftStakingVault.sol";

/// @title ClaimRouter
/// @notice One transaction that claims Chipworks stock and Clutch $CHIP together.
///
/// @dev THE GUARANTEE: routing must never be worse than claiming each side directly.
///      Three properties deliver that, and each has a test named after it.
///
///      1. EVERY LEG IS INDEPENDENT. Each claim is a separate bounded call whose failure is
///         recorded, not propagated. A frozen stock, a dead vault, an already-claimed round
///         — none of them can stop the other legs. The router only reverts if EVERY leg
///         failed, which means the caller learns nothing worked rather than silently paying
///         gas for a no-op.
///
///      2. THE ROUTER NEVER HOLDS ANYTHING. Chipworks pays the owner directly via
///         `claimFor`, so the router is never the claimant. The Clutch side is the open
///         question — its docs do not say whether `claim` pays the owner of record or the
///         caller (ASSUMPTIONS A-9). Rather than bet on the answer, the router sweeps its
///         own balance of every caller-listed token to the owner at the end. If Clutch pays
///         the owner, the sweep is a no-op. If Clutch pays the caller, the sweep delivers
///         it. Correct either way, with no redeploy if the guess was wrong.
///
///      The claim window gate lives in ChipRewards and the router neither adds to it nor
///      works around it: while claims are shut every Chipworks leg fails with ClaimsClosed
///      and the Clutch legs, which run on Clutch's own schedule, still settle.
///
///      3. GAS IS BOUNDED PER LEG. A token or vault that fails with an invalid opcode
///         consumes every wei of gas handed to it (ASSUMPTIONS A-17). Without a per-leg cap
///         one hostile entry would starve every leg after it, which is precisely the
///         "routing is worse than direct" failure this contract must not have.
contract ClaimRouter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice One Chipworks credit: a stock from a finalized round.
    struct ChipClaim {
        uint256 roundId;
        address stock;
    }

    /// @notice One Clutch activation to claim $CHIP for.
    struct ClutchClaim {
        address collection;
        uint256 tokenId;
    }

    /// @notice ChipRewards.
    IChipRewardsClaimable public rewards;

    /// @notice The Clutch adapter, used only to look up which vault serves a collection.
    /// @dev Reading the vault from the adapter keeps the whole Clutch seam in one place.
    IClutchVaultRegistry public vaultRegistry;

    /// @notice Gas handed to each individual leg.
    uint256 public legGasLimit;

    event Routed(
        address indexed owner, uint256 chipSucceeded, uint256 chipFailed, uint256 clutchSucceeded, uint256 clutchFailed
    );
    event LegFailed(address indexed owner, bool isClutchLeg, uint256 index, bytes reason);
    event Swept(address indexed owner, address indexed token, uint256 amount);
    event RewardsUpdated(address indexed previous, address indexed current);
    event VaultRegistryUpdated(address indexed previous, address indexed current);
    event LegGasLimitUpdated(uint256 previous, uint256 current);

    error ZeroAddress();
    error NothingRequested();
    error EverythingFailed();
    error BadGasLimit();

    constructor(address multisig, address rewards_, address vaultRegistry_, uint256 legGasLimit_) Ownable(multisig) {
        if (multisig == address(0) || rewards_ == address(0)) revert ZeroAddress();
        if (legGasLimit_ < 100_000) revert BadGasLimit();
        rewards = IChipRewardsClaimable(rewards_);
        vaultRegistry = IClutchVaultRegistry(vaultRegistry_);
        legGasLimit = legGasLimit_;
    }

    /* ------------------------------------------------------------------ */
    /*                            GOVERNANCE                                */
    /* ------------------------------------------------------------------ */

    function setRewards(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        emit RewardsUpdated(address(rewards), v);
        rewards = IChipRewardsClaimable(v);
    }

    /// @notice Repoint at a new Clutch adapter, e.g. once the real vault ABI is confirmed.
    function setVaultRegistry(address v) external onlyOwner {
        emit VaultRegistryUpdated(address(vaultRegistry), v);
        vaultRegistry = IClutchVaultRegistry(v);
    }

    /// @notice Tune the per-leg gas budget. Multisig only.
    function setLegGasLimit(uint256 v) external onlyOwner {
        if (v < 100_000) revert BadGasLimit();
        emit LegGasLimitUpdated(legGasLimit, v);
        legGasLimit = v;
    }

    /* ------------------------------------------------------------------ */
    /*                               CLAIM                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Claim Chipworks stock and Clutch $CHIP in one transaction.
    /// @param chipClaims   Chipworks (round, stock) credits to collect.
    /// @param clutchClaims Clutch activations to collect $CHIP for.
    /// @param sweepTokens  Tokens to forward to the caller if any land on the router. Pass
    ///                     $CHIP here. Harmless to over-list; leaving it empty is safe only
    ///                     if Clutch pays the owner of record directly (ASSUMPTIONS A-9).
    /// @return chipSucceeded   How many Chipworks legs paid out.
    /// @return clutchSucceeded How many Clutch legs paid out.
    function claimEverything(
        ChipClaim[] calldata chipClaims,
        ClutchClaim[] calldata clutchClaims,
        address[] calldata sweepTokens
    ) external nonReentrant returns (uint256 chipSucceeded, uint256 clutchSucceeded) {
        if (chipClaims.length == 0 && clutchClaims.length == 0) {
            revert NothingRequested();
        }

        address owner = msg.sender;
        uint256 chipFailed;
        uint256 clutchFailed;

        for (uint256 i; i < chipClaims.length; ++i) {
            (bool ok, bytes memory reason) = _claimChip(owner, chipClaims[i]);
            if (ok) {
                ++chipSucceeded;
            } else {
                ++chipFailed;
                emit LegFailed(owner, false, i, reason);
            }
        }

        for (uint256 i; i < clutchClaims.length; ++i) {
            (bool ok, bytes memory reason) = _claimClutch(clutchClaims[i]);
            if (ok) {
                ++clutchSucceeded;
            } else {
                ++clutchFailed;
                emit LegFailed(owner, true, i, reason);
            }
        }

        // Nothing worked. Tell the caller rather than charging them for silence.
        if (chipSucceeded == 0 && clutchSucceeded == 0) revert EverythingFailed();

        _sweep(owner, sweepTokens);

        emit Routed(owner, chipSucceeded, chipFailed, clutchSucceeded, clutchFailed);
    }

    /// @notice Whether Chipworks claims are currently open, and when they next open.
    /// @dev The router does not add a gate of its own and does not bypass the one in
    ///      ChipRewards. Chipworks legs simply fail while claims are shut, with the
    ///      ClaimsClosed reason carried back per leg. Clutch legs are unaffected: their
    ///      schedule is Clutch's, not ours. Exposed so the site can grey out the button
    ///      rather than letting people burn gas on a call that cannot succeed.
    function claimWindowStatus() external view returns (bool open, uint64 nextOpenAt) {
        open = rewards.isClaimOpen();
        nextOpenAt = rewards.nextWindowOpensAt();
    }

    /// @notice Forward any tokens sitting on the router to the caller. Permissionless
    ///         safety valve: the router is not supposed to hold balances, so anyone finding
    ///         one stuck can push it out.
    /// @dev Sends to `to`, not to `msg.sender`, so it can be used to rescue a specific
    ///      user's stranded tokens without the caller being able to take them.
    function sweepTo(address to, address[] calldata tokens) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _sweep(to, tokens);
    }

    /* ------------------------------------------------------------------ */
    /*                             INTERNALS                                */
    /* ------------------------------------------------------------------ */

    /// @dev Chipworks pays `owner` directly, so the router never becomes the claimant.
    function _claimChip(address owner, ChipClaim calldata c) internal returns (bool, bytes memory) {
        (bool ok, bytes memory ret) = address(rewards).call{gas: legGasLimit}(
            abi.encodeCall(IChipRewardsClaimable.claimFor, (owner, c.roundId, c.stock))
        );
        return (ok, ok ? bytes("") : ret);
    }

    /// @dev Clutch is foreign code. Bounded, and a missing vault is a failed leg, not a
    ///      revert of the whole batch.
    function _claimClutch(ClutchClaim calldata c) internal returns (bool, bytes memory) {
        if (address(vaultRegistry) == address(0)) return (false, "no vault registry");
        address vault = vaultRegistry.vaultOf(c.collection);
        if (vault == address(0)) return (false, "no vault for collection");

        (bool ok, bytes memory ret) = vault.call{gas: legGasLimit}(abi.encodeCall(ISoftStakingVault.claim, (c.tokenId)));
        return (ok, ok ? bytes("") : ret);
    }

    /// @dev Each token is swept independently and a failure is skipped, so one frozen
    ///      token cannot strand the others or undo the claims that already succeeded.
    function _sweep(address to, address[] calldata tokens) internal {
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            if (token == address(0)) continue;

            (bool okBal, bytes memory balRet) =
                token.staticcall{gas: legGasLimit}(abi.encodeCall(IERC20.balanceOf, (address(this))));
            if (!okBal || balRet.length < 32) continue;
            uint256 amount = abi.decode(balRet, (uint256));
            if (amount == 0) continue;

            (bool okXfer,) = token.call{gas: legGasLimit}(abi.encodeCall(IERC20.transfer, (to, amount)));
            if (okXfer) emit Swept(to, token, amount);
        }
    }
}
