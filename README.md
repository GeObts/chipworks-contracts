# Chipworks contracts

Base Nouns and DarkNOUNs earn Coinbase B20 tokenized stocks on Base, funded by protocol fee
streams, in permissionless 24-hour rounds.

Start here:

| Document | What it is |
|---|---|
| [AUDIT_BRIEF.md](AUDIT_BRIEF.md) | Contract list, dependencies, claimed invariants, what to attack first |
| [ASSUMPTIONS.md](ASSUMPTIONS.md) | Every guess about a contract we do not control, and every decision you can overrule |
| [OPEN_ITEMS.md](OPEN_ITEMS.md) | What is still unresolved, with the Clutch seam marked |
| [DEPLOY.md](DEPLOY.md) | Deploy order, constructor arguments, verified addresses |

```bash
cp .env.example .env      # add a Base archive RPC
forge test                # everything
forge test --no-match-contract Fork   # no RPC needed
```

Phase 1 is feature-complete and frozen pending answers from Clutch. Not audited. Not deployed.
