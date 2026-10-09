# ChipWorks Raffle — v1.1 spec (as built)

**Status:** built on branch `raffle` (src/raffle/Raffle.sol), tests green, NOT deployed —
mainnet waits on external audit. v1.1 decisions (owner, 2026-10-08) override anything below:

| Decision | As built |
|---|---|
| Who creates raffles | **Owner (the Safe) only.** `createRaffle` is `onlyOwner`; there is no public create. The house is creator; it names a `payee` for the base. |
| NFT prizes | Generic `Prize{kind, token, amountOrId}` built in; ERC-721 path implemented and tested, **OFF at launch** (`nftPrizesEnabled = false`, per-collection allow-list empty). Enabling = two Safe calls. |
| Launch cap | base **$10–$1,000** per raffle; `setBaseLimits` (owner) within hard bounds [1, 1,000,000]. |
| Redraw timeout | constructor parameter, owner-adjustable within **[1 hour, 30 days]**; **launch value 24 hours** (owner, 2026-10-09) — pinned in `script/raffle/DeployRaffle.s.sol` and asserted by `test/fork/RaffleLaunchConfig.t.sol`. |
| Mutation testing | `tools/raffle/mutation.py`: **22/22 killed** (2026-10-09 confirming run), plus 1 documented equivalent (stale-callback check unreachable by construction). The first run (19/22) exposed two test gaps — fee rounding and double-paid credits — both fixed. |
| Keeper | chipworks-keeper branch `raffle-job`: completes any late draw (> 2 min) with `revealWithCallback`, requests/settles, alerts (and `/health` 503) on any draw pending > 15 min. Proven end to end on a Base fork (`tools/raffle-e2e.ts`). |
| No refund | kept: no refund/cancel/expiry/withdraw path exists in the contract. Frontend discloses (separate work). |
| Owner powers | fee (≤ 20%), base limits, redraw timeout, callback gas, NFT switch + allow-list, create. **None touches an escrowed prize, ticket money or a reserve.** No pause (creation is already owner-only, and pausing buys/draws would trap funds). |


Design only. Nothing built or deployed. Facts below were read live on Base on 2026-10-08
unless marked otherwise. The locked decisions in the brief are taken as given; where this
spec adds structure it says why.

---

## 0. One-paragraph summary

One non-upgradeable contract holds many raffles. A creator escrows a prize (v1: an amount
of an allow-listed B20 stock) and an asking price `base` in whole dollars. The raffle sells
`N = base + feeTickets` tickets at exactly 1 USDC each. There is no deadline, refund,
cancel or admin exit: everything stays escrowed until ticket N is sold. That purchase
requests Pyth Entropy, paid from an ETH reserve the creator posted at creation. The callback
only **records** the random number; a separate permissionless `settle` picks the winning
ticket by index (binary search, O(log purchases)), and credits the prize to the winner,
`base` USDC to the creator and `feeTickets` USDC to the Pot. Every credit is claimable by its
fixed recipient and can be pushed to them by anyone.

---

## 1. Pyth Entropy on Base

| Item | Value |
|---|---|
| Entropy V2 | `0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb` (708-byte proxy; same one the Box uses) |
| Default provider (today) | `0x52DeaA1c84233F7bb8C8A45baeDE41091c616506` |
| Fee, `getFeeV2(provider, gasLimit)` | 0.000015 ETH (≈$0.037) for 100k–500k gas; 0.00002 ETH (≈$0.050) at 1M |
| Real latency | Box: 410 opens to date; last 40 revealed in median 4 s, max 6 s |

**Flow (reuse the Box pattern exactly):**
1. `provider = getDefaultProvider()`, `fee = getFeeV2(provider, CALLBACK_GAS)`.
2. `sequence = requestV2{value: fee}(provider, CALLBACK_GAS)`.
3. Store `requestKey = keccak256(provider, sequence) → raffleId`, plus the provider on the
   raffle. Key by **(provider, sequence)**, never sequence alone: sequences are per provider
   and collide after a default-provider change (Box finding).
4. Entropy calls `_entropyCallback(sequence, provider, randomNumber)`. Accept only
   `msg.sender == entropy`; unknown/stale keys emit `OrphanCallback` and **return** (never revert).

**Callback gas: keep it tiny.** The callback writes `randomNumber` + state and returns
(~40–50k gas). Set `CALLBACK_GAS = 100_000` (fee floor tier). No token transfers, no search,
no external calls in the callback — so it cannot fail for any winner, token or N.

**Retry / stall paths (anyone can poke):**
- **Callback failed** (should not happen at ~50k): Pyth marks it `CALLBACK_FAILED` and
  publishes the number; anyone calls Pyth's permissionless `revealWithCallback`, which
  re-runs our callback with the **same** number. Never request fresh randomness here — a
  number that is already public must not be re-rollable.
- **Never revealed:** after `redrawTimeout` **anyone** may call `retryDraw(raffleId){value}`;
  it checks `getRequestV2(provider, sequence).callbackStatus == CALLBACK_NOT_STARTED` and
  requests again (reserve first, `msg.value` tops up). The stale request becomes an orphan.

**Is a 1-hour redraw timeout safe? Conditionally — read this before deploying.** Pyth's
docs: the provider's contribution "must be retrieved from the provider's API. This value
becomes available after the reveal delay has passed." So a draw can be **knowable off chain
(Fortuna API) while still unrevealed on chain**. If that state lasted the full timeout, a
ticket holder could read a losing number and call `retryDraw` to roll again. It is safe only
if someone always completes a revealable draw first, which anyone can do via Pyth's
permissionless `revealWithCallback` (same number). Requirements that make 1 hour safe:
1. The keeper checks every `Drawing` raffle each cycle (every 30 min today) and completes it
   with `revealWithCallback` when Fortuna serves the revelation — two chances inside 1 hour.
2. Alerting if any raffle is `Drawing` for > 15 min (the Box's reveals land in ~4 s).
Decision: launch at **24 h** with the keeper job in place — belt and braces. Two facts learned
building it: Fortuna serves a revelation only while the request is unrevealed on chain (403
otherwise), and for a FAILED callback the provider contribution is public in Entropy's
`Revealed` event (topic 0x2231996c, verified on live Base logs) — the keeper reads it there.

**Callback gas (measured on the fork):** we request 200k; the live provider **rounds the
limit up to 500k** at the same fee (0.000015 ETH). Our callback uses ~50k.
- **Keeper:** add a "stuck raffle reveals" job to the existing keeper (the Box job already
  completes stuck reveals via `revealWithCallback`); it should also call `requestDraw` and
  `settle` permissionlessly so nothing depends on a human.

---

## 2. Fair, unpredictable, uniform winner

- **Commit-reveal:** Entropy V2 is a provider commit-reveal; the number for a sequence is
  fixed by the provider's hash chain before the request and unknown to everyone until the
  reveal. We use the same request path as the Box (no extra user seed needed in v1).
- **State is frozen at request time.** The request happens in the transaction that sells
  the last ticket, so after the request there is no action left that could react to the
  revealed number (no buys, no cancel, no refund — the locked design helps here).
- **The last buyer cannot steer it:** they only decide whether to buy; the number is
  unknown when they do. Everyone else's tickets are already fixed.
- **Uniform pick:** `winningTicket = uint256(randomNumber) % N`. Modulo bias is
  < N / 2^256 (≈ 2^-236 at N = 2^20) — negligible; no rejection sampling needed.
- **Determinism:** `settle` re-derives the winner from the stored number, so anyone can
  verify it off chain from events.

---

## 3. Data model and gas at large N

```
struct Raffle {                     // one per raffleId
  address creator;                  // receives base USDC
  uint32  feeBps;                   // snapshotted at create
  uint8   state;                    // OPEN, SOLD_OUT(draw pending), DRAWING, DRAWN, SETTLED
  Prize   prize;                    // see §5 — kind, token, amount/id
  uint64  base;                     // whole USD; creator payout = base * 1e6
  uint64  totalTickets;             // N
  uint64  sold;
  uint128 ethReserve;               // wei left for Entropy
  address provider; uint64 sequence; uint64 drawRequestedAt;
  bytes32 randomNumber;             // set by callback
}
struct Purchase { address buyer; uint64 endExclusive; }   // ONE storage slot
mapping(uint256 => Purchase[]) purchases;                 // per raffle, append-only
```

- **Buying** `buy(raffleId, qty)`: check `qty <= N - sold`; `USDC.transferFrom(buyer, this,
  qty * 1e6)`; append ONE `Purchase{buyer, sold + qty}` (one new slot ≈ 22k) regardless of
  `qty`; `sold += qty`. ≈ 70–90k gas per buy, flat in qty and N. If `sold == N`, also call
  `_requestDraw` (≈ +70–90k for the last buyer only; Entropy ETH comes from the reserve,
  never from the buyer).
- **Tickets are ranges, not rows.** Buyer of ticket `t` = the purchase whose
  `[prev.endExclusive, endExclusive)` contains `t`. No per-ticket storage at all.
- **Drawing:** callback stores 32 bytes (§1).
- **Settle:** binary search over `purchases[raffleId]` — O(log P), P ≤ N. At P = 100,000
  that is 17 cold reads ≈ 36k gas. No loops over tickets or buyers anywhere.
- **Caps (launch):** `MIN_BASE = $10`, `MAX_BASE = $10,000` (N ≤ 11,000 at 10%). The data
  model works far beyond that; the cap limits exposure while unaudited behaviour is young.
- **Per-user views** come from events (`TicketsBought(raffleId, buyer, firstTicket, qty)`),
  not on-chain arrays.

**Ticket count (exact):** `feeTickets = ceil(base * feeBps / 10_000)`, `N = base +
feeTickets`. base $100 @ 1000 bps → 10 + 100 = 110. base $15 → ceil(1.5) = 2 → N = 17 (Pot
gets 11.8%, never less than feeBps). `feeBps` is capped (recommend ≤ 2_000), Safe-settable
for **new** raffles only, snapshotted per raffle.

---

## 4. Settlement, custody and security

**Settle (permissionless, after the callback):**
1. `winner = buyerOf(randomNumber % N)` (binary search).
2. Credit `prizeOwed[raffleId] → winner`, `usdcOwed[creator] += base*1e6`,
   push `feeTickets*1e6` USDC to the Pot (ours, cannot refuse) — or credit it too if you
   prefer uniformity.
3. Credit leftover `ethReserve` to the creator.
4. `state = SETTLED`. Emits everything needed to audit the draw.

**Claim vs push — recommendation: credit + claim, with permissionless push.**
Each payout is a credit with a FIXED recipient; `claimPrize(raffleId)` / `withdrawUsdc(who)`
/ `withdrawEth(who)` can be called by anyone and always pay the fixed recipient (same
pattern as the Box's `claimOwed`). Why not push inside settle:
- **B20 stocks refuse sanctioned recipients** (verified for the Box: OFAC-listed
  `0x098B…2f96` is refused by B20 policy and by Circle USDC). A pushed prize to such a
  winner would revert settle and block the creator's and the Pot's money with it.
- **USDC can blacklist the creator** — same problem on the other leg.
- **ERC-721 later:** `safeTransferFrom` to a contract winner runs their code; a reverting
  or gas-burning receiver must only hurt themselves.
Isolating every leg means one bad recipient can never freeze the others.

**Custody rules (all must hold):**
- `nonReentrant` on create, buy, requestDraw, retryDraw, settle, every claim/withdraw.
  Checks-effects-interactions: zero the credit before transferring.
- **Per-raffle isolation:** proceeds tracked per raffle; one raffle's state can never move
  another's funds. Global invariants (fuzz them): USDC balance ≥ Σ unsettled `sold*1e6` +
  Σ `usdcOwed`; per prize token, balance ≥ Σ escrowed amounts; ETH balance ≥ Σ reserves +
  Σ `ethOwed`.
- **No admin path to prize or proceeds.** The owner (Safe) may only: set `feeBps` for new
  raffles (capped), set the prize allow-list for new raffles, pause **creation** of new
  raffles. Pause must NEVER block buy-to-sellout, draw, retry, settle or claims — with no
  refund path, freezing those would trap funds. (If you want an emergency stop on `buy`,
  that is a design change against the locked brief; flag it, do not add it silently.)
- **Rescue** only of amounts ABOVE tracked liabilities (stray donations), computed from the
  invariants above — never below. Or omit rescue entirely.
- **Non-upgradeable**, `Ownable2Step`. A v2 is a new contract; old raffles finish in v1.
- **Escrow by measured delta:** record `balanceAfter - balanceBefore` for the prize, so a
  fee-on-transfer token cannot under-collateralise a raffle (B20s are not FoT; this guards
  the allow-list against future mistakes).
- **Prize allow-list:** only StockRegistry-enabled B20s in v1 (no arbitrary ERC-20s: no
  scam tokens, rebasing, hooks or FoT). Read the registry at create time.
- **Pot address:** immutable (`0x3918…855B`) or Safe-settable for NEW raffles only and
  snapshotted per raffle.

**Griefing:**
- *Creator self-buy:* allowed and harmless to others — they pay the 10% to the Pot to
  "win back" their own prize. Odds stay uniform for every ticket.
- *Spam raffles:* each costs a real prize + ETH reserve + gas; a raffle that never fills
  only locks the spammer's own prize. Add `MIN_BASE` and UI filtering. Optional per-creator
  open-raffle cap.
- *Dust buys:* `qty ≥ 1` USDC by construction; each buy is one slot, so P ≤ N bounds the
  search.
- *Mis-priced prizes:* nothing forces `base` to match the prize's value. The UI must show
  the prize's live market value (registry `priceUsd`) next to the ticket total, and
  ideally a "prize value vs total ticket cost" ratio.

---

## 5. Entropy ETH fee — who pays

**Recommendation: a per-raffle ETH reserve posted at creation.**
- `create` is payable; requires `msg.value >= RESERVE_MULT * getFeeV2(CALLBACK_GAS)`
  (recommend ×3 ≈ $0.11 today) and stores it as `ethReserve`.
- At sellout, `_requestDraw` pays the fee from the reserve. The last buyer pays only gas.
- If the fee has risen above the reserve, the last buy **does not revert**: the raffle
  goes `SOLD_OUT` and anyone calls `requestDraw(raffleId){value: shortfall}` (keeper or
  frontend). The buyer is never penalised.
- Leftover reserve is credited back to the creator at settle.
- Alternative considered: a protocol-funded ETH pool topped up by the Safe — simpler for
  creators but makes every raffle depend on an admin keeping a balance. Not recommended.

---

## 6. ERC-721 prize path (designed in now)

```
enum PrizeKind { ERC20, ERC721 /*, ERC1155 later */ }
struct Prize { PrizeKind kind; address token; uint256 amountOrId; }
```
- All escrow and release goes through two internal functions,
  `_escrowPrize(Prize)` and `_releasePrize(Prize, to)`, switching on `kind`.
- **v1 ships only ERC20 enabled** (the allow-list contains only B20s; ERC721 kind reverts
  `UnsupportedPrize`). Recommendation: write and audit the ERC721 branch in v1 too, behind
  a per-collection allow-list that starts empty — enabling NFT prizes is then a Safe
  allow-list call, not a redeploy. If the 721 branch is NOT audited in v1, keep it out of
  the bytecode and ship NFT prizes as v2 (new contract) instead.
- 721 escrow: `transferFrom(creator, this, id)` (pull, verified by `ownerOf` after);
  implement `onERC721Received` to accept it. Release in the winner's own `claimPrize` via
  `safeTransferFrom` — receiver-hook griefing then only affects the winner.
- 721 caveat for ChipWorks NFTs: a chipped Noun's activation is voided by transfer, so a
  chipped Noun as a prize loses its chip. Warn in UI.

---

## 7. Risk list

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | **Buyer funds locked indefinitely** in a raffle that never sells out (no refund/expiry by design) | High (user-facing) | Locked decision — mitigate in UX: progress bar, "your USDC stays locked until all N sell; there is no refund", MIN/MAX base caps, featuring near-complete raffles. Owner should sign off explicitly. |
| R2 | A bug in custody code with no exit path traps everything | High | Non-upgradeable + small caps at launch + two independent audits + invariant fuzzing (§8). |
| R3 | Sanctioned / blacklisted recipient blocks payouts | Medium | Credit-per-leg + claim (§4); one refused leg never blocks others. |
| R4 | Entropy reveal stalls | Low | Same-number `revealWithCallback`; `retryDraw` after timeout only if never revealed; keeper job. |
| R5 | Entropy fee spikes above reserve | Low | ×3 reserve; last buy never reverts; `requestDraw` top-up path. |
| R6 | Creator mis-prices the prize vs ticket total | Medium (trust) | UI shows live prize value; optional on-chain floor (prize value ≥ X% of base) — owner decision. |
| R7 | B20 token paused / policy change by Coinbase | Medium | Prize stays claimable; transfers resume when unpaused. Disclose. |
| R8 | USDC freezes the contract address | Low/systemic | Same exposure as every USDC protocol; disclose. |
| R9 | Callback gas / revert | Low | Callback does no transfers or search (~50k). |
| R10 | Regulatory: paid-entry raffles are gambling in many jurisdictions | Owner/legal | Not a code problem; decide geo/ToS before launch. |
| R11 | Spam / UI clutter | Low | MIN_BASE, UI filters, optional per-creator cap. |
| R12 | Sybil self-buying to wash volume | Low | Costs the 10% fee every time; no protocol harm. |

---

## 8. Audit recommendation

This contract holds third-party funds (prizes and every buyer's USDC) **indefinitely and
with no exit path by design**, so it warrants the highest bar used in this repo so far:

1. **Internal:** full unit suite; invariant/fuzz tests on the §4 conservation invariants;
   mutation testing (as done for the Box: every mutant killed); a Base-mainnet fork test
   against the real Entropy contract. Gotcha from the Box: B20s cannot execute in a forge
   fork (`OpcodeNotFound`) — prove real-B20 escrow/release with `eth_simulateV1` on the live
   node, as `box-callback-sim` does.
2. **Two independent external reviews before mainnet** (the owner's standing rule since
   the Box). Recommend one of them be a paid firm or a contest (Cantina / Code4rena-style)
   given indefinite custody — not only AI reviewers.
3. **Launch small:** `MAX_BASE` $1,000 for the first weeks, raise by Safe call later
   (new raffles only).
4. **Ship with:** the keeper job (stuck reveals, requestDraw, settle, optional push-claims),
   a public "verify this draw" view (random number → ticket → buyer), and the UI
   disclosures in R1/R6/R7.

---

## 9. Decisions (resolved 2026-10-08, see the table at the top)

Original list, kept for the record

1. `REVEAL_TIMEOUT` before a fresh redraw is allowed (recommend 7 days).
2. Pot fee: push at settle (recommended — the Pot can't refuse) or credit like the others.
3. Ship the ERC-721 branch audited-but-disabled in v1, or defer NFT prizes to a v2 contract.
4. On-chain "prize value ≥ X% of base" floor, or UI-only disclosure.
5. Launch caps: MIN_BASE / MAX_BASE / optional per-creator open-raffle limit.
6. Explicit sign-off on R1 (no refunds ever) and R10 (legal).
