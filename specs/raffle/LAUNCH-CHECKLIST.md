# Raffle v2 — launch checklist

**Nothing here is done yet except where marked.** The contract and the keeper stay **undeployed** until steps 1 and 2 both pass. Source under audit: `7e99239` (package `audit/raffle-v2-2026-10-09/`).

## Gates (both required before any mainnet deploy)

1. [ ] **External audit of v2 passes.** Any fix changes the commit; re-run the suites and re-package.
2. [ ] **SPEC-v2 §2.5 cleared:**
   - [x] Two past full weekends plus a weekday baseline measured (`predeploy/WEEKEND-DEPTH-2026-10-09.md`, `324467f`).
   - [ ] **Full weekend 9–12 Oct re-run**, Monday after 13:30 UTC:
     `OUT=weekend-1010 WINDOWS='weekend-1010:2026-10-09T20:00:00Z:2026-10-12T13:30:00Z' node tools/raffle/weekend-depth.cjs`
     Judge every stock against both 150 and 125 bps floors.
   - [x] **DONE 2026-10-09: buffer setting raised to 2,048 on all six pools.** 12 transactions from `0x3A3b…aA8d`, all status 1, nonces 17–28, 0.000817 ETH in total. Verified independently onchain: `observationCardinalityNext == 2048` on all six, and `observe(1800)` answers on all ten. The live `observationCardinality` was still 1,000 at completion; it grows into the new setting as trades are recorded (re-check with the Monday re-run). The step's original instructions follow, kept for re-runs.
   - [x] **Observation buffers raised to 2,048** on TSLA, AMZN, MSFT, MSTR, SNDK and SPCX. Permissionless; two transactions per pool, because 1,000 → 2,048 is over Base's per-transaction gas cap. Run it from **PowerShell** with one line: `& "C:\Program Files\Git\bin\bash.exe" "C:/Users/1136962520/ccx-raffle/tools/raffle/raise-observation-buffers.sh"`. It asks once for the `chipworks-deployer` keystore password, which goes to a private temp file and is deleted on exit. Foundry does not need to be on PATH: `tools/lib/find-cast.sh` locates it. Add `--check` for a password-free dry check. Then confirm each pool's `observationCardinalityNext == 2048`. The live `observationCardinality` only grows to 2,048 as the ring buffer wraps, which takes hours at observed swap rates.
   - [x] Parameter tuning: launch floor tightened to **125 bps** (owner, 2026-10-09). The other three values are unchanged.
   - [x] Tick-maths licence: no GPL code is used (SPEC-v2 §16.4).

## Deploy (after the gates)

3. [ ] `forge script script/raffle/DeployRaffle.s.sol --rpc-url $BASE_RPC_URL` dry run, then `--account <keystore> --broadcast --verify`. `checkChain()` must pass.
4. [ ] Verify the source on the explorers.

## Safe transactions right after deploy, before any raffle is created

Proven on a Base fork against the deploy script's output: `test/fork/RaffleLaunchSteps.t.sol`.

5. [ ] `setKeeper(0x6571E3412553Fada40C3D96e61E7Cfd20A0695B9)`, the chipworks-keeper signer.
6. [ ] **`setPriceGuard({twapWindow: 1800, maxDeviationTicks: 100, maxSlippageBps: 125, maxPoolShareBps: 100})`**, owner decision 2026-10-09. Every raffle created afterwards snapshots 125 bps. Do this **before** the first `createRaffle`: raffles created earlier keep the 150 bps default for life.

## Launch stock list

7. [ ] **SPCX stays OFF** until the 9–12 Oct re-run comes back clean for it (owner, 2026-10-09).
   - This is enforced by the house: the Safe does not create SPCX raffles, and the site does not offer SPCX.
   - It is **not** done by disabling SPCX in the StockRegistry: that registry is shared with ChipRounds and the Box, and disabling it there would remove SPCX from those live products too.
   - The other nine enabled stocks passed every weekend sample.
8. [ ] Launch caps: $10–$1,000, fee 10% on top (contract defaults). **Don't raise `maxBase`** without re-running the depth check per pool (pool TVL ≠ tradeable depth).

## Keeper (after the Raffle exists)

9. [ ] Merge `raffle-job` (`df53a4c`) to master. Set `RAFFLE_ADDRESS`, and add the `5-25/5,35-55/5` cron (already in `wrangler.toml` on the branch). Deploy with **`RAFFLE_SEND` off**, and check `/raffle.json` shows simulations only.
10. [ ] Turn `RAFFLE_SEND=true` once a first test raffle has been simulated end to end. Point an uptime check at `/health` (raffle alerts turn it 503).
