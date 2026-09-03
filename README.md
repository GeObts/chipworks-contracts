# Chipworks contracts

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
| [DEPLOY.md](DEPLOY.md) | Deploy order, constructor arguments, verified addresses |
| [CLUTCH_RECON.md](CLUTCH_RECON.md) · [CLUTCH_LICENSES.md](CLUTCH_LICENSES.md) | Why Chipworks runs its own activation vault instead of depending on Clutch |

```bash
cp .env.example .env      # add a Base archive RPC
forge test                # everything
forge test --no-match-contract Fork   # no RPC needed
```

Phase 1 is feature-complete and no longer blocked on anyone. Not audited. Not deployed.
