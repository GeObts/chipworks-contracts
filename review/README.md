# review/ — generated artifacts

Nothing here is authoritative. `src/` is the source of truth; these exist so an external
reviewer can run tooling without setting the toolchain up, and so the triage in
`../TRIAGE.md` can be checked rather than taken on trust.

| Path | What it is | Regenerate with |
|---|---|---|
| `flattened/*.flat.sol` | One self-contained file per deployable contract, for automated reviewers that want a single file. **Verified**: each compiles standalone under the pinned solc settings (0.8.24, cancun, optimizer 200) and its **executable runtime code is byte-for-byte identical** to the in-repo build — only the 53-byte CBOR metadata trailer differs, which it must, since it encodes the source path. Re-verified for the five `launch-candidate-21` re-scan contracts (`ChipBurner`, `ChipActivation`, `ChipRounds`, `StockRegistry`, `POLTreasury`); the other seven were generated earlier and are unchanged. | `forge flatten src/<Path>.sol --output review/flattened/<Name>.flat.sol` |
| `slither-raw.md` | Slither 0.11.6 summary checklist, 168 findings | `python -m slither . --exclude-dependencies --checklist > review/slither-raw.md` |
| `slither-findings.txt` | The same run's full per-finding detail | the stderr of the command above |

Triage of every one of those 168 findings is in `../TRIAGE.md`.

**The 168 are the `f0d6421` (2026-09-03) baseline run.** Slither was re-run at
`launch-candidate-21`; the artifacts here are that newer run. The **delta** — what the Burner
and the burn re-route actually added — is recorded in `../RESCAN_NOTE.md` rather than
re-triaged from scratch, so the 168 baseline in `../TRIAGE.md` stays meaningful.
