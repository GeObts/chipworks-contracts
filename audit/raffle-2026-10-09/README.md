# ChipWorks Raffle — external audit package (2026-10-09)

**Status:** built and tested, **NOT deployed.** Mainnet deployment waits on this external audit.

| | |
|---|---|
| Repository | `GeObts/chipworks-contracts` (private), branch **`raffle`** |
| In-scope source commit | **`7b81f9c19c2ae8974f052685413fd95c8a302c7c`** (Raffle.sol unchanged since) |
| Branch head when packaged | `6bcf2b93f536387716c19abaf665c1a6f15cf37e` (+ this package commit) |
| In scope | `src/raffle/Raffle.sol` (702 lines), plus the two interfaces it calls |
| Chain | Base mainnet (8453) |
| Toolchain | solc 0.8.24, `evm_version = cancun`, optimizer 200 runs, OpenZeppelin v5.1.0, forge 1.7.1 |
| Runtime size | 15,636 bytes (EIP-170 margin 8,940) |

## Read in this order

1. **`AUDIT_BRIEF.md`**: what the contract does, the scope, the launch config, external dependencies, where the as-built code differs from the design text in SPEC.md, and the questions we want answered.
2. **`THREAT-MODEL.md`**: actors, assets, trust assumptions, the threats considered, and the **accepted risks** (above all: no refund, so funds stay locked until a raffle sells out).
3. **`contracts/Raffle.sol`**: the code under audit.
4. **`TEST-REPORT.md`**: unit, fuzz, invariant, Base-fork, launch-config, live-node simulation, gas and mutation results, all re-run fresh for this package. Raw output is in `logs/`.
5. `SPEC.md`: the design spec, v1.1. Its top table holds the owner decisions as built and **overrides** the design body below it (the deltas are listed in AUDIT_BRIEF §6).
6. `KEEPER.md`: the off-chain keeper job the 24 h redraw-timeout safety argument relies on (outside audit scope, included for context).

## Layout

```
contracts/Raffle.sol                      in scope
contracts/interfaces/IEntropyV2.sol       Pyth Entropy V2 surface used
contracts/interfaces/IStockRegistry.sol   ChipWorks StockRegistry surface used (isEnabled)
script/DeployRaffle.s.sol                 the launch config + pre-broadcast chain checks
tests/                                    unit + invariant suites, base, mocks
tests/fork/                               Base-mainnet fork tests (real Entropy, real USDC)
tools/mutation.py                         23 hand-written mutants
tools/raffle-live-sim.cjs                 eth_simulateV1 on the live node with REAL B20 stock
logs/                                     raw output of every run in TEST-REPORT.md
SHA256SUMS, MANIFEST.md                   byte-exact hashes (LF line endings; .gitattributes = -text)
```

The copies under `contracts/`, `tests/`, `script/` and `tools/` are byte-identical to the repo paths at the commit above (see MANIFEST.md). To audit in place, check out the commit and use the repo paths. The commands are in TEST-REPORT.md §1.
