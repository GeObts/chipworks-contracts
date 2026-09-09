#!/usr/bin/env bash
#
# observed-price.sh - the T+48h decision tool.
#
# DEPLOY_CHECKLIST s1b: "read the observed price and decide execute-vs-cancel, and if
# you cannot state the ratio out loud you have not done the check." This is that check,
# mechanised, because doing it by hand at 22:56 UTC is exactly how it gets skipped.
#
# THE PRICE IS READ FROM THE CHAIN, NOT FROM A MIRROR. $CHIP trades in a Uniswap v4
# pool, so there is no pair contract to call getReserves on - the price lives in the
# PoolManager singleton behind a pool id, and StateView.getSlot0(poolId) is the read.
# currency0 is WETH and currency1 is $CHIP (0x42.. sorts below 0x75..), so
# (sqrtPriceX96 / 2^96)^2 is CHIP-per-WETH and one CHIP is its reciprocal, marked to
# USD through the same Chainlink ETH/USD feed the Pot itself uses.
#
#   set -a && . ./.env && set +a
#   ./tools/observed-price.sh                      # read and decide, emit nothing
#   ./tools/observed-price.sh --emit               # emit both bundles at the defaults
#   ./tools/observed-price.sh --emit --tier0 8 --chiplet 3 --ltv 60
#
# TARGETS ARE IN DOLLARS, NOT IN CHIP. That is the whole point: the $CHIP figure
# is derived from the live price at the moment you run it, so the same command
# produces the right numbers whatever the price has done overnight.
#
#   --tier0 <usd>    what a tier-0 Noun activation should COST. Default 8.
#   --chiplet <usd>  the FLAT Chiplet activation cost. Default 3. Chiplets are a
#                    flat-rate collection (isFlatRate == true, one-way, already
#                    set on chain), so queueCosts takes five EQUAL entries.
#   --ltv <pct>      target loan-to-value for setMaxPrincipal. Default 60.
#
set -euo pipefail

: "${BASE_RPC_URL:?set it first:  set -a && . ./.env && set +a}"
R=(--rpc-url "$BASE_RPC_URL")

# ---- verified on chain 2026-09-09 ----
STATE_VIEW=0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71   # Uniswap v4 StateView, Base
CHIP_POOL_ID=0xbcdd8383e38069f626846b94e93ee4d2c00cadfcce4b9457b0b8b04289030345
ETH_USD_FEED=0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
CHIP_ACTIVATION=0xb6392c6A1dcC030dfC2eB2cC42444612349Fe162
NOUN_LOANS=0x123Bc476594A80B0d99Ca6510e87E249b1C5EC5f
ANVIL=0x93Ac0B6C249c1497429Bc4863C697475DF0Acd4c
SAFE=0xe1096B727499a3f70FaD8bc0267F5e69d01373C7

LIL=0xe3c5Ef27B80481518a2363406e354a9361415556
BASED=0xBf57D0535E10E7033447174404b9bEd3D9eF4C88
DARK=0xd45E54B1A5e77d6E9469a4174d34f27D5D16270C
CHIPLETS=0xC7c114191aa3b2225F9bb053Bc55b3d6F145Bd33

EMIT=0; TIER0_USD=8; CHIPLET_USD=3; TARGET_LTV_PCT=60
while [ $# -gt 0 ]; do
  case "$1" in
    --emit)    EMIT=1; shift ;;
    --tier0)   TIER0_USD="${2:?--tier0 needs a dollar amount}"; shift 2 ;;
    --chiplet) CHIPLET_USD="${2:?--chiplet needs a dollar amount}"; shift 2 ;;
    --ltv)     TARGET_LTV_PCT="${2:?--ltv needs a percentage}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ---- reads ----
SQRT=$(cast call "$STATE_VIEW" "getSlot0(bytes32)(uint160,int24,uint24,uint24)" "$CHIP_POOL_ID" "${R[@]}" | head -1 | awk '{print $1}')
ETHUSD_RAW=$(cast call "$ETH_USD_FEED" "latestRoundData()(uint80,int256,uint256,uint256,uint80)" "${R[@]}" | sed -n 2p | awk '{print $1}')
NOW=$(cast block latest --field timestamp "${R[@]}")

PEND_BASED=$(cast call "$CHIP_ACTIVATION" "pendingCosts(address)" "$BASED" "${R[@]}")
ANVIL_LIVE=$(cast call "$ANVIL" "queuePrice(address)(uint256)" "$BASED" "${R[@]}" | awk '{print $1}')
ANVIL_PEND=$(cast call "$ANVIL" "pendingPrice(address)" "$BASED" "${R[@]}")

CAP_BASED=$(cast call "$NOUN_LOANS" "maxPrincipal(address)(uint256)" "$BASED" "${R[@]}" | awk '{print $1}')
CAP_DARK=$(cast call "$NOUN_LOANS" "maxPrincipal(address)(uint256)" "$DARK" "${R[@]}" | awk '{print $1}')
CAP_LIL=$(cast call "$NOUN_LOANS" "maxPrincipal(address)(uint256)" "$LIL" "${R[@]}" | awk '{print $1}')

# ---- the arithmetic, in python for the precision ----
python3 - "$SQRT" "$ETHUSD_RAW" "$NOW" "$PEND_BASED" "$ANVIL_LIVE" "$ANVIL_PEND" \
          "$CAP_BASED" "$CAP_DARK" "$CAP_LIL" \
          "$EMIT" "$TIER0_USD" "$CHIPLET_USD" "$TARGET_LTV_PCT" <<'PYEOF'
import sys, json, time, datetime
from decimal import Decimal, getcontext
getcontext().prec = 50

(sqrt_raw, ethusd_raw, now, pend, anvil_live, anvil_pend, cap_b, cap_d, cap_l,
 emit_arg, tier0_usd_arg, chiplet_usd_arg, ltv_pct_arg) = sys.argv[1:14]

D   = Decimal
now = int(now)
def words(hexstr):
    h = hexstr[2:] if hexstr.startswith('0x') else hexstr
    return [int(h[i:i+64], 16) for i in range(0, len(h), 64)]

# --- 1. the observed price ---
sqrt   = D(int(sqrt_raw)) / (D(2) ** 96)
chip_per_eth = sqrt * sqrt                      # currency1 per currency0, both 18dp
eth_usd = D(int(ethusd_raw)) / D(10**8)
chip_usd = eth_usd / chip_per_eth

def usd(x):  x = D(x); return f"${x:,.4f}" if x < 1 else f"${x:,.2f}"
def num(x, dp=0): return f"{D(x):,.{dp}f}"
def ts(t):   return datetime.datetime.fromtimestamp(t, datetime.UTC).strftime('%Y-%m-%d %H:%M:%S UTC')

bar = "=" * 74
print(bar); print("OBSERVED $CHIP PRICE - read from the chain, not a mirror"); print(bar)
print(f"  chain now         {ts(now)}")
print(f"  ETH/USD           {usd(eth_usd)}")
print(f"  CHIP per WETH     {num(chip_per_eth)}")
print(f"  $CHIP             ${chip_usd:.10f}")

# --- 2. the queued table, priced at what it would actually cost ---
w = words(pend)
queued_at, tiers = w[1], [D(x) / D(10**18) for x in w[2:7]]
base = tiers[0]

print(); print(bar); print("THE QUEUED TABLE, AT WHAT IT WOULD ACTUALLY COST TODAY"); print(bar)
print(f"  matures           {ts(queued_at)}   ({(queued_at-now)/3600:+.2f} h)")
print(f"  queued base unit  {num(base)} CHIP")
print()
for i, t in enumerate(tiers):
    print(f"    tier {i}  {num(t):>16} CHIP  {usd(t*chip_usd):>11}")

target5 = D(5) / chip_usd
ratio   = base / target5
print()
print(f"  s4 target, tier 0 at $5     {num(target5):>16} CHIP")
print(f"  s1b HIGH bias (1.5-2x)      {num(target5*D('1.5')):>16} - {num(target5*2)} CHIP")
print()
print(f"  >>> THE RATIO, SAY IT OUT LOUD: the queued table is {ratio:.2f}x the $5 target,")
print(f"      and {base/(target5*D('1.75')):.2f}x the deliberately-high target.")
print()
if D('1.2') <= ratio <= D('2.6'):
    print("  VERDICT: IN TOLERANCE  ->  sign safecalls-phase3b-EXECUTE.json.")
elif ratio > D('2.6'):
    print(f"  VERDICT: TOO HIGH.  Activation would cost {usd(base*chip_usd)} at tier 0.")
    print("           Re-queue lower. Chipping then goes live 48h after the re-queue.")
    print("           Executing anyway is SAFE but slow: the table is changeable with")
    print("           another 48h queue, and chipping/lending/rounds unblock immediately.")
else:
    print("  VERDICT: TOO LOW.  DO NOT EXECUTE - activation burns $CHIP at a discount")
    print("           and there is no un-burn. Re-queue higher.")

# --- 3. loan parity, which drifts on its own as $CHIP rises ---
aw = words(anvil_pend)
anvil_eth = D(int(anvil_live)) / D(10**18)
live = anvil_eth > 0
if not live:
    anvil_eth = D(aw[2]) / D(10**18)
anvil_usd = anvil_eth * eth_usd

print(); print(bar); print("LOAN PARITY - the cap is in $CHIP, the collateral is in dollars"); print(bar)
print(f"  Anvil BASED price {anvil_eth} ETH = {usd(anvil_usd)}"
      + ("  (live)" if live else "  (QUEUED, not yet executed)"))
print()

rows = [("BASED_NOUNS", "0xBf57D0535E10E7033447174404b9bEd3D9eF4C88", cap_b, anvil_usd, "Anvil"),
        ("DARK_NOUNS",  "0xd45E54B1A5e77d6E9469a4174d34f27D5D16270C", cap_d, D(160),   "floor"),
        ("LIL_NOUNS",   "0xe3c5Ef27B80481518a2363406e354a9361415556", cap_l, D(12),    "floor")]

fixes = []
for name, addr, cap_raw, bench, bench_name in rows:
    cap  = D(int(cap_raw)) / D(10**18)
    loan = cap * chip_usd
    ltv  = loan / bench
    want = int(bench * (D(ltv_pct_arg) / 100) / chip_usd)
    over = ltv > D(ltv_pct_arg) / 100
    flag = "  <<< BORROWING BEATS SELLING" if ltv > 1 else (f"  <<< over the {ltv_pct_arg}% target" if over else "")
    print(f"  {name:<12} {num(cap):>14} CHIP = {usd(loan):>9}  vs {bench_name} {usd(bench):>8}"
          f"  = {ltv*100:6.1f}% LTV{flag}")
    if ltv > D(ltv_pct_arg) / 100:
        fixes.append((name, addr, want))

if fixes:
    print()
    print(f"  setMaxPrincipal is IMMEDIATE - no timelock. Targets shown at {ltv_pct_arg}% LTV.")
    for name, _, want in fixes:
        print(f"    {name:<12} -> {num(want)} CHIP")

# --- 4. emit the Safe bundles, from DOLLAR targets at the price just read ---
if emit_arg == "1":
    # Round the base unit to something a person can say out loud - LAUNCH_CONFIG s4
    # item 2 asks for 50,000 / 100,000 / 250,000, never 63,412. Two significant
    # figures is the coarsest rounding that still lands within a few percent of
    # the dollar target at any plausible price.
    def sayable(x):
        x = D(x)
        if x <= 0: return 0
        mag = D(10) ** (len(str(int(x))) - 2)
        return int((x / mag).to_integral_value(rounding='ROUND_HALF_UP') * mag)

    b    = sayable(D(tier0_usd_arg) / chip_usd)
    flat = sayable(D(chiplet_usd_arg) / chip_usd)
    # The ladder shape is locked by LAUNCH_CONFIG s4 and must be non-decreasing or
    # queueCosts reverts BadConfig.
    tiers_new = [int(b * m) for m in (1, 2.2, 4.5, 9, 24)]
    assert all(tiers_new[i] <= tiers_new[i + 1] for i in range(4)), "ladder must be non-decreasing"
    assert flat > 0 and b > 0, "targets rounded to zero - check the price"
    E18       = 10**18

    def w32(x):  return f"{x:064x}"
    def addr32(a): return f"{int(a,16):064x}"
    def tx(to, data): return {"to": to, "value": "0", "data": data,
                              "contractMethod": None, "contractInputsValues": None}
    def bundle(name, desc, txs):
        return {"version": "1.0", "chainId": "8453", "createdAt": int(time.time()*1000),
                "meta": {"name": name, "description": desc, "txBuilderVersion": "1.16.5",
                         "createdFromSafeAddress": "0xe1096B727499a3f70FaD8bc0267F5e69d01373C7",
                         "createdFromOwnerAddress": ""},
                "transactions": txs}

    COLS = [("LIL_NOUNS",  "0xe3c5Ef27B80481518a2363406e354a9361415556", tiers_new),
            ("BASED_NOUNS","0xBf57D0535E10E7033447174404b9bEd3D9eF4C88", tiers_new),
            ("DARK_NOUNS", "0xd45E54B1A5e77d6E9469a4174d34f27D5D16270C", tiers_new),
            ("CHIPLETS",   "0xC7c114191aa3b2225F9bb053Bc55b3d6F145Bd33", [flat]*5)]

    txs = [tx("0xb6392c6A1dcC030dfC2eB2cC42444612349Fe162",
              "0x7d9e9e06" + addr32(a) + "".join(w32(c*E18) for c in costs))
           for _, a, costs in COLS]
    open("safecalls-phase3a-REQUEUE.json","w").write(json.dumps(
        bundle("safecalls-phase3a-REQUEUE",
               f"queueCosts x4: tier-0 ~${tier0_usd_arg}, Chiplet flat ~${chiplet_usd_arg} at "
               f"$CHIP {chip_usd:.10f}. OVERWRITES the pending slot and RESTARTS the 48h clock.",
               txs), indent=2))
    print()
    print("  wrote safecalls-phase3a-REQUEUE.json")
    print(f"    base unit    {num(b):>16} CHIP  = {usd(D(b)*chip_usd)}   (target ${tier0_usd_arg})")
    for i, t in enumerate(tiers_new):
        print(f"      tier {i}    {num(t):>16} CHIP  = {usd(D(t)*chip_usd)}")
    print(f"    chiplet flat {num(flat):>16} CHIP  = {usd(D(flat)*chip_usd)}   (target ${chiplet_usd_arg}, five EQUAL entries)")
    print()
    print("    Chiplets stay FLAT-RATE - isFlatRate is already true on chain and is")
    print("    one-way, so this only re-prices the single flat cost. No redeploy.")
    print(f"    NOTE: ChipRounds.splitChangeFeeChip is IMMUTABLE at 5,000,000 CHIP "
          f"({usd(D(5_000_000)*chip_usd)}); it does NOT move with this table.")

    if fixes:
        txs2 = [tx("0x123Bc476594A80B0d99Ca6510e87E249b1C5EC5f",
                   "0x43bbbe12" + addr32(a) + w32(want*E18)) for _, a, want in fixes]
        open("safecalls-parity-MAXPRINCIPAL.json","w").write(json.dumps(
            bundle("safecalls-parity-MAXPRINCIPAL",
                   f"setMaxPrincipal x{len(fixes)} back to 60% LTV. Immediate, no timelock.",
                   txs2), indent=2))
        print(f"  wrote safecalls-parity-MAXPRINCIPAL.json  ({len(fixes)} collections)")
else:
    print()
    print("  (pass --emit to write the re-queue and maxPrincipal Safe bundles)")
PYEOF
