# Security review round 1: response (source `5e575e5`)

Each finding, what changed, and the test that pins it. Mutant numbers refer to `tools/mutation.py`, where every listed mutant is killed.

## HIGH: Entropy randomness, no caller seed

**Finding.** `_requestDraw` and `_tryRequestDraw` call `requestV2(provider, gasLimit)` with no caller seed, so the randomness depends only on the Pyth provider.

**Fixed.** Every request now uses `requestV2(provider, userRandomNumber, gasLimit)` with `_drawSeed(raffleId, r)`:

```
keccak256(abi.encode(address(this), raffleId, ++_drawNonce, r.sold, lastBuyer,
                     blockhash(block.number - 1), block.prevrandao, block.timestamp))
```

The nonce gives every request a distinct seed, retries included. The seed is emitted as the new last field of `DrawRequested`.

**A correction to the finding's premise.** Entropy's unseeded overload does not leave the result to the provider alone. When a caller passes no seed, Entropy generates a user contribution itself. This was verified on Base: the Box's unseeded request (provider seq 584696, block 52,359,529) logged `userContribution = 0xd53cc22f…` in Entropy's `Requested` event, and its revealed number satisfies `keccak(0xd53cc22f…, providerRevelation, 0) = 0x50cf3a69…`, which is the logged result. The change is therefore defence in depth. It makes our side of the commit-reveal explicit, auditable and visible in our own event. It does not change the trust in the provider, which still knows the outcome once the request is mined and could withhold a reveal (THREAT-MODEL T3).

**Tests:**
- `test_draw_passesContractMixedSeedToEntropy` restates the seed formula independently and checks that the exact value is emitted and received by Entropy, and that the seeded overload is the only one used.
- `test_draw_everyRequestGetsADistinctSeed` covers two raffles in the same block and a retry.
- The fee-spike test checks that `requestDraw` is seeded too.
- **Base fork, real Entropy:** `test_fork_fullCycle_realEntropyRealUsdc` checks that the real Entropy's `Requested` log carries our seed.
- **Base fork, end to end with the real reveal:** `test_fork_realReveal_seedIncluded_drawCompletes` forks at block 52,359,528, so our draw is assigned the real sequence 584696. It then completes the draw with the public provider revelation through the real Entropy's permissionless `revealWithCallback`. Entropy verifies the revelation against the provider's commitment chain and runs our callback. The checks:
  - the result equals `keccak(ourSeed, revelation, 0)` and differs from the real Box number;
  - the raffle settles and pays the winner.

Mutants #24–27 cover: unseeded final buy, unseeded `requestDraw`/retry, nonce not advanced, last buyer not mixed in.

## MEDIUM: `retryDraw` griefing

**Finding.** `retryDraw` is permissionless and can be front-run to force a re-roll.

**Fixed.**
- `retryDraw` is restricted to `owner()`, the raffle's `payee`, or `keeper`. Anyone else gets `NotAuthorized(caller)`.
- `setKeeper(address)` is owner-only; zero means no keeper. The keeper has no other power.
- `redrawTimeout` is snapshotted into `RaffleData.redrawTimeout` at creation. `setRedrawTimeout` only affects later raffles, in both directions: it can neither shorten nor lengthen a live raffle's window.
- The existing guards are unchanged: a retry happens only after the timeout, and only when Entropy reports `CALLBACK_NOT_STARTED`. A FAILED callback is completed with the same number.

**Tests:**
- `test_retryDraw_onlyOwnerPayeeOrKeeper`: a ticket holder, a stranger and an unset keeper are refused; `setKeeper` is owner-only; keeper, payee and owner each succeed; clearing the keeper revokes it.
- `test_retryDraw_timeoutSnapshottedAtCreation`: both directions.
- The fork retry test: a ticket holder is refused against the real Entropy.

Mutants #28–33 cover: open to anyone, keeper dropped, payee dropped, `setKeeper` unguarded, no snapshot, retry reads the global.

**Trade-off we accept.** A draw Entropy never reveals can now only be retried by those three parties. If all three were unavailable, the draw would wait. The owner is the Safe, so this is a liveness dependency on the Safe, not a custody risk.

**Private mempool.** The reviewer asked us to confirm that keeper reveals go through a private mempool. They do not:
- The keeper (`chipworks-keeper/src/chain.ts`) sends through viem over plain HTTP to its `RPC_URL` (Alchemy). Only on a 429 or a connection failure does it fall back to `base-rpc.publicnode.com` and `mainnet.base.org`.
- There is no private, builder or "protect" endpoint.
- Flashbots Protect does not operate on Base.
- Base is an OP Stack chain with a single sequencer, and we believe its transaction pool is not publicly gossiped, but we have **not** verified that.

What matters: after this fix, seeing a reveal in any mempool no longer enables a re-roll. Front-running `retryDraw` requires being the owner, the payee or the keeper, and the keeper's code never calls `retryDraw` on a draw whose number is obtainable. It only calls `revealWithCallback` (same number) and `settle`. We therefore did not add a private-submission dependency. If the auditors want one anyway, it is a keeper configuration change (`RPC_URL`), not a contract change.

## LOW

1. **`entropy_ == address(0)` in the constructor.** Already present in the reviewed code: `usdc_ || entropy_ || registry_ || pot_` are all checked. No code change; `test_constructor_zeroAddresses` now covers each of the four addresses separately.
2. **`_tryTransfer` return data.** Fixed, slightly differently from the suggested text:
   - Suggested: `if (ret.length == 32) return abi.decode(ret,(bool)); return false;`
   - As built: `if (ret.length == 32) return abi.decode(ret, (uint256)) == 1; return false;`

   Decoding a `bool` reverts on any word other than 0 or 1, and a revert inside `settle` would block every leg of that raffle. Decoding as `uint256 == 1` gives the same answer for well-formed tokens and reads a malformed word as "refused" (credited), never a revert. Empty return data from a contract is still success, which is OpenZeppelin's convention.

   Test `test_tryTransfer_strictReturnData` covers three shapes, each of which moves nothing: two words, a word of 2, and `false`. For each, settle completes, the prize is owed rather than counted as delivered, escrow still counts it, and it is claimable once the token answers normally. Mutants #34–35 cover the old `>= 32` check and accepting any non-zero word.
3. **`minBase = 10` and `base > 0`.** `minBase` was already initialised to 10, and `setBaseLimits` already refuses 0. The explicit `base == 0` check is added anyway (`test_create_baseZero_reverts`). It cannot change behaviour, because `base == 0` always also fails `base < minBase`, so mutant #36 is a documented **equivalent**. `totalTickets ≥ base ≥ 1` therefore always holds and the callback's `% totalTickets` cannot divide by zero.

## INFORMATIONAL (documented, no behaviour change)

- **Payee and ETH.** NatSpec on `createRaffle`: the payee must be an EOA or a contract that can receive ETH, because the leftover reserve is paid by `withdrawEth` with a plain call.
- **ERC-721 release.** NatSpec on `_deliverPrize`: ERC-721 prizes use `transferFrom`, not `safeTransferFrom`, by design. No receiver hook runs in the Raffle's context, so a hostile winner contract can neither revert nor re-enter. A winner contract that cannot handle ERC-721s receives a token it cannot use, which affects only that winner. NFT prizes are off at launch.

## Also changed

- **`DeployRaffle.s.sol` comments.** Correct path to `RaffleLaunchConfig.t.sol`; decision date 2026-10-09; the keeper is now documented as a post-deploy Safe call, `setKeeper(0x6571E3412553Fada40C3D96e61E7Cfd20A0695B9)`. The launch-config fork test asserts the keeper is unset at deploy.
- **ABI changes.** `RaffleData` gains a trailing `redrawTimeout`; `DrawRequested` gains a trailing `userRandomNumber`. There is a new `KeeperSet` event and a new `NotAuthorized` error. The keeper raffle job (branch `raffle-job`, not deployed) must refresh its ABI before it is deployed.
- **Gas.** The last buy (including the Entropy request) is 226,965 gas, up from 203,044; the increase is the seed and the nonce write. Runtime size is 16,332 bytes, leaving 8,244 under EIP-170.
