#!/usr/bin/env bash
# SPEC-v2 §2.5 item 2 (owner decision 2026-10-09): raise the observation buffer of the six stock
# pools still at 1,000 slots to 2,048. PERMISSIONLESS pool calls that only pre-pay storage; they
# touch no ChipWorks contract and deploy nothing.
#
# Each new slot costs ~22.6k gas, so 1,000 -> 2,048 (~23.7M gas) is over Base's ~16.8M per-tx
# cap: two transactions per pool, -> 1,700 (~15.9M gas) then -> 2,048 (~7.9M). Pools already at
# a step are skipped, so re-running after a partial run only sends what is missing.
# Every send waits for its receipt; the script stops on any status other than 1.
#
# Run in your own terminal (it asks for the keystore password once):
#   cd ~/ccx-raffle && bash tools/raffle/raise-observation-buffers.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
RPC=$(grep -m1 '^BASE_RPC_URL=' .env | cut -d= -f2-)
ACCOUNT=${ACCOUNT:-chipworks-deployer}
POOLS=(
  "TSLAc 0x469337fDcc5E8f38e2E4B670B04F57865D13a7BB"
  "AMZNc 0xd03Bc8C7F2FAedCe2aac81bF0444AEA08Ea06E9b"
  "MSFTc 0x7103eB3c9590d1281f7dc03b2A9EE27C39dF5D54"
  "MSTRc 0x8b27f626ab668197000BC722A1012022CAeD10E2"
  "SNDKc 0x5A8236f575471e7BfCA2C8462a200c28f737246E"
  "SPCXc 0x0bf58fe0FAc935Ac69595c19B12Ba0d75E3F8c0E"
)
next_of() { cast call "$1" 'slot0()(uint160,int24,uint16,uint16,uint16,bool)' --rpc-url "$RPC" | sed -n 5p | awk '{print $1}'; }

if [ -z "${ETH_PASSWORD:-}" ]; then read -r -s -p "Keystore password for $ACCOUNT: " ETH_PASSWORD; echo; fi
export ETH_PASSWORD
trap 'unset ETH_PASSWORD' EXIT
FROM=$(cast wallet address --account "$ACCOUNT")
echo "sender $FROM | balance $(cast balance "$FROM" --rpc-url "$RPC" --ether) ETH | gas price $(cast gas-price --rpc-url "$RPC") wei"
echo "needs roughly 142M gas in total (~0.00085 ETH at 0.006 gwei)."

for entry in "${POOLS[@]}"; do
  read -r name pool <<<"$entry"
  for target in 1700 2048; do
    n=$(next_of "$pool")
    if [ "$n" -ge "$target" ]; then echo "$name: already at $n (>= $target), skip"; continue; fi
    echo "$name: $n -> $target ..."
    out=$(cast send "$pool" 'increaseObservationCardinalityNext(uint16)' "$target" --account "$ACCOUNT" --rpc-url "$RPC" --json)
    status=$(echo "$out" | sed -n 's/.*"status":"\(0x[0-9a-f]*\)".*/\1/p')
    hash=$(echo "$out" | sed -n 's/.*"transactionHash":"\(0x[0-9a-f]*\)".*/\1/p')
    gas=$(echo "$out" | sed -n 's/.*"gasUsed":"\(0x[0-9a-f]*\)".*/\1/p')
    echo "  tx $hash status $status gasUsed $((gas))"
    [ "$status" = "0x1" ] || { echo "  FAILED - stopping"; exit 1; }
  done
done

echo "--- after:"
for entry in "${POOLS[@]}"; do read -r name pool <<<"$entry"; echo "$name observationCardinalityNext = $(next_of "$pool")"; done
