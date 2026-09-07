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
///         router is never the claimant — see `ChipClaims._claim`, which credits the `owner`
///         argument and never `msg.sender`. {sweepTo} exists only for something that arrives
///         here by accident, and it is **multisig-only**. External review SEC-RTR-001 found
///         it permissionless while its own comment claimed a caller could not take what it
///         moved; both halves of that are fixed below, and the comment mattered as much as
///         the modifier.
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
///
///      A NOTE THE CALLER HAS TO GET RIGHT, AND THE CONTRACT CANNOT (SEC-RTR-003).
///
///      Each leg is given `legGasLimit`, but EIP-150 hands a subcall at most 63/64 of the gas
///      remaining at that moment. Send too little gas overall and the later legs receive less
///      than their budget, fail for that reason alone, and are recorded as `LegFailed` — a
///      **valid credit reported as failed**. The credit itself is untouched and stays
///      claimable, so nothing is lost but the caller's gas and their confidence in the
///      readout.
///
///      This cannot be fixed here without making it worse. Reverting on low gas would throw
///      away the legs that already succeeded, and stopping early would silently do less than
///      was asked. So it is the caller's job: **estimate `claims.length × (legGasLimit +
///      30_000)`** and send at least that. `MAX_CLAIMS` bounds the array so that number stays
///      computable, and `legGasLimit` is readable on chain so an SDK never has to hardcode
///      it. See SITE_CLAIM_API.md.
contract ClaimRouter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice One Chipworks credit: a stock from a finalized round.
    struct ChipClaim {
        uint256 roundId;
        address stock;
    }

    /// @notice ChipClaims — the ledger. `claimFor` lives there, not on the engine.
    IChipRewardsClaimable public rewards;

    /// @notice Largest batch {claimEverything} will accept.
    /// @dev External review SEC-RTR-004. The array was unbounded, so the only thing stopping
    ///      a caller building a batch that cannot fit in a block was the caller. A cap does
    ///      not make a big batch cheap — at `legGasLimit` of 1,000,000 even 100 legs is more
    ///      than a Base block can reserve — but it makes the worst case a knowable number
    ///      instead of an open question, and it is what lets the gas formula above be
    ///      written down at all. **The practical limit is lower and gas-driven**; the site
    ///      should batch in tens, not hundreds.
    uint256 public constant MAX_CLAIMS = 100;

    /// @notice Gas handed to each individual leg.
    uint256 public legGasLimit;

    event Routed(address indexed owner, uint256 succeeded, uint256 failed);
    event LegFailed(address indexed owner, uint256 index, bytes reason);
    event Swept(address indexed to, address indexed token, uint256 amount);
    event RewardsUpdated(address indexed previous, address indexed current);
    event LegGasLimitUpdated(uint256 previous, uint256 current);

    error ZeroAddress();
    error NothingRequested();
    /// @notice More than {MAX_CLAIMS} credits in one batch. SEC-RTR-004.
    error TooManyClaims(uint256 requested, uint256 max);
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
    /// @dev Send `claims_.length * (legGasLimit + 30_000)` gas or better. A leg starved of
    ///      gas is recorded as failed even though the credit is fine — see the note on this
    ///      contract, SEC-RTR-003.
    function claimEverything(ChipClaim[] calldata claims_) external nonReentrant returns (uint256 succeeded) {
        if (claims_.length == 0) revert NothingRequested();
        if (claims_.length > MAX_CLAIMS) revert TooManyClaims(claims_.length, MAX_CLAIMS);

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

    /// @notice Forward tokens sitting on the router to `to`. **Multisig only.**
    ///
    /// @dev The router is not supposed to hold a balance at any point — `claimFor` pays the
    ///      owner directly and the router is never the claimant — so this exists only for
    ///      something that arrived by accident.
    ///
    ///      SEC-RTR-001: THIS USED TO BE PERMISSIONLESS, AND THE COMMENT ABOVE IT WAS FALSE.
    ///      It said sending to `to` rather than `msg.sender` meant a caller could not take
    ///      what it moved. A caller passes its own address as `to`; that is the whole of it.
    ///      Anything stranded here was a public bounty, and the person who lost it would
    ///      almost certainly lose the race to recover it.
    ///
    ///      Fixed by making it owner-only rather than by rewording. Permissionless recovery
    ///      is only better than multisig recovery if the victim can be sure of winning, and
    ///      they cannot; owner-only means the multisig can return a misdirected transfer to
    ///      the person who actually made it. It also matches every other rescue in this repo
    ///      — `Anvil.recoverExcess`, `POLTreasury.recoverExcess`, `Furnace.recoverNFT` — so
    ///      there is now one rule for accidental deposits across the protocol rather than an
    ///      exception here that a reviewer has to hold in their head.
    ///
    ///      There is nothing to trust the multisig with that it does not already have: no
    ///      normal path puts a token on this contract.
    function sweepTo(address to, address[] calldata tokens) external onlyOwner nonReentrant {
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
    ///
    ///      SEC-RTR-002: `Swept` USED TO MEAN "THE CALL DID NOT REVERT". A token that returns
    ///      `false` instead of reverting — the ERC-20 spec permits it and real tokens do it —
    ///      produced an event saying a balance had moved when it had not. An event that lies
    ///      is worse than no event: it is what an indexer, a support ticket and an incident
    ///      timeline are all built on.
    ///
    ///      Fixed by booking the measured delta rather than the return value, which is the
    ///      same rule `ConversionRoutes` and `ChipRounds` already follow for every value that
    ///      moves in this protocol. It is stronger than the boolean check the finding asked
    ///      for, because a token can return `true` and still move nothing.
    ///
    ///      Precisely: the amount booked is what left THIS CONTRACT, not what landed at
    ///      `to`. For a fee-on-transfer token those differ and the event reports the larger
    ///      figure. That is the honest reading of a sweep — the router is saying what it gave
    ///      up — and measuring the recipient instead would mean trusting a second balance on
    ///      an address we know nothing about. `Swept` is not emitted at all when nothing left.
    function _sweep(address to, address[] calldata tokens) internal {
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            if (token == address(0)) continue;

            uint256 before = _balanceOfSelf(token);
            if (before == 0) continue;

            (bool okXfer,) = token.call{gas: legGasLimit}(abi.encodeCall(IERC20.transfer, (to, before)));
            if (!okXfer) continue;

            uint256 remaining = _balanceOfSelf(token);
            // A token whose balance grew, or which stopped answering, is not one to book.
            if (remaining >= before) continue;

            emit Swept(to, token, before - remaining);
        }
    }

    /// @dev Gas-capped, and returns zero rather than reverting for anything that will not
    ///      answer — a token that cannot be read is one this loop skips, not one that stops
    ///      the sweep. Per ASSUMPTIONS A-17.
    function _balanceOfSelf(address token) internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            token.staticcall{gas: legGasLimit}(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }
}
