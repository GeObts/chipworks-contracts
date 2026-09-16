// Is the round filling up, and who is filling it? Weight now vs earlier, plus recent contributeWeights txs.
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, parseAbiItem, getAddress } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const c = createPublicClient({ chain: base, transport: http(env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim()) });
const ROUNDS = '0xa8192D4Ee3526CA8158cBE83b2FC05BdC205bed3';
const KEEPER = '0x6571E3412553Fada40C3D96e61E7Cfd20A0695B9';
const R = parseAbi(['function getRound(uint256) view returns ((uint8 state,uint64 openedAt,uint64 finalizedAt,uint128 budget,uint128 spent,uint256 totalWeight))']);
const ROUND = BigInt(process.env.ROUND || 5);
const MINUTES = Number(process.env.MINUTES || 30);

(async () => {
  const head = await c.getBlock();
  const from = head.number - BigInt(MINUTES * 30);
  const [now, then] = await Promise.all([
    c.readContract({ address: ROUNDS, abi: R, functionName: 'getRound', args: [ROUND] }),
    c.readContract({ address: ROUNDS, abi: R, functionName: 'getRound', args: [ROUND], blockNumber: from }),
  ]);
  console.log(`round ${ROUND} weight ${MINUTES}m ago ${then.totalWeight} -> now ${now.totalWeight} (+${now.totalWeight - then.totalWeight})`);

  const logs = [];
  for (let a = from; a <= head.number; a += 5000n) {
    logs.push(...await c.getLogs({ address: ROUNDS, event: parseAbiItem('event WeightsContributed(uint256 indexed roundId, address indexed collection, uint256 count, uint256 weightAdded)'), fromBlock: a, toBlock: a + 4999n > head.number ? head.number : a + 4999n }));
  }
  const mine = logs.filter((l) => l.args.roundId === ROUND);
  const bySender = {};
  for (const l of mine) {
    const tx = await c.getTransaction({ hash: l.transactionHash });
    const who = getAddress(tx.from) === getAddress(KEEPER) ? 'KEEPER' : tx.from;
    bySender[who] ||= { txs: new Set(), nouns: 0, weight: 0n };
    bySender[who].txs.add(l.transactionHash);
    bySender[who].nouns += Number(l.args.count);
    bySender[who].weight += l.args.weightAdded;
  }
  console.log(`\ncontributions to round ${ROUND} in the last ${MINUTES}m:`);
  for (const [who, v] of Object.entries(bySender)) console.log(`  ${who}: ${v.txs.size} txs, ${v.nouns} Nouns, weight ${v.weight}`);
  if (!mine.length) console.log('  none');
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
