# CLUTCH_RECON.md

On-chain reconnaissance of the Clutch Anvil protocol, run 2026-08-30 because the Discord is
gated. Settles the seven Clutch assumptions in `ASSUMPTIONS.md` against **deployed, live
contracts** rather than documentation prose.

---

## Headline

**1. There is no Clutch deployment on Base. We would be first.**

**2. But a real SoftStakingVault exists on Robinhood Chain, and I read it.** Five of them.
That turns most of the guesswork into fact — with one caveat that matters, in §4.

**3. Three of the seven assumptions are refuted, and one of the refutations breaks
`ClaimRouter`'s Clutch leg as designed.** Details in §3.

---

## 1. Base: nothing there

| Check | Result |
|---|---|
| Docs contract list (`anvil.clutch.market/docs#contracts`) | ApeChain 33139, Robinhood 4663, Ethereum "TBD". **No Base row.** |
| Frontend chain list | Ethereum, Robinhood Chain, ApeChain. **No Base.** |
| ApeChain AMMFactory `0x87B6…Fc84` — does it exist on Base? | **no code** |
| Robinhood AMMFactory `0x8b18…9069` — on Base? | **no code** |
| ApeChain BatchRouter `0x1577…AfDc` — on Base? | **no code** |
| Robinhood BatchRouter `0x02eA…a3F1` — on Base? | **no code** |
| Control: USDC on Base | reads fine, so the RPC is not the problem |

Factories are frequently deployed to identical addresses across chains via CREATE2, so
checking the known addresses on Base is a meaningful test, not just a formality. All four
are empty.

**Conclusion: no Clutch market exists on Base. Deploying one makes Chipworks the first.**

## 2. Where the real vaults are

| Chain | Factory | Markets | Soft staking? |
|---|---|---|---|
| ApeChain (33139) | `0x87B62309B6fF4FA184C89919351bEbd3AC11Fc84` | 13 | **No.** 115 contracts scanned, zero expose `activate`. Consistent with soft staking being a v2 feature. |
| Robinhood (4663) | `0x8b186717a20845b514344b17fd5e198aDCab9069` | 5 | **Yes.** Five SoftStakingVaults found. |

The five Robinhood vaults, each bound to one collection:

| Vault | Collection | Reward token |
|---|---|---|
| `0xda29113cb602a9ac81bec6d86ad2ac8f1cb69ecd` | `0xD353952eA5607A0fe0541aaBef343F2Fb10297a9` | `0x0D30AeF38b52…` |
| `0x3fa388a9b2eac3e622200857cf33330686721c54` | `0x6b0079F47e39…` | `0xC18a9c47Dc68…` |
| `0xcba4ce723cd05018935f79af77d221486ae32345` | `0x85DD837cCEd3…` | `0xC4Ab5cE4De5c…` |
| `0xeef2b9dff22c4362b0f00075181bb91bef35654b` | `0xc60283eBe17F…` | `0xf0bDF44fC8C4…` |
| `0xf5975975a7e12b4f412eca5d9b984246f9ee03d7` | `0xf4D10E22B4129CF44572C395E025Dd8d17537A83` | `0x084e24C9b575…` |

RPC: `https://rpc.mainnet.chain.robinhood.com` (chain 4663), public and unauthenticated.

## 3. The seven assumptions, settled

| # | Assumption | Verdict | Evidence |
|---|---|---|---|
| A-1 | Clutch supports Base | **REFUTED (for now)** | No deployment on Base. We would be first. |
| A-2 | "Anvil V3" exists | **UNRESOLVED** | Deployed code is v2. No V3 anywhere on chain. |
| A-3 | One vault per collection | **CONFIRMED** | `collection()` returns a single address on all 5 vaults; 5 vaults, 5 distinct collections. No signature anywhere takes a collection argument. |
| A-4 | `isActive(uint256)` | **REFUTED** | Reverts. Does not exist. |
| A-5 | `tierOf(uint256)` | **REFUTED** | Reverts. Does not exist. |
| A-6 | `ownerOfRecord(uint256)` | **REFUTED as a name, CONFIRMED as a concept** | Reverts, but the vault *does* store an owner of record — see below. |
| A-8 | Voiding is lazy, needs `kick()` | **CONFIRMED** | Two independent proofs, below. |
| A-9 | `claim()` pays the owner of record | **CONFIRMED, and worse than assumed** | It also *rejects* anyone else as caller. See §4. |
| A-11 | `pendingRewards` returns `(address[], uint256[])` | **CONFIRMED** | Return data decodes as two dynamic arrays. |

### What actually exists instead of A-4/A-5/A-6

All three assumed views are replaced by **one** real function:

```solidity
function activations(uint256 tokenId)
    external view returns (address ownerOfRecord, uint256 tier, uint256 activatedAt);
```

Live samples from vault `0xf597…03d7`:

```
token  5 -> owner 0xdb363862e5e73a7ce226730de475c507547cd4c2, tier 4, activatedAt 1786566287
token 10 -> owner 0xbef778fa93ac68ae21a7156aa6b4f7c4e4d4e167, tier 1, activatedAt 1786950725
an unactivated token -> (0x0, 0, 0)
```

This is **better** than what we assumed: one call instead of three, and it confirms the
vault records an owner of record separately from the live NFT owner — the fact A-6 was
really about. `activationOf(uint256)` also exists and returns the same shape.

### A-8: voiding really is lazy — two proofs

1. **Logical.** The vault and the collection are separate contracts, and the collection's
   bytecode contains **no reference to the vault address**. There is no transfer hook. The
   vault therefore *cannot* learn about a transfer; only an explicit `kick()` can update it.
2. **Empirical.** `kick(uint256)` is present in every vault's bytecode, which would be
   pointless if voiding were automatic.

**Our mitigation was correct and is now justified by evidence, not caution.** The adapter
independently compares `IERC721.ownerOf` against the vault's recorded owner and scores a
mismatched Noun as inactive. Without it, a sold Noun would keep earning for the seller until
a stranger volunteered to call `kick`.

A scan of live activations found matched owners in every case sampled — unsurprising, since
these are current holders who have not sold. That is consistent with lazy voiding; it does
not contradict it.

## 4. The finding that breaks ClaimRouter

`claim(uint256)` is **permissioned to the owner of record**:

```
claim(5) from 0x…dEaD (a stranger)          -> reverts NotOwner()   [0x30cd7471]
claim(5) from the recorded owner            -> succeeds
```

Confirmed on two different tokens and two different vaults.

`ClaimRouter` calls `vault.claim(tokenId)` **from the router's own address**. Against this
interface, that call reverts every time. The Clutch leg of "claim everything in one
transaction" cannot work as a plain router contract.

**Why the damage is contained:** the router already treats every leg as independently
failable. A reverting Clutch leg is recorded and skipped, the Chipworks legs still pay out,
and `test_clutchFailureDoesNotBlockChipworks` already covers exactly this shape. So the
router is not *broken* — it silently degrades to Chipworks-only, which is the correct
behaviour but not the advertised feature.

**Options, none applied yet:**
1. **Drop the Clutch leg from the router.** The site does two transactions: ours, then
   Clutch's directly from the user's wallet. Honest, simple, and removes a dependency.
2. **Ask Clutch for a `claimFor(tokenId, owner)`** that pays the owner of record regardless
   of caller. This is the clean fix and costs them very little.
3. **EIP-7702 / smart-account batching** on the site, so the user's own account makes both
   calls in one transaction. Works today, but only for accounts that support it.

I did not change any code. Option 1 is a deletion, option 2 is a conversation, and this
evidence is from **v2 on Robinhood** while the Base target is nominally "V3" — so the
interface could shift again. Worth deciding with that caveat in view.

## 5. What changes in the adapter

`ClutchVaultAdapter` is the only contract that touches Clutch, exactly so this is cheap.
Against the interface as observed, `activation()` becomes **one** staticcall instead of
three:

```solidity
// replaces the isActive / tierOf / ownerOfRecord probes
(bool ok, bytes memory ret) = vault.staticcall{gas: VAULT_PROBE_GAS}(
    abi.encodeWithSignature("activations(uint256)", tokenId)
);
if (!ok || ret.length < 96) return (false, 0, address(0));
(address ownerOfRecord, uint256 tier,) = abi.decode(ret, (address, uint256, uint256));
if (ownerOfRecord == address(0)) return (false, 0, address(0));   // inactive
if (tier >= TIER_COUNT) return (false, 0, address(0));
// ...then the existing live-owner check, unchanged and now evidence-backed
```

Everything else in the adapter stands: the per-collection vault mapping (A-3 confirmed), the
configurable tier table, the gas caps, and the independent owner check. Cheaper and simpler
than what we have.

**Not applied.** The contracts are tagged `audit-candidate-2`, this is v2 evidence against a
V3 target, and A-1 means there is nothing on Base to point an adapter at yet. The change is
one function body when the Base market exists and its interface is confirmed.

## 6. Reproducing this

```bash
RH=https://rpc.mainnet.chain.robinhood.com
cast call 0x8b186717a20845b514344b17fd5e198aDCab9069 "marketCount()(uint256)" -r $RH
cast call 0xf5975975a7e12b4f412eca5d9b984246f9ee03d7 "activations(uint256)" 5 -r $RH
cast call 0xf5975975a7e12b4f412eca5d9b984246f9ee03d7 "collection()(address)" -r $RH
# permission check
cast call 0xf5975975a7e12b4f412eca5d9b984246f9ee03d7 "claim(uint256)" 5 \
  --from 0x000000000000000000000000000000000000dEaD -r $RH   # reverts NotOwner()
```

**Methodology note.** An early version of this scan reported "zero contracts expose
`activate`" on both chains. That was a **false negative**: extracted addresses carried a
trailing `\r`, every `cast code` call errored, and the scan was grepping empty strings. It
was caught by asking whether the method could find functions already known to exist. Any
future scan should include that control.
