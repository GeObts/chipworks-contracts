# Issue #5: executable quotes for enablement and spending

## Reviewed target and caller chain

This contribution integrates upstream `eb0f31b` (launch-candidate-22 era). That target
contains `ChipRounds._maxSpendFor`; its former STATICCALL read balance-derived TVL.
The earlier local branch predates that function. The final implementation covers both
the registry gate and the current production settlement caller. PR #4's separate
minimum-threshold flag policy is not included in the final diff against upstream.

The production chain is:

`setEnabled` / `liquidityReport` / `clearsMinLiquidity` -> `poolLiquidityUsd` ->
bounded executable probe -> canonical venue QuoterV2 -> reverting pool swap simulation.

`settleStock` -> `_maxSpendFor` -> the same executable probe -> conservative impact
fraction -> independent quote caps -> slice/commitment clamp -> existing swap path.

## Metric and ABI

- `poolLiquidityUsd` returns the configured buy-probe input notional in 18-decimal USD
  when its quoted stock output is within the configured Chainlink value deviation. It
  returns zero on failure. This is finite validated capacity, not total pool liquidity.
- `setDepthConfig` selects the canonical quoter, raw quote-token probe amount, maximum
  deviation (including fees, at most 500 bps), and mandatory feed age (at least 72 hours).
  Missing configuration and zero measurements cannot pass even a zero threshold.
- `poolBalances` and the renamed `poolTvlUsd` are informational. No gate or spending
  decision consumes them. Donations can change these reports without changing quotes.
- QuoterV2 interfaces distinguish Uniswap fee tiers from Slipstream tick spacing.
  Both execute non-view calls; STATICCALL is unsupported. Off-chain clients use eth_call.
  The factory-B deployment named Quoter exposes the tuple-based QuoterV2 ABI on chain.
- Probe changes disable a stock and venue changes clear its configuration. The factory
  getter catches mismatches; governance must still verify canonical deployed bytecode.

Sources: [Uniswap QuoterV2 interface](https://github.com/Uniswap/v3-periphery/blob/main/contracts/interfaces/IQuoterV2.sol),
[Slipstream QuoterV2 interface](https://github.com/aerodrome-finance/slipstream/blob/main/contracts/periphery/interfaces/IQuoterV2.sol),
[Uniswap Base deployments](https://developers.uniswap.org/docs/protocols/v3/deployments/v3-base-deployments),
[Slipstream deployments](https://github.com/aerodrome-finance/slipstream#deployments).

## Spending, failures, and governance

The existing `maxImpactBps` applies as an additional fraction of the validated probe.
It is not a constant-product price-impact estimate. For example, 25 bps of a validated
$1,000 probe gives a $2.50 ceiling. No extrapolation to raw TVL is performed.

An independent `maxRoundBudget` is restored (constructor default: 10,000 whole quote
tokens), with an optional tighter `maxStockSpend`. Zero stock cap means the global cap;
zero round cap is invalid. The three-argument upstream `setRoundParams` remains intact;
`setMaxRoundBudget` configures the separate hard cap. The launch runbook retains its
$1,000 policy through that setter. Existing open rounds are additionally constrained by
their recorded slice and available committed quote.

Depth failure produces the existing isolated `StockSkipped(..., "no depth")` event
without consuming committed quote. Successful swaps still account for actual balance
deltas and retain the Chainlink-derived minimum output; multiplication/division uses
full-precision arithmetic without changing the rounding order. Unspent quote carries
back to the Pot at finalization.

Settlement requires enough gas to forward the full 1.5M depth allowance, EIP-150
overhead, and bookkeeping reserve. An intentionally underfunded call reverts without
marking the stock settled/skipped and can be retried. A quoter that exceeds its bounded
1M allowance still fails closed. Registry measurement also bounds feed/pool reads and
catches decoding and arithmetic failures. Reports quote each stock once.

## Validation

- `forge build --build-info`: passed. Deployed code sizes: StockRegistry 12,951 bytes;
  ChipRounds 23,413 bytes, both below EIP-170's 24,576-byte limit.
- `forge test --no-match-path 'test/fork/*'`: 766 passed, zero failed or skipped.
- Negative regression check in an isolated copy: substituting the old raw-balance
  implementation makes the donation invariant fail, as expected. Production sources
  were not modified for that check.
- `forge test --match-path 'test/fork/*' -j 1`: 64 passed, zero failed or skipped
  across 12 suites (920.68 seconds). Both donation venues, the factory-B B20 gate,
  and full-system settlement/carry integration passed.
- `git diff --cached upstream/master --check` and formatting checks on the changed
  production interfaces and donation regression suites: passed.
- Slither 0.11.6 analyzed a fresh production-only Foundry build: 96 contracts,
  102 detectors, 204 findings (8 high, 55 medium, 106 low, 34 informational,
  1 optimization). This is not a clean scan or a replacement for an audit.

Changed-path Slither findings were reviewed as follows:

- Reentrancy around `settleStock`'s new registry CALL is covered by its existing
  `nonReentrant` guard, including settlement, finalization, cancellation and recovery
  entry points. Accounting continues to use actual swap balance deltas.
- The registry enablement warning requires a callback to reach owner-only mutation.
  Canonical pool/quoter callbacks have no such permission. A malicious owner-selected
  quoter remains outside the trust model, as documented for `setDepthConfig`.
- Return-data-copy warnings on pool/quoter reads are contained by the bounded external
  measurement call: exhaustion reverts that subcall and reports zero depth. The
  factory-identity read occurs only during owner configuration; malformed or exhausting
  data can reject configuration. ChipRounds' immutable registry returns one fixed word.
  These boundaries do not promise successful execution with arbitrarily low caller gas.
- Calls inside `liquidityReport` are deliberate: one bounded quote per stock, with
  linear aggregate gas cost. Timestamp comparisons implement the stated freshness
  policy. The external self-call to `priceUsd` intentionally bounds feed execution.
- All eight high-severity reports concern unchanged upstream functions in ChipClaims,
  ConversionRoutes, ChipBurner and FeeSplitter. They remain separate review items;
  this contribution makes no claim to resolve the repository's other scan findings.

The regression coverage includes donations of either token on both venues; exact
thresholds; absent, zero, malformed, reverting, and gas-exhausting quotes; invalid pool
state; stale/future/uninitialized feed timestamps; unsafe arithmetic; configuration
authorization; cap behavior; isolated skipped slices; and underfunded-keeper retries.

Real Base fork coverage uses canonical Uniswap V3 and Slipstream-A WETH/USDC pools,
including the production `maxSpendFor` caller, plus the current Slipstream-B NVDA pool.
The WETH/USDC tests use unchanged token, pool, feed, and quoter code. The B20 test retains
the repository's necessary ERC20 stand-in for node-native stock precompiles; pool state,
factory, feed, and quote simulation remain real. Donation tests compare actual quoted
output as well as the capped metric and active liquidity/slot0.

The address-identity source scan retains all forbidden patterns and file coverage but
uses Foundry's host-side `contains` helper; its previous byte-by-byte EVM scan exceeded
the test gas allowance as the source tree grew. Audit-era flattened files and existing
audit tallies remain historical snapshots; this note describes the new contribution.

## Residual limitations

- Spot manipulation and flash liquidity remain possible. This is neither a TWAP nor
  an anti-MEV guarantee, and does not replace the independent hard caps.
- The probe is fixed and conservative: capacity beyond it is not discovered, and many
  tick crossings can exceed the gas budget. Real changes can invalidate the next quote.
- Chainlink can be stale within the configured window; the quote token is still valued
  at par. Issuer transfer policies and production-node precompile behavior matter.
- Enabling remains a point-in-time flag; settlement now re-quotes executable capacity.
  A nonzero probe below the enablement threshold can still bound an already-enabled
  stock's buy, consistent with upstream's policy on threshold/flag persistence.
- Compiler/EVM settings remain the repository's pinned Solidity 0.8.24/Cancun toolchain;
  this fix does not undertake a compiler migration or change audit status.
