// Block until getRound(ROUND).state == Finalized, then exit 0. Exits 2 if still not
// finalized at DEADLINE (unix seconds), so a stalled keeper is noticed before the window.
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const RPC = env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim();
const ROUNDS = '0xa8192D4Ee3526CA8158cBE83b2FC05BdC205bed3';
const ROUND = BigInt(process.env.ROUND || 4);
const DEADLINE = Number(process.env.DEADLINE || 0);
const STATES = ['None', 'Accumulating', 'Buying', 'Finalized'];
// getRound(uint256) selector 0x8f1327c0; state is the first word of the returned tuple
const data = '0x8f1327c0' + ROUND.toString(16).padStart(64, '0');

const rpc = async (method, params) => {
  const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message);
  return j.result;
};

(async () => {
  let last = null;
  for (;;) {
    try {
      const ret = await rpc('eth_call', [{ to: ROUNDS, data }, 'latest']);
      const state = STATES[parseInt(ret.slice(2, 66), 16)] || 'unknown';
      const now = new Date().toISOString();
      if (state !== last) { console.log(`${now} round ${ROUND} ${state}`); last = state; }
      if (state === 'Finalized') process.exit(0);
      if (DEADLINE && Date.now() / 1000 > DEADLINE) { console.log(`${now} STALLED: round ${ROUND} still ${state} at deadline`); process.exit(2); }
    } catch (e) {
      console.log(`${new Date().toISOString()} rpc error: ${e.message}`);
    }
    await new Promise((r) => setTimeout(r, 60_000));
  }
})();
