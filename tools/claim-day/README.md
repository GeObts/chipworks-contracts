# claim-day

Verifies ChipClaims against LIVE Base before a claim window opens. Run in order,
from this directory (viem is borrowed from `~/chipworks/node_modules`, the RPC
from `../../.env` `BASE_RPC_URL`):

    node sweep.cjs                       # solvency + every holder's claimable, pinned to one block
    FROM=50208000 node events.cjs        # ledger vs StockBought / AcquiredRecorded / WeightCredited history
    node sim.cjs                         # eth_simulateV1: everyone claims at opensAt, repeats, attacker, gate, expiry

Each ends with `problems: []` when everything holds. `sweep.cjs` writes
`sweep.out.json`, which the other two read, so run it first.

`sim.cjs` uses `eth_simulateV1` rather than a forge fork on purpose: B20 stocks
are node-native precompiles that cannot execute in a fork (see
`test/fork/B20Probe.t.sol`), but do execute under simulation on the real node.

Regenerate the ABIs after any contract change:
`forge inspect ChipClaims abi --json > claims.abi.json` (same for ChipRounds).
