# Raffle — audit brief

## 1. What it is

One non-upgradeable contract (`Raffle`, `Ownable2Step` + `ReentrancyGuard`) runs many raffles.

- **Only the house creates.** `createRaffle` is `onlyOwner`, and the owner is the ChipWorks Safe. The house escrows a prize, sets an asking price `base` in whole USD, names a `payee` for the base, and posts an ETH reserve for the randomness fee.
- **Tickets cost exactly 1 USDC.** A raffle sells `N = base + ceil(base * feeBps / 10_000)` tickets. The extra tickets are the fee, paid to the ChipWorks Pot.
- **No exit, by design.** There is no deadline, refund, cancel, expiry, pause or admin withdrawal. Prize, ticket money and reserve stay escrowed until ticket N sells.
- **Randomness is Pyth Entropy V2.** The purchase that sells ticket N requests the draw, paid from the reserve. If that request cannot be made (fee spike, Entropy reverts, out of gas), the purchase still succeeds and the raffle sits `SoldOut` until anyone calls `requestDraw`.
- **The callback only records.** `_entropyCallback` stores the number and `winningTicket = rnd % N`. It makes no transfers, no search and no external calls.
- **Settle is permissionless.** `settle` finds the winner by binary search over purchases. Each purchase is one storage slot `(buyer, endExclusive)`, so the search is O(log P). It then pushes or credits each leg independently: prize to winner, `base` USDC to payee, fee USDC to Pot, leftover reserve to payee (always credited). A refused push (sanctioned or blacklisted recipient) becomes a credit for that recipient only.
- **Credits pay a fixed recipient.** `claimPrize`, `withdrawUsdc(account)` and `withdrawEth(account)` are callable by anyone and only ever pay the recorded recipient.
- **Stalled draws.** `retryDraw` requests **fresh** randomness only when Entropy reports the request `CALLBACK_NOT_STARTED` (never revealed) and `redrawTimeout` has passed. A FAILED callback, whose number is already public, is completed with Pyth's permissionless `revealWithCallback` using the **same** number. `retryDraw` refuses it, so a public number can never be re-rolled.

State machine: `None → Open → SoldOut → Drawing → Drawn → Settled`. `SoldOut` is skipped when the request in the final `buy` succeeds. `retryDraw` keeps the raffle in `Drawing` under a new sequence.

## 2. Scope

| File | Lines | In scope |
|---|---|---|
| `src/raffle/Raffle.sol` | 702 | **yes** |
| `src/interfaces/IEntropyV2.sol` | 45 | interface correctness against the deployed Entropy (selectors, `RequestV2` layout) |
| `src/interfaces/IStockRegistry.sol` | 47 | `isEnabled` only |
| `script/raffle/DeployRaffle.s.sol` | — | launch-config review (constructor args, checks) |

Out of scope:
- Pyth Entropy, USDC, the B20 stock tokens, StockRegistry and the Pot themselves.
- The keeper (off-chain; see KEEPER.md).
- The frontend.

## 3. Launch configuration

Pinned in `script/DeployRaffle.s.sol` and asserted against a Base fork by `tests/fork/RaffleLaunchConfig.t.sol`.

| Parameter | Launch value | Where set | Adjustable? |
|---|---|---|---|
| Owner / house | Safe `0xe1096B727499a3f70FaD8bc0267F5e69d01373C7` (2-of-3) | constructor | `Ownable2Step` transfer only |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (constructor requires 6 decimals) | immutable | no |
| Entropy V2 | `0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb` | immutable | no |
| StockRegistry | `0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458` | immutable | no |
| Pot (fee recipient) | `0x3918a9B479Ce9B58238584c645079AB3bB49855B` | immutable | no |
| `redrawTimeout` | **24 hours** | constructor | owner, within hard bounds **[1 h, 30 d]** |
| `feeBps` | **1,000 (10%)** | default | owner, ≤ 2,000; snapshotted per raffle |
| `minBase` / `maxBase` | **$10 / $1,000** | default | owner, within [1, 1,000,000] |
| `callbackGasLimit` | 200,000 (the live provider rounds it up to 500k at the same fee) | default | owner, within [100k, 1M] |
| `nftPrizesEnabled` | **false**; NFT allow-list empty | default | owner (two calls to enable) |
| Reserve at create | ≥ 3 × `quoteDrawFee()`; today 3 × 0.000015 ETH | constant | no |

None of the owner setters can touch an escrowed prize, ticket money, a reserve or a credit. Each one affects only raffles created afterwards, except `redrawTimeout` and `callbackGasLimit`, which are read when a draw is requested or retried (see THREAT-MODEL T9). There is no pause and no rescue.

## 4. External dependencies

| Dependency | Address (Base) | What the Raffle relies on | Failure impact |
|---|---|---|---|
| **Pyth Entropy V2** (proxy) | `0x6E7D…81Bb`; default provider `0x52De…6506` (Pyth's Fortuna) | `getDefaultProvider`, `getFeeV2`, `requestV2(provider, gasLimit)`, `getRequestV2` (for `retryDraw`), and calling `_entropyCallback(seq, provider, rnd)` from the Entropy address only. The provider's commit-reveal keeps the number unknown until reveal. | Entropy down: draws wait; nothing can be lost. Provider never reveals: `retryDraw` after 24 h. Provider dishonest or withholding: see THREAT-MODEL T1/T2. |
| **USDC** (Circle, upgradeable proxy) | `0x8335…2913` | standard ERC-20; 6 decimals | Blacklisting a recipient: credited leg. Blacklisting or freezing the Raffle itself: systemic (accepted, R8). Upgrade risk: accepted. |
| **ChipWorks StockRegistry** | `0x5e4b…5458` (owner = the Safe) | `isEnabled(token)`, read once at `createRaffle` for ERC-20 prizes | Read at creation only. Later disabling a token does not affect live raffles. |
| **B20 stock tokens** (prizes) | e.g. NVDAc `0xb200…108C` | standard ERC-20 transfer/transferFrom. They are Coinbase-issued tokenized equities with a transfer policy (sanctions refusals; can pause). | Refused transfer at settle: `prizeOwedTo` credit. Paused: the prize stays claimable once unpaused. B20s use an opcode anvil/forge forks lack, so real-B20 behaviour is proven by `eth_simulateV1` on the live node. |
| **ChipWorks Pot** | `0x3918…855B` (owner = the Safe) | receives fee USDC | If it ever refused USDC, the fee is credited to it. |
| OpenZeppelin | v5.1.0 | `Ownable2Step`, `ReentrancyGuard`, `SafeERC20`, `IERC20`/`IERC721` | — |

All addresses and the Safe's 2-of-3 threshold were read live on Base on 2026-10-09 (block ≈ 52,385,000).

## 5. Things we specifically want reviewed

1. **Accounting invariants.** `usdcLiability`, `ethLiability` and `erc20PrizeEscrow` should always equal the balance owed, to the unit, across every path, including refused pushes and later claims. The invariant suite checks this; please try to break it.
2. **Draw integrity:**
   - Can anyone (buyer, last buyer, payee, owner, provider) influence or re-roll the outcome?
   - Is the `retryDraw` guard (`sequenceNumber == r.sequence && callbackStatus == CALLBACK_NOT_STARTED`) correct against the deployed Entropy's request lifecycle, including request clearing after a successful reveal?
3. **Callback safety.** It can never revert for a known request (an unbounded revert would mark it FAILED). Orphan and stale deliveries are handled, and the request key is `(provider, sequence)`.
4. **`_tryRequestDraw` inside `buy`.** Every failure mode must leave the raffle `SoldOut` with the reserve untouched. Consider 63/64-gas griefing by the last buyer (we believe it only delays; see T6).
5. **`_tryTransfer`.** Return-data handling for tokens that return nothing, `false`, or revert, and code-less tokens.
6. **The ERC-721 path** (off at launch, but in the bytecode): escrow check, settle never pushes, claim uses `transferFrom` (see §6, item 4).
7. **Binary search `_buyerOf`.** Bounds and off-by-one, including `p.length == 1`. It is reachable only when `sold > 0`.
8. **Owner-power boundary.** Confirm no owner path reaches escrowed value, and nothing a setter does can strand a live raffle.

## 6. As-built vs the design text in SPEC.md

SPEC.md's top table records the owner decisions and matches the code. The design body (§0–§8) was written before the build. Where they differ, **the code and the top table are authoritative**:

1. **No public creator.** The body talks about "a creator". As built, only the owner creates, and `payee` receives the base.
2. **Caps.** The body's §3 says `MAX_BASE = $10,000`. As built the launch value is **$1,000** (hard ceiling 1,000,000).
3. **Callback gas.** The body says `CALLBACK_GAS = 100_000`. As built the default is **200,000**, bounded [100k, 1M], and the provider rounds it up to 500k. The callback uses about 26k.
4. **ERC-721 release.** The body's §6 says `safeTransferFrom` on claim. As built, `claimPrize` uses **`transferFrom`**, so no receiver hook ever runs, but a contract winner that cannot handle NFTs would hold it unusably. The contract implements no `onERC721Received`; escrow uses `transferFrom` plus an `ownerOf` check. NFT prizes are off at launch.
5. **Pot fee.** Pushed at settle, falling back to a credit (the body offered either).
6. **Pause and rescue.** Neither exists (the body allowed a creation-only pause and a rescue above liabilities). Stray tokens sent to the contract are unrecoverable (THREAT-MODEL R9).
7. **Timeout name.** The body says `REVEAL_TIMEOUT` (7 days recommended). As built it is `redrawTimeout`, with **24 h** at launch and bounds [1 h, 30 d].

Two comment nits in `DeployRaffle.s.sol`, left unchanged because this package makes no code changes:
- It refers to `test/raffle/RaffleLaunchConfig.t.sol`; the file is `test/fork/RaffleLaunchConfig.t.sol`.
- It dates the 24 h decision 2026-10-08; SPEC.md says 2026-10-09.

## 7. Prior review

Internal only: unit, fuzz, invariant, fork, live-node simulation and mutation testing (TEST-REPORT.md). No external review yet; this is the first. The owner's standing rule for custody contracts is two independent external reviews before mainnet.
