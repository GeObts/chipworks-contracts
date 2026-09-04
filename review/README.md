# review/ — generated artifacts

Nothing here is authoritative. `src/` is the source of truth; these exist so an external
reviewer can run tooling without setting the toolchain up, and so the triage in
`../TRIAGE.md` can be checked rather than taken on trust.

| Path | What it is | Regenerate with |
|---|---|---|
| `flattened/*.flat.sol` | One self-contained file per deployable contract, for automated reviewers that want a single file. **Verified**: all eleven compile standalone under the pinned solc settings and produce byte-for-byte identical runtime sizes to the in-repo build. | `forge flatten src/<Path>.sol --output review/flattened/<Name>.flat.sol` |
| `slither-raw.md` | Slither 0.11.6 summary checklist, 168 findings | `python -m slither . --exclude-dependencies --checklist > review/slither-raw.md` |
| `slither-findings.txt` | The same run's full per-finding detail | the stderr of the command above |

Triage of every one of those 168 findings is in `../TRIAGE.md`.
