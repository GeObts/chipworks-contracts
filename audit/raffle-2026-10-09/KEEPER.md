# Keeper job (context, not in audit scope)

The 24 h `redrawTimeout` is safe because draws are completed with the **same** number long before the timeout (THREAT-MODEL T2). That is the keeper's job, and anyone else can do it too, since every call involved is permissionless.

| | |
|---|---|
| Repo / branch | `GeObts/chipworks-keeper`, branch **`raffle-job`** @ `71ad507c9140327e16e6a3e5d00e26274ccad876` (not deployed; the Raffle is not deployed) |
| Runtime | Cloudflare Worker, cron every 30 min; RPC fallback across providers |
| Files | `src/tasks/raffle.ts`, `src/tasks/raffleplan.ts`, `src/abis/Raffle.json`, `test/raffleplan.test.ts`, `tools/raffle-e2e.ts` |

## Each cycle, for every raffle

1. **SoldOut** (the automatic request failed): call `requestDraw`, topping up only the shortfall.
2. **Drawing for more than `RAFFLE_REVEAL_AFTER_SECONDS` (120 s)**: complete it with Pyth's permissionless `revealWithCallback(provider, seq, userContribution, providerContribution)`. Two inputs come from different places:
   - `userContribution` comes from Entropy's `Requested` event.
   - `providerContribution` comes from Fortuna `{uri}/revelations/{seq}`. For a **FAILED** callback, or when Fortuna fails, it comes instead from Entropy's own `Revealed` event (topic `0x2231996c…`), where Pyth published it.

   The keeper never calls `retryDraw` on a draw whose number is obtainable.
3. **Drawn**: call `settle`.
4. **Alert**: any draw pending for more than `RAFFLE_ALERT_SECONDS` (900 s) sets `/health` to 503 and pushes an alert.

Sends are gated by `RAFFLE_SEND`; without it the job only simulates.

## Evidence

- `test/raffleplan.test.ts`: 12 unit tests of the planning logic.
- `tools/raffle-e2e.ts`: all checks pass on a Base fork. It forks one block before a real past Entropy request so the Raffle's request reuses that sequence, serves the real revelation in place of Fortuna, and the real Entropy accepts the keeper's `revealWithCallback`. The keeper then settles.

The same Revealed-event fallback was ported to the live Box keeper on 2026-10-09 (branch `box-failed-reveal` @ `ad112ac`). It has a Base-fork proof (`tools/box-failed-reveal-e2e.ts`): the keeper's reveal reproduces the exact random number real Base produced, and the real Entropy accepts the re-completion of a FAILED request.
