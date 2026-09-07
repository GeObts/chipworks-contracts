# SITE_CLAIM_API.md — batching claims through the router, and the gas you must send

Everything the claim SDK needs to call `ClaimRouter.claimEverything` without reporting a
working credit as broken. **There is one thing the contract cannot get right for you** and it
is the gas estimate; the rest is bookkeeping.

Contract: `ClaimRouter`, `launch-candidate-13`.

---

## The one that will bite you

```
gasLimit >= claims.length * (legGasLimit + 30_000)
```

Read `legGasLimit()` from the contract. Do not hardcode it — it is a multisig-tunable number
with a 100,000 floor, and it launches at 1,000,000.

**Why.** Each leg is dispatched with `call{gas: legGasLimit}`, but EIP-150 gives a subcall at
most 63/64 of the gas remaining *at that moment*. Send a total that is too tight and the later
legs receive less than their budget, run out inside `ChipClaims`, and come back as failures.
The router cannot tell that apart from a genuinely bad credit, so it emits `LegFailed` and the
user is told a claim they own does not work.

**Nothing is lost when this happens.** The credit is untouched and stays claimable — asserted
by `test_failedLegLeavesTheCreditClaimable`. The cost is the user's gas and their trust in the
screen. Re-running with enough gas succeeds.

This is external review SEC-RTR-003, triaged as a caller concern rather than a contract change:
reverting on low gas would throw away the legs that already succeeded, and stopping early would
silently do less than the user asked for. Both are worse than sending enough gas.

## Batch size

`MAX_CLAIMS()` is **100** and the call reverts `TooManyClaims(requested, max)` above it.

**Treat 100 as a ceiling, not a target.** At the launch `legGasLimit` of 1,000,000, a hundred
legs asks for more gas than a Base block will reserve, so the practical batch is set by the gas
formula above and not by the cap. **Batch in tens.** A reasonable default is 20–25 per
transaction, which lands around 20–25M of requested budget while typically *using* far less,
since a successful `claimFor` costs nothing like its ceiling.

If a user has more than one batch of credits, send several transactions. Each is independent
and a failure in one does not affect another.

## The calls

```solidity
function claimEverything(ChipClaim[] calldata claims_) external returns (uint256 succeeded);
struct ChipClaim { uint256 roundId; address stock; }

function claimWindowStatus() external view returns (bool open, uint64 nextOpenAt);
function legGasLimit() external view returns (uint256);
function MAX_CLAIMS() external view returns (uint256);
```

## Reading the result

| Signal | Meaning |
|---|---|
| returns `succeeded` | how many legs paid out |
| `Routed(owner, succeeded, failed)` | one per call, the summary |
| `LegFailed(owner, index, reason)` | one per failed leg; `index` is the position in the array you sent |
| reverts `EverythingFailed()` | nothing worked — the caller is told rather than charged for silence |
| reverts `NothingRequested()` | empty array |
| reverts `TooManyClaims(n, max)` | over `MAX_CLAIMS` |

`LegFailed.reason` is the raw revert data from `ChipClaims`. Decode it before showing anything
to a user: `ClaimsClosed`, `RoundNotFinalized`, `CreditsExpired` and "nothing to claim" all read
very differently to a person, and an undecoded blob reads as a bug in the site.

## Before you let anyone press the button

Call `claimWindowStatus()`. While claims are shut **every leg fails** with `ClaimsClosed` and
the whole call reverts `EverythingFailed` — the router does not add a gate of its own and does
not work around the one in `ChipClaims`. Grey the button out and show `nextOpenAt` instead of
letting people pay gas to be told no.

## Don'ts

- **Don't send `claims.length * legGasLimit`.** That is the floor for the legs alone with
  nothing left for the loop, the events, or the 1/64 EIP-150 keeps back. The `+ 30_000` per leg
  is what makes it hold.
- **Don't hardcode `legGasLimit` or `MAX_CLAIMS`.** Both are readable; one is tunable.
- **Don't treat `LegFailed` as "this credit is gone".** It is still claimable, and the most
  likely cause is your gas estimate.
- **Don't retry a whole batch on partial failure.** The legs that succeeded have been paid;
  re-sending them just burns gas failing on "nothing to claim". Retry only the indices that
  came back in `LegFailed`.
- **Don't expect `sweepTo` to be callable.** It is multisig-only (SEC-RTR-001) and is not part
  of any user flow — the router never holds a balance, because `claimFor` pays the owner
  directly.
