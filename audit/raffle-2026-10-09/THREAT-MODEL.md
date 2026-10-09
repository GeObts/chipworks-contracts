# Raffle — threat model and known risks

## 1. Assets

| Asset | Held by the Raffle until | Tracked by |
|---|---|---|
| Prize: ERC-20 (B20 stock) or ERC-721 | settle (pushed) or `claimPrize` | `erc20PrizeEscrow[token]`, `prizeOwedTo[id]` |
| Ticket USDC | settle (pushed to payee and Pot) or `withdrawUsdc` | `usdcLiability`, `usdcOwed` |
| ETH reserve (Entropy fees) | each draw request; the leftover goes to the payee as a credit | `ethReserve`, `ethLiability`, `ethOwed` |
| Draw integrity: a uniform, unpredictable winner | — | `randomNumber`, `winningTicket`, events |

## 2. Actors and trust

| Actor | Trust | Powers |
|---|---|---|
| **Owner (the Safe, 2-of-3)** | Trusted for **prize authenticity and parameters**, NOT for custody | Create raffles (escrowing a real prize); set fee ≤ 20%, base limits, redraw timeout [1 h, 30 d], callback gas [100k, 1M], NFT switch and allow-list. **No path to escrowed value.** |
| Payee | Chosen by the owner per raffle | Receives `base` USDC and the leftover reserve. Nothing else. |
| Buyers | Untrusted | `buy` while Open. |
| Anyone | Untrusted | `requestDraw`, `settle`, `claimPrize`, `withdrawUsdc`, `withdrawEth`, top-ups. Every one of them pays only the fixed recipient. |
| Keeper (set by the owner) | Trusted for liveness only | `retryDraw`, which the owner and the raffle's payee can also call (after the snapshotted timeout, never-revealed draws only). No other power; the owner can clear it. |
| Pyth Entropy contract | Trusted, external | The only caller allowed into `_entropyCallback`. |
| Entropy provider (Pyth's Fortuna) | **Trusted for liveness and for not withholding selectively** | Knows its own contribution; reveals it. |
| StockRegistry admin (the Safe) | Trusted | Decides which tokens may be ERC-20 prizes (checked at create only). |
| Circle (USDC), Coinbase (B20 issuer) | Trusted, systemic | Can blacklist, pause or upgrade their tokens. |

## 3. Threats considered

**T1. Re-rolling a known number.** A FAILED callback means the number is public. If `retryDraw` allowed it, a losing ticket holder could ask for fresh randomness.
→ `retryDraw` requires `callbackStatus == CALLBACK_NOT_STARTED`. A FAILED callback is completed by Pyth's permissionless `revealWithCallback` with the same number. Covered by `test_retryDraw_onlyAfterTimeout_andOnlyIfNeverRevealed`, by mutant #8, and by the fork test against the real Entropy status.

**T2. Number knowable off chain before it lands on chain.** Fortuna serves a revelation once its reveal delay has passed, even while the request is still unrevealed on chain. If that state outlasted the redraw timeout, whoever can call `retryDraw` could read a losing number from Fortuna and retry.
→ Since v1.2 a ticket holder cannot call `retryDraw` at all: only the owner, the raffle's payee or the keeper can. Seeing a reveal in a mempool therefore no longer enables a re-roll. The remaining exposure is the owner, payee or keeper choosing to retry. That is a trust assumption on the house, which is already trusted for prize authenticity, and it is mitigated operationally:
- `redrawTimeout` is **24 h** at launch.
- The keeper completes any draw still pending after 2 min with `revealWithCallback`. It reads the number from Fortuna, or from Entropy's `Revealed` event for a FAILED callback.
- An alert (and `/health` 503) fires if a draw stays pending for more than 15 min.
- Anyone, not just our keeper, can call `revealWithCallback`.

Observed Base reveal latency is a few seconds. See KEEPER.md.

**T3. Provider withholding.** The provider knows its own contribution, and therefore the outcome, as soon as the request is mined. Our v1.2 user seed does not change that: it is mixed in, but it is public once the request is mined. A provider that withholds a reveal unfavourable to a party it colludes with forces a wait; after the 24 h snapshotted timeout, the owner, payee or keeper may request fresh randomness. Only the provider can create this situation, because nobody else knows the contribution.
→ This is an **accepted trust assumption** in Pyth Entropy and is shared by every Entropy integrator. The 15-min alert makes any withholding visible long before the 24 h window. The owner can lengthen the window to 30 days.

**T4. Last buyer steering the draw.** The request happens inside the final `buy`, after all tickets are fixed, and the number is unknown at that point. The last buyer chooses only whether to buy. After the request no state can change (no buys, refunds or cancels).

**T5. Callback failure.** A revert would mark the request FAILED. The callback accepts only `msg.sender == entropy`. For an unknown or stale key, or a mismatched state, sequence or provider, it emits `OrphanCallback` and returns. Otherwise it does three writes and the modulo. It measures about 26k gas against a 200k limit (rounded to 500k by the provider).

**T6. Last-buyer gas griefing.** The final `buy` wraps the Entropy calls in `try/catch`. A buyer who supplies just enough gas for the outer call can make `requestV2` fail inside the try. The raffle then stays `SoldOut` with its reserve intact, and anyone calls `requestDraw`. This is a liveness delay only, covered by `test_buy_entropyOutage_lastBuyStillSucceeds` and the fee-spike test.

**T7. A refused recipient freezes others.** B20 and USDC refuse sanctioned addresses. Settle pushes each leg independently through `_tryTransfer`, and a refusal becomes a credit for that recipient alone. Covered by `test_settle_refused*` and by the invariant suite's blacklist toggling.

**T8. Reentrancy.** Every state-changing external function is `nonReentrant` and follows checks-effects-interactions: credits are zeroed before transfer and settle sets the state first. ERC-721 is never pushed during settle. Covered by `test_reentrancy_prizeTokenCannotReenter`.

**T9. Owner abuse or Safe compromise.** A compromised Safe can:
- create raffles with a worthless prize (an ERC-721 only once it enables NFTs and allow-lists a collection; an ERC-20 only once it enables the token in the registry, which the same Safe owns);
- set the fee to 20% and the timeout to [1 h, 30 d] (since v1.2 snapshotted per raffle, so only future raffles change);
- name a keeper, or itself retry a never-revealed draw after its timeout (T2);
- set callback gas up to 1M (raises the fee a live `requestDraw` needs; anyone can top up).

It cannot take escrowed prizes, USDC or reserves, or change a live raffle's fee, ticket count, payee or redraw timeout. `test_ownerHasNoPathToEscrow`, `test_retryDraw_timeoutSnapshottedAtCreation` and mutants #16, #22, #31–33 cover this.

**T10. Fee-on-transfer or rebasing prize.** Escrow measures the balance delta and requires the exact amount (`test_create_rejectsFeeOnTransferPrize`, mutant #18). Prizes are limited to registry-enabled B20s.

**T11. Unbounded loops or gas DoS.** None. Buying is one slot per purchase. Settle is an O(log P) binary search, measured at 139,680 gas for 2,003 purchases / 11,000 tickets.

**T13. Seed quality (v1.2).** `_drawSeed` mixes the contract, raffle, a per-request nonce, sold count, last buyer, previous blockhash, prevrandao and timestamp. It is not secret and does not need to be: the result is `keccak(seed, providerRevelation, 0)`, and the provider's revelation is committed before the request and unknown until reveal. The nonce guarantees that two requests never share a seed (`test_draw_everyRequestGetsADistinctSeed`). The sequencer can influence prevrandao and timestamp, but not the provider's revelation, so it cannot steer the result.

**T12. Modulo bias.** `rnd % N` with N ≤ 1.2M gives bias below N/2^256. It is negligible.

## 4. Known and accepted risks

| # | Risk | Status |
|---|---|---|
| **R1** | **No refund, so funds can be locked indefinitely.** A raffle that never sells out keeps every buyer's USDC, the prize and the reserve escrowed forever. No deadline, cancel, refund, expiry, pause or admin exit exists. | **Accepted by the owner (2026-10-08).** Mitigations are UX only: progress bars, explicit "no refund" disclosure, $10–$1,000 caps, featuring near-complete raffles. Only the house creates, so it controls which raffles exist. |
| R2 | A custody bug with no exit path traps everything. | Non-upgradeable; small launch caps; invariant fuzzing; mutation testing; external audit(s) before mainnet. |
| R3 | A sanctioned or blacklisted **winner** can never receive the prize (`claimPrize` reverts while refused). The prize stays escrowed for them indefinitely. | Accepted. Other legs are unaffected. |
| R4 | A payee that rejects ETH leaves its `ethOwed` (about 0.00003 ETH per raffle) unwithdrawable. | Accepted and documented in NatSpec (v1.2): the payee must be an EOA or a contract that can receive ETH. The house chooses it. |
| R5 | Provider liveness and honesty (T2, T3). | Accepted trust in Pyth; keeper plus alerting; owner-adjustable timeout. |
| R6 | B20 pause or policy change by the issuer. | The prize stays claimable once transfers resume. Disclosed. |
| R7 | USDC upgrade, or freezing of the Raffle address. | Systemic; same exposure as every USDC protocol. |
| R8 | Prize value vs ticket total is not enforced on chain. | Owner-only creation. The UI shows the prize's live value. |
| R9 | **No rescue.** Tokens or ETH sent to the contract outside the flows are unrecoverable. | Accepted (no admin path to funds is the stronger property). |
| R10 | ERC-721 released with `transferFrom` (by design, documented) may land in a contract that cannot use it. | NFT prizes are off at launch; revisit before enabling. |
| R11 | A never-revealed draw can only be retried by the owner, the payee or the keeper (v1.2). If all three are unavailable it waits. | Accepted: a liveness dependency on the Safe, not a custody risk. |
| R12 | Legal: paid-entry raffles are gambling in many jurisdictions. | Owner and legal, outside the code. |

## 5. Invariants we assert (and want challenged)

1. `usdc.balanceOf(raffle) == usdcLiability == Σ unsettled sold × 1e6 + Σ usdcOwed`, to the unit.
2. USDC is conserved across buyers, payee, Pot and the Raffle: none is created or lost.
3. `address(raffle).balance == ethLiability == Σ ethReserve + Σ ethOwed`, to the wei.
4. For each prize token: `balanceOf(raffle) == erc20PrizeEscrow[token]`, the sum of escrowed plus owed prizes.
5. `sold ≤ N`. Any state at or past `SoldOut` has `sold == N`. When drawn, `winningTicket == rnd % N` and `winner == buyerOf(winningTicket)`.
