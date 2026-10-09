# ChipWorks Raffle v2 — external audit package (2026-10-09)

**Status:** built and tested, **NOT deployed.** Mainnet waits until both of these are done:
1. the pre-deploy items in SPEC-v2 §2.5 clear;
2. this fresh external audit passes.

**v2 is a different contract from the v1.2 package** (`audit/raffle-2026-10-09/`). In v1 the house pre-funded each prize. In v2 the contract **buys the prize stock with the ticket money** at sellout, before the draw. The v1.2 review-round-1 fixes are carried into v2: the Entropy user seed, owner/keeper-only retry, snapshotted timeouts, and strict transfer return data.

| | |
|---|---|
| Repository | `GeObts/chipworks-contracts` (private), branch **`raffle`** |
| In-scope source commit | **`7e9923973cbbae0ecad2d04cd2fcbea823b70e79`** |
| Spec | `SPEC-v2.md` (owner sign-off 2026-10-09; §16 lists where the build differs from the text) |
| In scope | `src/raffle/Raffle.sol` (1,067 lines incl. NatSpec) + `src/interfaces/ISlipstreamPool.sol` (new), and the interface surfaces it calls |
| Chain | Base mainnet (8453) |
| Toolchain | solc 0.8.24, `evm_version = cancun`, optimizer 200 runs, OpenZeppelin v5.1.0, forge 1.7.1 |
| Runtime size | **24,145 bytes — 431 under EIP-170.** Little headroom; any audit fix that adds code may need a size trade. |

## Read in this order

1. **`AUDIT_BRIEF.md`**: what v2 does, the money flow, the price guard, the scope, the launch config, external dependencies and the questions we want answered.
2. **`THREAT-MODEL.md`**: actors, trust, the threats (price manipulation and swap safety are new), and the accepted risks.
3. **`contracts/Raffle.sol`**: the code.
4. **`TEST-REPORT.md`**: unit, fuzz, invariant, Base-fork, launch-config, live-node real-swap simulation, gas, mutation and keeper E2E. All were run fresh on the source commit; raw output is in `logs/`.
5. **`SPEC-v2.md`**: the signed-off design; §16 is the as-built delta.
6. **`KEEPER.md`**: the off-chain job that buys the prize, falls back to USDC, reveals and settles. It is out of scope, included for context.

## Layout

```
contracts/Raffle.sol                         in scope
contracts/interfaces/ISlipstreamPool.sol     NEW: pool (slot0/observe), factory (getPool), router factory()
contracts/interfaces/ISwapRouters.sol        ISlipstreamSwapRouter.exactInputSingle (used), IUniswapV3SwapRouter (unused here)
contracts/interfaces/IEntropyV2.sol          Pyth Entropy V2 surface used
contracts/interfaces/IStockRegistry.sol      StockRegistry surface used (getStock, quoteToken, slipstreamFactory)
script/DeployRaffle.s.sol                    the launch config + pre-broadcast chain checks
tests/  tests/fork/  tests/mocks/            unit + invariant suites, Base-fork suites, mocks (MockSlipstream = pool/factory/router)
tools/mutation.py                            66 hand-written mutants
tools/raffle-live-sim.cjs                    eth_simulateV1 on the live node: the REAL swap in the REAL pool
logs/                                        raw output of every run in TEST-REPORT.md
SHA256SUMS, MANIFEST.md                      byte-exact hashes (.gitattributes = -text)
```

The copies are byte-identical to the repo paths at the source commit (see MANIFEST.md).

Note on `tools/raffle-live-sim.cjs`: it resolves `viem` from a hard-coded local path (`createRequire('C:/Users/1136962520/chipworks/package.json')`). Point that at any project with viem ≥ 2 installed before running it.
