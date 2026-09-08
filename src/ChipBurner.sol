// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ChipBurner
/// @notice Owns the $CHIP token so that burning it is a REAL burn, and owns nothing else that
///         anyone can take.
///
/// @dev WHY THIS CONTRACT EXISTS. Bankr's Doppler $CHIP has no public `burn` — only an
///      owner-gated one. Until now every "burn" in this protocol was a transfer to `0xdead`:
///      unreachable, but still counted in `totalSupply`, so every aggregator overstated
///      circulating supply and the gap grew with every activation. Making this contract the
///      token's owner turns that into a true burn — `totalSupply` falls, on chain, everywhere.
///
///      THE TRAP THIS AVOIDS, WHICH IS THE WHOLE DESIGN. `transferOwnership` moves **every**
///      `onlyOwner` power, not just `burn`: `updateTokenURI`, `updateMintRate`,
///      `lockPool`/`unlockPool`, `mintInflation`, and `transferOwnership` itself. A burn-only
///      sink would therefore be a one-way door — the token's metadata could never be updated
///      again and ownership could never be moved, forever, by anyone. So this is an owner
///      **wrapper**, not a sink: burning is permissionless, and the remaining owner powers we
///      must keep pass through to the multisig.
///
///      TWO ROLES, AND THE ASYMMETRY IS THE POINT.
///        - **Anyone** may call {burnAll}. Burning is the one thing that should never need
///          permission, and it can only ever destroy this contract's own balance.
///        - **`adminOwner`** — the multisig — may call the pass-throughs. Those touch the
///          token's other admin surface. They cannot move a single $CHIP.
///
///      $CHIP IS STRUCTURALLY BURN-ONLY HERE. There is no `transfer`, no `sweep`, no rescue
///      for $CHIP, and no generic `call` to smuggle one through. The only instruction this
///      contract can give about its own $CHIP balance is "destroy it". A token that arrives
///      here is gone; the only question is when somebody calls {burnAll}.
///
///      **`mintInflation` IS DELIBERATELY NOT EXPOSED.** A permissionless burner that can also
///      mint is a contradiction, and "gated behind the multisig with an event" still means the
///      capability exists and has to be trusted. It is not here. If inflation is ever genuinely
///      needed, {transferTokenOwnership} is the escape hatch: move the token to a new wrapper
///      that implements it, deliberately and visibly. That is the reason the ownership
///      pass-through exists at all, and it is why leaving it out would have been the mistake.
contract ChipBurner is Ownable2Step, ReentrancyGuard {
    /// @notice The token this contract owns and burns.
    IERC20 public immutable chipToken;

    /// @notice Running total of $CHIP destroyed by this contract, in wei.
    /// @dev Measured, never requested — a token that under-burns or lies would otherwise
    ///      inflate the figure the site publishes. Specifically it is the SMALLER of the fall
    ///      in `totalSupply` and the fall in this contract's own balance, so it cannot be
    ///      inflated by a burn happening elsewhere in the same call, nor by tokens that merely
    ///      moved without being destroyed. See {burnAll}.
    uint256 public totalBurned;

    /// @notice How many times {burnAll} has actually destroyed something.
    uint256 public burnCount;

    event Burned(address indexed caller, uint256 amount, uint256 supplyBefore, uint256 supplyAfter);
    event TokenUriUpdated(string uri);
    event TokenOwnershipTransferred(address indexed to);

    error NothingToBurn();
    error BurnDidNotReduceSupply(uint256 before, uint256 nowSupply);
    error BurnDidNotReduceBalance(uint256 before, uint256 nowBalance);
    error PassThroughFailed(bytes reason);
    error ZeroAddress();

    /// @param multisig The `adminOwner`: may use the pass-throughs, may never move $CHIP.
    /// @param chipToken_ $CHIP. Immutable — the token this wrapper owns is not a setting.
    constructor(address multisig, address chipToken_) Ownable(multisig) {
        if (multisig == address(0) || chipToken_ == address(0)) revert ZeroAddress();
        chipToken = IERC20(chipToken_);
    }

    /* ------------------------------------------------------------------ */
    /*                        THE BURN, PERMISSIONLESS                      */
    /* ------------------------------------------------------------------ */

    /// @notice Destroy every $CHIP this contract holds. Anyone may call it.
    ///
    /// @dev Permissionless on purpose. The app's burn paths transfer $CHIP here and then this
    ///      is triggered — atomically in the same transaction, or in a batch by a keeper — and
    ///      neither should depend on a privileged caller being awake. There is no argument to
    ///      get wrong and no way to direct the outcome: it burns the whole balance, to nowhere.
    ///
    ///      VERIFIED BY THE SUPPLY, NOT BY THE RETURN VALUE. `totalSupply` is read before and
    ///      after, and the call reverts unless it actually fell. That is what makes
    ///      {totalBurned} a number the site can publish: it counts what left existence, not
    ///      what we asked to leave. A token that silently no-ops its own burn cannot quietly
    ///      turn this contract into the `0xdead` address with extra steps.
    ///
    ///      **`nonReentrant`, AND THE REASON IS THE ACCOUNTING, NOT THE FUNDS.** `burn` is a
    ///      call into a token this contract does not control, and `burned` is derived from a
    ///      `totalSupply` reading that spans it. A token that re-entered here would have its
    ///      inner call credit {totalBurned}, and then the outer call would compute its own
    ///      figure from a supply delta covering *both* burns and credit it a second time. No
    ///      $CHIP could be stolen or stranded — it is destroyed either way, and there is still
    ///      no path that moves it out — but the published number would be wrong, and that
    ///      number is the entire reason this contract exists. Slither reports this as
    ///      `reentrancy-benign`; it is benign for funds and not benign for the figure.
    ///
    ///      The guard is also the consistent choice. Everything else here refuses to trust the
    ///      token — the burn is verified by reading supply rather than believing a return
    ///      value — so relying on that same token not to re-enter would have been the one
    ///      place the contract took it at its word.
    ///
    ///      BOUNDED BY OUR OWN BALANCE AS WELL AS BY SUPPLY. `burned` is the **smaller** of
    ///      the fall in `totalSupply` and the fall in this contract's own balance. The supply
    ///      delta alone would credit us for any other burn that happened during the call;
    ///      the balance delta alone would credit us for tokens that merely moved. Taking the
    ///      lesser of the two cannot over-report in either direction, whatever the token does.
    /// @return burned How much $CHIP ceased to exist.
    function burnAll() external nonReentrant returns (uint256 burned) {
        uint256 balanceBefore = chipToken.balanceOf(address(this));
        if (balanceBefore == 0) revert NothingToBurn();

        uint256 supplyBefore = chipToken.totalSupply();
        IChipOwnable(address(chipToken)).burn(balanceBefore);
        uint256 supplyAfter = chipToken.totalSupply();
        uint256 balanceAfter = chipToken.balanceOf(address(this));

        if (supplyAfter >= supplyBefore) revert BurnDidNotReduceSupply(supplyBefore, supplyAfter);
        // A token that handed us MORE than it burned has not given anything up on our behalf.
        // Checked before the subtraction, which would otherwise underflow.
        if (balanceAfter >= balanceBefore) revert BurnDidNotReduceBalance(balanceBefore, balanceAfter);

        uint256 supplyDrop = supplyBefore - supplyAfter;
        uint256 balanceDrop = balanceBefore - balanceAfter;
        burned = supplyDrop < balanceDrop ? supplyDrop : balanceDrop;

        totalBurned += burned;
        ++burnCount;

        emit Burned(msg.sender, burned, supplyBefore, supplyAfter);
    }

    /// @notice $CHIP sitting here waiting to be destroyed.
    function pending() external view returns (uint256) {
        return chipToken.balanceOf(address(this));
    }

    /* ------------------------------------------------------------------ */
    /*                  PASS-THROUGHS, MULTISIG ONLY                        */
    /* ------------------------------------------------------------------ */

    /// @notice Update the token's metadata URI. Multisig only.
    /// @dev One of the powers `transferOwnership` swept up. Without this pass-through the
    ///      token's metadata would be frozen forever the moment this contract took ownership.
    function updateTokenUri(string calldata uri) external onlyOwner {
        _passThrough(abi.encodeWithSignature("updateTokenURI(string)", uri));
        emit TokenUriUpdated(uri);
    }

    /// @notice Hand the TOKEN's ownership to somebody else. Multisig only.
    ///
    /// @dev THE ESCAPE HATCH, AND THE REASON IT IS SAFE TO OMIT EVERYTHING ELSE. Any owner
    ///      power this wrapper does not expose — `mintInflation`, `updateMintRate`,
    ///      `lockPool` — is not lost, only made deliberate: move the token's ownership to a
    ///      contract that does expose it, in a transaction anybody can see.
    ///
    ///      It is also the thing that stops this contract being a permanent trap. Note it
    ///      transfers ownership of the TOKEN, not of this contract; this contract's own
    ///      `adminOwner` moves through `Ownable2Step` as usual.
    function transferTokenOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        _passThrough(abi.encodeWithSignature("transferOwnership(address)", newOwner));
        emit TokenOwnershipTransferred(newOwner);
    }

    /// @dev Calls the token and bubbles its revert reason rather than swallowing it.
    ///
    ///      Deliberately NOT a generic `execute(bytes)`. The whole value of this contract is
    ///      that its authority over $CHIP is enumerable from its own source: burn, and two
    ///      named admin calls. A generic call would make that unknowable, and would put
    ///      `mintInflation` back within reach of whoever holds the multisig.
    function _passThrough(bytes memory data) internal {
        (bool ok, bytes memory ret) = address(chipToken).call(data);
        if (!ok) revert PassThroughFailed(ret);
    }
}

/// @notice The owner-gated surface of Bankr's Doppler $CHIP that this wrapper uses.
/// @dev VERIFY THESE SIGNATURES AGAINST THE DEPLOYED TOKEN BEFORE HANDING IT OVER. They are
///      encoded by string here, so a mismatch is a one-line fix — but it is also a mismatch
///      that would not be discovered until the first burn, which is far too late. LAUNCH_CONFIG
///      carries the check.
interface IChipOwnable {
    function burn(uint256 amount) external;
    function updateTokenURI(string calldata uri) external;
    function transferOwnership(address newOwner) external;
}
