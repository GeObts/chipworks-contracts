// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Round lifecycle states, shared so tooling and tests can read them.
enum RoundState {
    None,
    Accumulating,
    Buying,
    Finalized
}

/// @notice A round's budget and progress. The claim schedule lives in {ChipClaims}.
struct Round {
    RoundState state;
    uint64 openedAt;
    uint64 finalizedAt;
    uint128 budget; // quote-token budget taken from the Pot
    uint128 spent; // quote token actually deployed
    uint256 totalWeight; // sum of all per-stock weights in this round
}
