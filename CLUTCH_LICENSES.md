# CLUTCH_LICENSES.md

Licence audit of every Clutch contract read during `CLUTCH_RECON.md`. **Legal check only —
no Clutch code has been copied, adapted, or referenced in our source.**

Run 2026-08-30. Sources fetched from each chain's verified-source explorer API.

---

## Headline

**The Clutch V3 code we care about is BUSL-1.1 — not open source, and not forkable for
production without a licence from Clutch.** The older v2-era deployment on ApeChain is MIT.

Two things fell out of this that are not about licensing at all and matter more, in §4.

---

## 1. Per-file verdict

### Robinhood Chain (4663) — the V3 deployment

| Contract | Address | Name | SPDX | Forkable? |
|---|---|---|---|---|
| Soft-staking vault | `0xf5975975a7…` | `SoftStakingVaultV3` | **BUSL-1.1** | **NO** |
| Soft-staking vault | `0xda29113cb6…` | `SoftStakingVaultV3` | **BUSL-1.1** | **NO** |
| Soft-staking vault | `0x3fa388a9b2…` | `SoftStakingVaultV3` | **BUSL-1.1** | **NO** |
| Factory | `0x8b186717a2…` | `AMMFactoryV3` | **BUSL-1.1** | **NO** |
| Market token | `0x084e24C9b5…` | `CollectionToken` | MIT | yes |
| Collection (NFT) | `0xf4d10e22b4…` | `ERC721SeaDrop` | MIT (+2 AGPL-3.0-only deps) | see §3 |

The `AMMFactoryV3` verified bundle contains **23 BUSL-1.1 files** — every Clutch-authored
contract in the system:

```
src/v3/SoftStakingVaultV3.sol     src/v3/NFTAMMVaultV3.sol
src/v3/LoanVaultV3.sol            src/v3/ContractDeployersV3.sol
src/vaults/SoftStakingVault.sol   src/vaults/NFTAMMVault.sol
src/vaults/LoanVault.sol          src/vaults/NFTStakingVault.sol
src/vaults/ERC1155AMMVault.sol    src/market/TokenEscrowReserve.sol
src/market/CollectionToken.sol    src/governance/MarketGovernor.sol
src/factory/ContractDeployers.sol src/libs/Errors.sol   src/libs/Events.sol
src/interfaces/IStakingVault.sol  … and the v2 governor/types files
```

The other 38 files in that bundle are MIT — OpenZeppelin and similar third-party
dependencies, not Clutch's own work.

### ApeChain (33139) — the v2 deployment, COMPLETE

Every Clutch contract deployed on ApeChain, all seven roles:

| Role | Address | Name | SPDX | Forking |
|---|---|---|---|---|
| Factory | `0x87B62309B6…` | `AMMFactoryV2` | **MIT** | **permitted** |
| Router | `0x1577A7E374…` | `BatchRouterV2` | **MIT** | **permitted** |
| AMM vault | `0x56203C9a36…` | `NFTAMMVault` | **MIT** | **permitted** |
| Loan vault | `0x372F30E431…` | `LoanVault` | **MIT** | **permitted** |
| Escrow | `0x8F683Ba486…` | `TokenEscrowReserve` | **MIT** | **permitted** |
| Market token | `0xf95217c08D…` | `CollectionToken` | **MIT** | **permitted** |
| Collection (NFT) | `0x881f79E5d3…` | `MockNFT` | MIT | permitted |
| **Soft-staking vault** | — | — | — | **DOES NOT EXIST ON APECHAIN** |

Every dependency bundled on ApeChain is MIT as well — no copyleft anywhere in that tree.

The full ApeChain factory bundle is **19 Clutch-authored files, all MIT**:

```
src/v2/AMMFactoryV2.sol            src/v2/MarketGovernorV2.sol
src/v2/GovernorV2Deployer.sol      src/v2/MarketTypesV2.sol
src/vaults/NFTAMMVault.sol         src/vaults/LoanVault.sol
src/vaults/ERC1155AMMVault.sol     src/vaults/NFTStakingVault.sol
src/market/CollectionToken.sol     src/market/TokenEscrowReserve.sol
src/governance/MarketGovernor.sol  src/factory/ContractDeployers.sol
src/factory/MarketTypes.sol        src/libs/Errors.sol  src/libs/Events.sol
src/interfaces/{IAMMVault,ILoanVault,IStakingVault,ITokenEscrowReserve}.sol
```

**There is no soft-staking vault in the MIT generation.** The staking contract it does ship
is `src/vaults/NFTStakingVault.sol` — custodial staking, where the NFT is deposited. The
non-custodial `SoftStakingVault` and `SoftStakingVaultV3` appear only in the BUSL bundle.

A scan of all 92 contracts across ApeChain's 13 markets confirms this on chain: **none
exposes `activate(uint256,uint8)` or `kick(uint256)`.** (This scan was re-run correctly after
the `
` bug described at the end of `CLUTCH_RECON.md`, and validated with a control that
greps for a function proven to exist by a live call.)

## 2. Clutch relicensed the entire tree between deployments

This is the part worth understanding rather than skimming.

**All 18 files that appear in both bundles changed licence — 18 of 18, without exception:**

| file | ApeChain | Robinhood |
|---|---|---|
| `src/vaults/NFTAMMVault.sol` | MIT | BUSL-1.1 |
| `src/vaults/LoanVault.sol` | MIT | BUSL-1.1 |
| `src/vaults/NFTStakingVault.sol` | MIT | BUSL-1.1 |
| `src/vaults/ERC1155AMMVault.sol` | MIT | BUSL-1.1 |
| `src/market/CollectionToken.sol` | MIT | BUSL-1.1 |
| `src/market/TokenEscrowReserve.sol` | MIT | BUSL-1.1 |
| `src/governance/MarketGovernor.sol` | MIT | BUSL-1.1 |
| `src/factory/{ContractDeployers,MarketTypes}.sol` | MIT | BUSL-1.1 |
| `src/libs/{Errors,Events}.sol` | MIT | BUSL-1.1 |
| `src/interfaces/*.sol` (4 files) | MIT | BUSL-1.1 |
| `src/v2/{GovernorV2Deployer,MarketGovernorV2,MarketTypesV2}.sol` | MIT | BUSL-1.1 |

Note the last row: **even the V2-era files are BUSL-1.1 in the Robinhood bundle.** This was
not a "new code is BUSL" split; Clutch relicensed everything going forward.

Unique to each bundle:
- **Robinhood only:** `src/v3/{AMMFactoryV3, ContractDeployersV3, LoanVaultV3, NFTAMMVaultV3,
  SoftStakingVaultV3}.sol` and `src/vaults/SoftStakingVault.sol` — all BUSL-1.1.
- **ApeChain only:** `src/v2/AMMFactoryV2.sol` — MIT.

Clutch moved from a permissive licence to a source-available one somewhere between the two
releases. Two practical consequences:

- **MIT is irrevocable for the version it was granted on.** The ApeChain v2 code that was
  published under MIT stays MIT for that code. A later relicence does not reach back.
- **But V3 — the generation with the soft staking we actually want — is BUSL.** The older
  MIT code does not contain `SoftStakingVaultV3`, so "just use the MIT version" does not get
  us the thing we were interested in.

## 2b. Are the two chains the same generation? No.

| | ApeChain (33139) | Robinhood (4663) |
|---|---|---|
| Factory | `AMMFactoryV2` | `AMMFactoryV3` |
| AMM vault | `NFTAMMVault` | `NFTAMMVaultV3` |
| Loan vault | `LoanVault` | `LoanVaultV3` |
| Staking | `NFTStakingVault` (**custodial**) | `SoftStakingVaultV3` (**non-custodial**) |
| Licence | MIT | BUSL-1.1 |
| Markets live | 13 | 5 |

**They are different generations, and the difference is exactly the feature Chipworks needs.**
The vaults I read during the recon were the Robinhood V3 ones; nothing equivalent exists on
ApeChain at any licence.

**This also vindicates the spec.** Spec §2 says: *"Anvil V3 (not V2: V2 is custodial
staking)."* `ASSUMPTIONS.md` A-2 recorded that as contradicted by the docs, which describe v2
soft staking as *"NFTs never leave your wallet"*. The deployed source settles it in the
spec's favour: the V2 generation ships `NFTStakingVault` (custodial deposit), and
non-custodial soft staking arrives only with V3. **The spec was right; the documentation was
misleading; my A-2 note was wrong to side with the docs.**

## 3. What each licence permits

| Licence | Category | What it means for us |
|---|---|---|
| **MIT** | **Forking permitted** | Copy, modify, ship commercially. Only obligation is to keep the copyright and licence notice. |
| **BUSL-1.1** | **Forking NOT permitted (for production)** | Source-available, *not* open source. Copying and modification are allowed for non-production use; **production use requires a commercial licence from the licensor** unless the "Additional Use Grant" covers it. Converts to a permissive "Change License" on the "Change Date". |
| **AGPL-3.0-only** | **Permitted with strong copyleft** | Two dependency files in the SeaDrop collection. If we ever linked AGPL code into something we deploy and users interact with over a network, we would owe complete corresponding source under AGPL. |

**Important limitation on the BUSL finding.** The SPDX header states only `BUSL-1.1`. The
parameters that actually decide whether we may use it — **Licensor, Change Date, Change
License, and Additional Use Grant** — live in a `LICENSE` file that is not part of the
verified on-chain source. Some projects set an Additional Use Grant broad enough to permit
exactly what we would want. **We cannot know without seeing Clutch's LICENSE file**, so the
"NO" above is the safe default reading, not a confirmed prohibition.

## 4. Two findings that matter more than the licence

These emerged from reading the file headers and are flagged here rather than buried.

### 4a. Anvil V3 exists. A-2 is resolved.

`ASSUMPTIONS.md` A-2 recorded "'Anvil V3' is not a public product name" as an unresolved
blocker, because the docs describe only v2. **It is real**: the Robinhood factory is
`AMMFactoryV3`, and the vaults are `SoftStakingVaultV3` at `src/v3/SoftStakingVaultV3.sol`,
compiled with solc 0.8.26. The spec's "Anvil V3" is a real thing, deployed, today.

This also corrects something I said in `CLUTCH_RECON.md` §2: I attributed ApeChain's lack of
soft staking to it being a pre-v2 generation. It is not — ApeChain runs `AMMFactoryV2`.

### 4b. My A-8 conclusion is now in doubt and must be re-checked.

`CLUTCH_RECON.md` states that voiding is lazy and that Chipworks "would right now be paying
five sellers". The `SoftStakingVaultV3` natspec says the opposite:

> Activation is void the moment the NFT changes owner (wallet transfer, AMM sell,
> loan-escrow). … V3 FIX — atomic custody voiding (closes the gen-6 "resurrection" hole):
> gen-6 only evaluated ownership lazily (in activate/claim/kick) …

So V3 appears to have **fixed** the lazy-voiding behaviour that A-8 is about. My five
observed mismatches are still real — the raw `activations` mapping does record a stale owner
after a transfer — but a stale *record* is not the same as an *effective* activation. V3 may
well treat those five as void at evaluation time, which is exactly what our adapter does
independently.

**What this changes:**
- The A-8 headline in `CLUTCH_RECON.md` is **not safe to rely on** until re-verified.
- Our adapter's independent `ownerOf` check remains correct and harmless either way — it
  agrees with V3's intent. It is belt-and-braces rather than load-bearing.
- **The keeper "kick job" is premised on lazy voiding.** If V3 voids on evaluation, that job
  may be unnecessary. Worth settling before building it.

Re-verifying means reading `SoftStakingVaultV3`'s actual logic, which is BUSL-1.1 — reading
for comprehension is fine and is not copying, but I stopped at the header comment pending
your call on how to handle that code.
