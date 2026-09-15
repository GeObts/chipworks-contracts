// Who opened each round, and who settled/finalized it.
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbiItem, formatUnits } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const c = createPublicClient({ chain: base, transport: http(env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim()) });
const ROUNDS = '0xa8192D4Ee3526CA8158cBE83b2FC05BdC205bed3';
const NAMES = { '0x6571e3412553fada40c3d96e61e7cfd20a0695b9': 'KEEPER', '0xe1096b727499a3f70fad8bc0267f5e69d01373c7': 'Safe' };
(async () => {
  const latest = await c.getBlockNumber();
  const logs = [];
  for (let a = 50208000n; a <= latest; a += 100000n) {
    logs.push(...await c.getLogs({ address: ROUNDS, event: parseAbiItem('event RoundOpened(uint256 indexed roundId, uint256 budget, address indexed opener)'), fromBlock: a, toBlock: a + 99999n > latest ? latest : a + 99999n }));
  }
  for (const l of logs) {
    const b = await c.getBlock({ blockNumber: l.blockNumber });
    const who = l.args.opener.toLowerCase();
    console.log(`round ${l.args.roundId} opened ${new Date(Number(b.timestamp) * 1000).toISOString()} budget $${formatUnits(l.args.budget, 6)} by ${NAMES[who] || l.args.opener}`);
  }
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
