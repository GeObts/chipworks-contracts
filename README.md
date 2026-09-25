# ChipWorks contracts

ChipWorks on Base lets holders of four seperate NFT collections on Base (Lil Based Nouns, Based Nouns, DarkNOUNs, and Chiplets) earn Coinbase B20 tokenized stocks. Burn `$CHIP` to activate an NFT without moving it; activation dies the moment the Noun is sold (a Noun locked as loan collateral is the deliberate exception and keeps earning for the borrower). Protocol fee streams fund permissionless 24-hour rounds. Around that core: Box gacha, Noun-backed `$CHIP` loans, a Morpho helper to borrow USDC against tokenized stocks, Anvil (FIFO Noun sales), the Chiplet Furnace, and a `$CHIP` lottery wrapper for Megapot Lottery integration.

**This repo is the contracts.** The product site is [getchipped.xyz](https://getchipped.xyz); its app source is [`GeObts/chipworks`](https://github.com/GeObts/chipworks) (may be private). Contracts live here. The site lives there.

## Start here for judges

1. [Live site](https://getchipped.xyz) — what users actually see
2. [REVIEW_PACKAGE.md](REVIEW_PACKAGE.md) — how to build, what’s in scope, how to judge findings
3. [SITE_MORPHO_API.md](SITE_MORPHO_API.md) — Morpho vault + stock-borrow helper (**live** on Base)
4. [BOX.md](BOX.md) — sealed-box gacha (**unaudited, not deployed**)
5. [Frontend repo](https://github.com/GeObts/chipworks) — sister app for getchipped.xyz

## Status (honest)

ChipWorks contracts are **not a completed independent audit.** Do not quote this repo as “audited” or “fully audited.”

| Surface | Deploy | Review |
|---|---|---|
| Earn / activation / rounds / claims, Noun loans, Anvil, Furnace, POL | Deployed and verified on Base — addresses in [`verify-json/`](verify-json/_initcode_index.json) | Iterative **external review** through tag `launch-candidate-22`. Named gaps remain: `StockRegistry` never had its own review batch; `ChipClaims` lows were never received. See [REVIEW_PACKAGE.md](REVIEW_PACKAGE.md) and [TRIAGE.md](TRIAGE.md). |
| Morpho `ChipBorrowHelper` + Chipworks USDC vault (`cwUSDC`) | **Live** (2026-09-17). Helper `0x36C7f9Ed1ffF7FD6305874837b257C3Bfa8FDff6`, vault `0x6B0EF5dd1cED6E26c384E4CcAf72f9dC0A1093d6` | Two targeted review rounds (Bankr, Grok) before deploy — not a public audit report. |
| Box gacha (`src/box/`) | **Not deployed** | Unaudited. Highs H-01–H-05 from the Box review are closed; that is not a completed audit. |

`$CHIP` itself is Bankr/Doppler infrastructure. ChipWorks’ own contracts are a separate surface.

## Build and test

Foundry · Solidity **0.8.24** · EVM **cancun** · OpenZeppelin **v5.1.0** · optimizer 200 runs · no `via_ir`. Pinned in [`foundry.toml`](foundry.toml).

```bash
git submodule update --init --recursive
cp .env.example .env          # set BASE_RPC_URL for fork tests (archive node; public Base RPC will rate-limit)
forge test --no-match-contract Fork   # unit / fuzz / invariant — no RPC
forge test                            # full suite, including Base-fork tests
```

Deploy keys: there is no `PRIVATE_KEY` in `.env.example`. Use an encrypted Foundry keystore (`cast wallet import`) and pass `--account`.

## Docs

### Product

- [BOX.md](BOX.md) — Box gacha brief (SKUs, odds, vault rules)
- [BURN_VISIBILITY.md](BURN_VISIBILITY.md) — what is actually burned vs sent to `0xdead`
- [B20_DOCS.md](B20_DOCS.md) — Base tokenized-stock docs, filed verbatim

### Security review

- [REVIEW_PACKAGE.md](REVIEW_PACKAGE.md) — reviewer entry point
- [AUDIT_BRIEF.md](AUDIT_BRIEF.md) — contract inventory, claimed invariants, what to attack first
- [TRIAGE.md](TRIAGE.md) — every finding, including disputed ones
- [OPEN_ITEMS.md](OPEN_ITEMS.md) · [ASSUMPTIONS.md](ASSUMPTIONS.md) · [RESCAN_NOTE.md](RESCAN_NOTE.md)

### Deploy

- [DEPLOY.md](DEPLOY.md) — order, constructor args, why each wire exists
- [DEPLOY_CHECKLIST.md](DEPLOY_CHECKLIST.md) — live run sheet
- [LAUNCH_CONFIG.md](LAUNCH_CONFIG.md) — locked launch parameters + sequence

### Site integration

- [SITE_CLAIM_API.md](SITE_CLAIM_API.md) — `ClaimRouter` batching and gas
- [SITE_LOAN_API.md](SITE_LOAN_API.md) — Noun loan deadlines and grace
- [SITE_MORPHO_API.md](SITE_MORPHO_API.md) — lend/borrow on Morpho as the contracts expose it

Historical recon (Clutch, log dumps) lives under [`docs/archive/`](docs/archive/) — not part of the current product.
