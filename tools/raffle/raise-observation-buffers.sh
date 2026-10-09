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
# Run it from PowerShell (one line; asks for the keystore password once):
#   & "C:\Program Files\Git\bin\bash.exe" "C:/Users/1136962520/ccx-raffle/tools/raffle/raise-observation-buffers.sh"
# or from Git Bash:  bash ~/ccx-raffle/tools/raffle/raise-observation-buffers.sh
# `--check` resolves cast and reads the pools without asking for a password or sending anything.
set -euo pipefail
cd "$(dirname "$0")/../.."
. tools/lib/find-cast.sh   # cast works even when Foundry is not on this shell's PATH
RPC=$(grep -m1 '^BASE_RPC_URL=' .env | cut -d= -f2- | tr -d '\r')
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

if [ "${1:-}" = "--check" ]; then
  echo "cast: $CAST_BIN ($(cast --version | head -1))"
  echo "gas price $(cast gas-price --rpc-url "$RPC") wei"
  for entry in "${POOLS[@]}"; do read -r name pool <<<"$entry"; echo "$name observationCardinalityNext = $(next_of "$pool")"; done
  echo "check OK - nothing sent"
  exit 0
fi

# THE PASSWORD GOES IN A FILE, NOT AN ENV VAR. In cast 1.7.1 ETH_PASSWORD means "path to a
# password FILE" (--password-file), and --password on the command line would be visible in the
# process list. So: ask once, write it to a private temp file (umask 077), pass
# --password-file, and delete the file on any exit — normal end, failure, or Ctrl-C.
unset ETH_PASSWORD
if grep -qi microsoft /proc/version 2>/dev/null; then
  PWDIR=/mnt/c/Users/1136962520/AppData/Local/Temp   # readable by the Windows cast.exe
else
  PWDIR="${TMPDIR:-/tmp}"
fi
PWFILE=$(umask 077 && mktemp "$PWDIR/cw-keystore.XXXXXX")
trap 'rm -f "$PWFILE"' EXIT
trap 'rm -f "$PWFILE"; echo; echo "interrupted - password file removed"; exit 130' INT TERM
read -r -s -p "Keystore password for $ACCOUNT: " PW; echo
printf '%s' "$PW" >"$PWFILE"
unset PW
# The path as the (Windows) cast.exe needs to see it.
if command -v wslpath >/dev/null 2>&1 && [[ "$CAST_BIN" == *.exe ]]; then PWARG=$(wslpath -w "$PWFILE")
elif command -v cygpath >/dev/null 2>&1; then PWARG=$(cygpath -w "$PWFILE")
else PWARG="$PWFILE"; fi
KS=(--account "$ACCOUNT" --password-file "$PWARG")

FROM=$(cast wallet address "${KS[@]}") || { echo "could not unlock $ACCOUNT (wrong password?) - nothing sent"; exit 1; }
echo "sender $FROM | balance $(cast balance "$FROM" --rpc-url "$RPC" --ether) ETH | gas price $(cast gas-price --rpc-url "$RPC") wei"
echo "needs roughly 142M gas in total (~0.00085 ETH at 0.006 gwei)."

for entry in "${POOLS[@]}"; do
  read -r name pool <<<"$entry"
  for target in 1700 2048; do
    n=$(next_of "$pool")
    if [ "$n" -ge "$target" ]; then echo "$name: already at $n (>= $target), skip"; continue; fi
    echo "$name: $n -> $target ..."
    out=$(cast send "$pool" 'increaseObservationCardinalityNext(uint16)' "$target" "${KS[@]}" --rpc-url "$RPC" --json)
    status=$(echo "$out" | sed -n 's/.*"status":"\(0x[0-9a-f]*\)".*/\1/p')
    hash=$(echo "$out" | sed -n 's/.*"transactionHash":"\(0x[0-9a-f]*\)".*/\1/p')
    gas=$(echo "$out" | sed -n 's/.*"gasUsed":"\(0x[0-9a-f]*\)".*/\1/p')
    echo "  tx $hash status $status gasUsed $((gas))"
    [ "$status" = "0x1" ] || { echo "  FAILED - stopping"; exit 1; }
  done
done

echo "--- after:"
for entry in "${POOLS[@]}"; do read -r name pool <<<"$entry"; echo "$name observationCardinalityNext = $(next_of "$pool")"; done
