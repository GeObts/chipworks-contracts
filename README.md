# Chipworks contracts

> ## 🔍 Reviewing this code? Start at **[REVIEW_PACKAGE.md](REVIEW_PACKAGE.md)**.
>
> It is the self-contained reviewer entry point: how to build and run the 593 tests (553 need
> no RPC), the eleven-contract inventory grouped by blast radius, the 22 invariants we claim,
> which open items are accepted-by-design versus genuinely open, and how we would like
> severity judged against the launch caps currently in effect.
>
> Check out the **`review-1`** tag — identical contracts to `launch-candidate-1`, plus the
> review package. Findings are processed per **[TRIAGE.md](TRIAGE.md)**.
>
> **Not audited. Not deployed.** Launch caps are in effect until independent review completes.

Lil Based Nouns, Based Nouns and DarkNOUNs earn Coinbase B20 tokenized stocks on Base, funded
by protocol fee streams, in permissionless 24-hour rounds.

Holders opt in by burning $CHIP to activate a Noun at a tier. Activation is non-custodial —
the Noun never leaves the wallet — and it is void the moment the Noun changes hands, computed
on every read rather than stored, so a sold Noun stops earning in the same block with no
keeper involved. A Noun locked as loan collateral is the deliberate exception: it keeps
earning for its borrower.

Start here:

| Document | What it is |
|---|---|
| [AUDIT_BRIEF.md](AUDIT_BRIEF.md) | Contract list, dependencies, claimed invariants, what to attack first |
| [ASSUMPTIONS.md](ASSUMPTIONS.md) | Every guess about a contract we do not control, and every decision you can overrule |
| [OPEN_ITEMS.md](OPEN_ITEMS.md) | What is still unresolved |
| [LAUNCH_CONFIG.md](LAUNCH_CONFIG.md) | **The runbook.** Locked launch parameters merged with the deploy sequence — start here on the day |
| [DEPLOY.md](DEPLOY.md) | Deploy order, constructor arguments, verified addresses, and why each is wired that way |
| [RESCAN_NOTE.md](RESCAN_NOTE.md) | What changed since the audit closed, and what to re-scan |
| [BURN_VISIBILITY.md](BURN_VISIBILITY.md) | What is truly destroyed (Chiplets) and what only sits at `0xdead` ($CHIP) — **and the aggregator filing that is required post-launch** |
| [SITE_CLAIM_API.md](SITE_CLAIM_API.md) · [SITE_LOAN_API.md](SITE_LOAN_API.md) | What the site must get right: the claim-batch gas formula, and the loan deadline UX |
| [B20_DOCS.md](B20_DOCS.md) | Base's tokenized-stock documentation, filed verbatim — the source the B20 reconciliation in ASSUMPTIONS is checked against |
| [CLUTCH_RECON.md](CLUTCH_RECON.md) · [CLUTCH_LICENSES.md](CLUTCH_LICENSES.md) | Why Chipworks runs its own activation vault instead of depending on Clutch |

```bash
cp .env.example .env      # add a Base archive RPC
forge test                # everything
forge test --no-match-contract Fork   # no RPC needed
```

Phase 1 is feature-complete and no longer blocked on anyone. Not audited. Not deployed.
