# SPEC-v2 §2.5 pre-deploy check: weekend depth and price-guard tuning (2026-10-09)

**Read-only.** Nothing was sent, nothing deployed; contract and keeper unchanged. Tool: `tools/raffle/weekend-depth.cjs`. Raw data: the four `weekend-depth-*.json` files beside this one.

## Method

All 10 enabled stocks (NVDA, GOOGL, AAPL, META, TSLA, AMZN, MSFT, MSTR, SNDK, SPCX) were sampled every 2 hours (every 30 minutes for the partial weekend) across four windows. At each sampled block the tool records:
- active liquidity;
- the pool's USDC balance;
- the spot tick, and the TWAP over 15, 30 and 60 minutes (`observe`);
- **the real `exactInputSingle` of $1,000 USDC on the real router at that historical block** (`eth_call` with a USDC state override; nothing sent), evaluated against Raffle v2's four checks using the contract's own maths ported 1:1;
- swap, mint and burn event counts per window;
- the pool price against Chainlink at the window's end (Monday's open for the weekends). This is a fairness check only; the contract never reads Chainlink.

| Window (UTC) | Kind | Samples |
|---|---|---|
| Fri 25 Sep 20:00 → Mon 28 Sep 13:30 | full weekend | 34 × 10 |
| Fri 2 Oct 20:00 → Mon 5 Oct 13:30 | full weekend | 34 × 10 |
| Tue 6 Oct 13:30 → Thu 8 Oct 20:00 | weekday baseline | 29 × 10 |
| Fri 9 Oct 20:00 → 22:45 (run time) | **this weekend, first 3 h** | 7 × 10 |

**This weekend can't be measured in full until Monday 13:30 UTC.** Base keeps full history, so no live sampler is needed. The same command samples it retroactively, unchanged:

```
OUT=weekend-1010 WINDOWS='weekend-1010:2026-10-09T20:00:00Z:2026-10-12T13:30:00Z' node tools/raffle/weekend-depth.cjs
```

## Result: a $1,000 buy against all four checks at launch values (30 min / 100 ticks / 150 bps / 1%)

| Window | Pass | Failures |
|---|---|---|
| Weekend 26–28 Sep | **339 / 340** | SPCX at Monday 13:30: TWAP unavailable (its observation buffer was then **360 slots**; it has been raised to 1,000 since) |
| Weekend 3–5 Oct | **340 / 340** | — |
| This weekend, first 3 h | **70 / 70** | — |
| Weekday 6–8 Oct | 288 / 290 | MSTR: spot 104 ticks off the TWAP once (the fill would have been +99 bps, i.e. favourable). SPCX: pool USDC dipped to **$73k**, so the 1% cap ($730) was under $1,000 once. |

Every failure is a **refusal**: the buy reverts, nothing moves, and the keeper retries 5 minutes later, with the USDC fallback after 6 h. **No sample showed a fill below the 150 bps floor.**

## Weekend vs weekday

| Measure | Weekends (750 samples) | Weekday (290) |
|---|---|---|
| Fill vs TWAP-price reference, $1,000 (bps): median / p5 / p1 / worst | −5.0 / −15 / −31 / **−101** (MSTR) | −5.0 / −29 / −43 / −88 |
| \|spot − 30-min TWAP\| (ticks): median / p95 / p99 / max | 0 / 15 / 37 / 96 | 5 / 38 / 68 / 104 |
| Swaps / mints / burns per hour, all 10 pools | 694–1,014 / 518–649 / 1,324–1,537 | 2,290 / 1,192 / 2,144 |
| Pool vs Chainlink at Monday's open | within **±0.5%** for all 10 stocks, both weekends | — |

**Weekend pricing tracks the market.** The pools keep trading all weekend, and when the market reopens the pool price sits within half a percent of the new Chainlink price.

**Weekend spot-vs-TWAP is calmer than weekday** (p95 15 vs 38 ticks).

## Is liquidity pulled on weekends? No

Mints and burns continue all weekend, at roughly half the weekday rate: the market maker keeps re-centring ranges. Pool USDC, weekend minimum against weekday median:

| Stock | NVDA | GOOGL | AAPL | META | TSLA | AMZN | MSFT | MSTR | SNDK | SPCX |
|---|---|---|---|---|---|---|---|---|---|---|
| Weekend min ($k) | 879 | 380 | 755 | 562 | 357 | 494 | **298** | 429 | 346 | 369 |
| Weekday median ($k) | 1,223 | 1,019 | 899 | 830 | 471 | 1,131 | 445 | 523 | 420 | 627 |
| Ratio | 0.72 | 0.37 | 0.84 | 0.68 | 0.76 | 0.44 | 0.67 | 0.82 | 0.82 | 0.59 |

The lowest weekend figure (MSFT, $298k) still gives a 1% cap of **$2,980**, about 3× the $1,000 launch maximum. The only sub-cap dip in the data was SPCX on a **weekday** ($73k).

Active in-range liquidity swings far more than pool USDC: its minimum is often 2–5% of its median between samples, because ranges are re-centred constantly. **This is why the guard checks the real fill rather than TVL**, and the real fill passed.

## Parameter tuning (pass rate of the measured $1,000 fills under alternative guards)

| TWAP / deviation / slippage / pool share | Weekends | All |
|---|---|---|
| **30 min / 100 / 150 / 1% (launch)** | **99.9%** | **99.7%** |
| 30 / 100 / **125** / 1% | 99.9% | 99.7% |
| 30 / 100 / 100 / 1% | 99.7% | 99.6% |
| 30 / 75 / 150 / 1% | 99.7% | 99.4% |
| 30 / 50 / 150 / 1% | 99.5% | 98.8% |
| 15 / 100 / 150 / 1% | 99.9% | 99.8% |
| 60 / 100 / 150 / 1% | 99.7% | 99.4% |
| 30 / 100 / 150 / **0.5%** | 99.9% | 99.7% |

**Recommendation:**
1. **TWAP window: keep 30 min.** 15 min passes marginally more often but is cheaper to manipulate; 60 min refuses more.
2. **Manipulation guard: keep 100 ticks.** The weekend maximum was 96 and the weekday maximum 104. Tightening to 50 costs about 1% of buys (they wait) for little gain.
3. **Slippage floor: tighten 150 → 125 bps.** It refuses nothing more in the data (worst fill −101 bps), and it cuts the worst-case sandwich on a $1,000 prize from $15 to $12.50. This needs **no code change**: one Safe call, `setPriceGuard({1800, 100, 125, 100})`, after deploy.
4. **Pool share: keep 1%.** Halving it changes nothing in the data, but would shrink the margin over $1,000 at the thinnest weekend pool to about 1.5×.

## Flags

| Stock | Status | Action |
|---|---|---|
| **SPCX** | The only weekend failure (TWAP buffer at 360 slots then; 1,000 now), plus the weekday pool-USDC dip to $73k | **Raise its observation buffer to 2,048** before listing it, re-check depth, and consider leaving it off the launch list until this weekend's re-run is clean. |
| TSLA, AMZN, MSFT, MSTR, SNDK, SPCX | Observation buffer **1,000** slots | Raise to 2,048 (`increaseObservationCardinalityNext(2048)`, permissionless, ≈ $0.35 of gas per pool at today's 0.006 gwei). 1,000 covers 30 min at observed rates but is the thinnest margin at peak activity. NVDA, GOOGL, AAPL and META are already at 2,048. |
| MSTR | Most volatile (dev up to 96 at the weekend, 104 on a weekday; fills −101…+99 bps) | Passes; expect the most "wait and retry" refusals. No change. |
| All others | Pass every weekend sample | — |

**No stock needs its `maxPoolShareBps` tightened on the weekend evidence.**

## Still open in §2.5

- This full weekend (re-run Monday after 13:30 UTC with the command above).
- Raise the six 1,000-slot buffers (an owner ops step, not a contract change).
- The owner's decision on 125 bps.
