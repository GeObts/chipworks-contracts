// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IChipRewardsClaimable} from "./interfaces/IChipRewardsClaimable.sol";

/// @title ClaimRouter
/// @notice One transaction that collects every Chipworks credit a holder has.
///
/// @dev THE CLUTCH LEG IS GONE, AND THAT IS THE HEADLINE CHANGE.
///
///      This contract used to claim a second time against a Clutch soft-staking vault, on
///      the assumption that `claim(tokenId)` would pay the owner of record whoever called
///      it. On-chain recon settled that it does not: Clutch's `claim` is permissioned to the
///      owner of record and reverts `NotOwner()` for anybody else, so a router calling it
///      from its own address could never have worked (CLUTCH_RECON section 4). The leg
///      degraded safely — every leg was independently failable — but it degraded to nothing
///      on every single call, which is a feature that does not exist rather than one that
///      sometimes fails.
///
///      Chipworks now runs its own activation vault, {ChipActivation}, and there is no
///      second reward stream to collect: activation is a cost that burns, not a position
///      that accrues. So "claim everything" means exactly what it says with one leg, and the
///      router needs no vault registry, no foreign-vault ABI, and no guess about who a
///      third party pays. Claiming is `ChipClaims.claimFor`, which is permissionless and
///      always pays the owner — there is no special case left to handle.
///
///      WHAT SURVIVES, because it was never about Clutch:
///
///      1. EVERY LEG IS INDEPENDENT. Each claim is a separate bounded call whose failure is
///         recorded, not propagated. A frozen stock or an already-claimed round cannot stop
///         the others. The router reverts only if EVERY leg failed, so the caller learns
///         nothing worked rather than silently paying gas for a no-op.
///
///      2. THE ROUTER NEVER HOLDS ANYTHING. `claimFor` pays the owner directly, so the
///         router is never the claimant. {sweepTo} remains as a permissionless safety valve
///         for anything that lands here by accident; it is not part of any normal path.
///
///      3. GAS IS BOUNDED PER LEG. A token that fails with an invalid opcode consumes every
///         wei of gas handed to it (ASSUMPTIONS A-17). Without a per-leg cap one hostile
///         entry would starve every leg after it, which is precisely the "routing is worse
///         than direct" failure this contract must not have.
///
///      The claim window gate lives in `ChipClaims` and the router neither adds to it nor
///      works around it: while claims are shut every leg fails with `ClaimsClosed`, and
///      {claimWindowStatus} exists so the site can grey out the button instead of letting
///      people burn gas on a call that cannot succeed.
contract ClaimRouter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice One Chipworks credit: a stock from a finalized round.
    struct ChipClaim {
        uint256 roundId;
        address stock;
    }

    /// @notice ChipClaims — the ledger. `claimFor` lives there, not on the engine.
    IChipRewardsClaimable public rewards;

    /// @notice Gas handed to each individual leg.
    uint256 public legGasLimit;

    event Routed(address indexed owner, uint256 succeeded, uint256 failed);
    event LegFailed(address indexed owner, uint256 index, bytes reason);
    event Swept(address indexed to, address indexed token, uint256 amount);
    event RewardsUpdated(address indexed previous, address indexed current);
    event LegGasLimitUpdated(uint256 previous, uint256 current);

    error ZeroAddress();
    error NothingRequested();
    error EverythingFailed();
    error BadGasLimit();

    constructor(address multisig, address rewards_, uint256 legGasLimit_) Ownable(multisig) {
        if (multisig == address(0) || rewards_ == address(0)) revert ZeroAddress();
        if (legGasLimit_ < 100_000) revert BadGasLimit();
        rewards = IChipRewardsClaimable(rewards_);
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

    /// @notice Tune the per-leg gas budget. Multisig only.
    function setLegGasLimit(uint256 v) external onlyOwner {
        if (v < 100_000) revert BadGasLimit();
        emit LegGasLimitUpdated(legGasLimit, v);
        legGasLimit = v;
    }

    /* ------------------------------------------------------------------ */
    /*                               CLAIM                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Claim many Chipworks credits in one transaction.
    /// @param claims_ The (round, stock) credits to collect. Proceeds go to `msg.sender`,
    ///                who must be the owner of the credit; a credit belonging to somebody
    ///                else simply fails its leg.
    /// @return succeeded How many legs paid out.
    function claimEverything(ChipClaim[] calldata claims_) external nonReentrant returns (uint256 succeeded) {
        if (claims_.length == 0) revert NothingRequested();

        address owner = msg.sender;
        uint256 failed;

        for (uint256 i; i < claims_.length; ++i) {
            (bool ok, bytes memory reason) = _claimChip(owner, claims_[i]);
            if (ok) {
                ++succeeded;
            } else {
                ++failed;
                emit LegFailed(owner, i, reason);
            }
        }

        // Nothing worked. Tell the caller rather than charging them for silence.
        if (succeeded == 0) revert EverythingFailed();

        emit Routed(owner, succeeded, failed);
    }

    /// @notice Whether Chipworks claims are currently open, and when they next open.
    /// @dev The router does not add a gate of its own and does not bypass the one in
    ///      `ChipClaims`. Exposed so the site can grey out the button.
    function claimWindowStatus() external view returns (bool open, uint64 nextOpenAt) {
        open = rewards.isClaimOpen();
        nextOpenAt = rewards.nextWindowOpensAt();
    }

    /// @notice Forward tokens sitting on the router to `to`. Permissionless safety valve.
    /// @dev The router is not supposed to hold a balance at any point — `claimFor` pays the
    ///      owner directly and the router is never the claimant — so this exists only for
    ///      something that arrived by accident. It sends to `to` rather than to
    ///      `msg.sender`, so it can rescue a specific user's stranded tokens without the
    ///      caller being able to take them.
    function sweepTo(address to, address[] calldata tokens) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _sweep(to, tokens);
    }

    /* ------------------------------------------------------------------ */
    /*                             INTERNALS                                */
    /* ------------------------------------------------------------------ */

    /// @dev ChipClaims pays `owner` directly, so the router never becomes the claimant.
    function _claimChip(address owner, ChipClaim calldata c) internal returns (bool, bytes memory) {
        (bool ok, bytes memory ret) = address(rewards).call{gas: legGasLimit}(
            abi.encodeCall(IChipRewardsClaimable.claimFor, (owner, c.roundId, c.stock))
        );
        return (ok, ok ? bytes("") : ret);
    }

    /// @dev Each token is swept independently and a failure is skipped, so one frozen token
    ///      cannot strand the others.
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
