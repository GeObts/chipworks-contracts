# Keeper job (context, not in audit scope)

| | |
|---|---|
| Repo / branch | `GeObts/chipworks-keeper`, branch **`raffle-job`** @ **`df53a4c`** (NOT deployed; the Raffle is not deployed) |
| Runtime | Cloudflare Worker. The raffle job runs from the 30-min cycle **and** a raffle-only cron `5-25/5,35-55/5`, so about every 5 minutes. The cron skips :00 and :30 so the keeper key never has two senders in one minute. The raffle job keeps its state in its own KV record. |
| Files | `src/tasks/raffle.ts`, `src/tasks/raffleplan.ts`, `src/abis/Raffle.json` (v2), `src/worker.ts`, `test/raffleplan.test.ts`, `tools/raffle-e2e.ts` |

## Each run, for every raffle not yet Settled (decisions on BLOCK time)

| State | Action |
|---|---|
| **SoldOut** | `acquirePrize`, simulated first. A refusal (guard, floor, router) is a simulation revert: **nothing is sent**, the row is `waiting`, and it retries next run. Once `now ≥ soldOutAt + acquireTimeout` it calls `fallbackToUsdc` instead. **Alert** if a raffle stays unbought > 1 h (`RAFFLE_ACQUIRE_ALERT_SECONDS`, re-aged live in `/health`). |
| **PrizeReady** | `requestDraw` (a reserve shortfall is an alert; the keeper never tops up from its own wallet). |
| **Drawing** | after 2 min, `revealWithCallback` with the same number. The provider's revelation comes from Fortuna, or for a FAILED callback or a Fortuna failure from Entropy's `Revealed` event, using the hardened helper the live Box keeper already runs. Alert after 15 min pending. |
| **Drawn** | `settle`. |

Sends are gated by `RAFFLE_SEND`. They go over plain HTTP to the configured RPC (Alchemy, with public fallbacks), not through a private endpoint.

## Evidence

- `test/raffleplan.test.ts`: 18 tests, including the sold-out decision at and around the timeout, the snapshot timeout, the v2 state numbers, and live re-ageing of the 1 h alert.
- **`tools/raffle-e2e.ts`: 19/19** on an anvil Base fork with the real Entropy and USDC (mock stock, pool and router; B20 can't run in a fork). See `logs/07-keeper-e2e.log`.
  - **Raffle 1:** the real job buys the prize; the raffle holds it, then requests the draw on a reused real sequence; the job reveals with the real revelation and settles; the winner gets the bought stock and the Pot 1 USDC.
  - **Raffle 2:** its pool is pushed off its TWAP. The job's buy is refused and nothing is sent; the 1 h alert fires; after 6 h the job falls back to USDC and the draw is requested.
