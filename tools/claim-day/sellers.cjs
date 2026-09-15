// For every wallet owed credit: does it still hold the Noun(s) it chipped, and if not, where did they go?
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, parseAbiItem, getAddress } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const RPC = env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim();
const rd = (f) => JSON.parse(fs.readFileSync(path.join(__dirname, f), 'utf8').replace(/^\uFEFF/, ''));
const ROUNDS_ABI = rd('rounds.abi.json');
const S = rd('sweep.out.json');
const c = createPublicClient({ chain: base, transport: http(RPC, { batch: { batchSize: 50 } }) });

const ROUNDS = '0xa8192D4Ee3526CA8158cBE83b2FC05BdC205bed3';
const V2 = '0x762984092Cb9404982835551970C73b5838d5411';
const KNOWN = {
  '0x123Bc476594A80B0d99Ca6510e87E249b1C5EC5f': 'NounLoans',
  '0x93Ac0B6C249c1497429Bc4863C697475DF0Acd4c': 'Anvil',
  '0x411a505b81546beA83305298c14EF5F8c9b10bA5': 'Furnace',
  '0xe1096B727499a3f70FaD8bc0267F5e69d01373C7': 'Safe',
  '0x000000000000000000000000000000000000dEaD': 'burn(0xdEaD)',
};
const V2ABI = parseAbi([
  'function isCustodian(address) view returns (bool)',
  'function activation(address,uint256) view returns (bool,uint32,address)',
  'function effectiveOwner(address,uint256) view returns (address)',
]);
const NFT = parseAbi(['function ownerOf(uint256) view returns (address)', 'function balanceOf(address) view returns (uint256)']);

async function logs(event, from, to) {
  const out = [];
  for (let a = from; a <= to; a += 100000n) out.push(...(await c.getLogs({ address: V2, event, fromBlock: a, toBlock: a + 99999n > to ? to : a + 99999n })));
  return out;
}

(async () => {
  const latest = await c.getBlockNumber();
  const src = await c.readContract({ address: ROUNDS, abi: ROUNDS_ABI, functionName: 'activationSource' });
  console.log(`ChipRounds.activationSource = ${src} (V2? ${getAddress(src) === getAddress(V2)})`);
  for (const [a, n] of Object.entries(KNOWN)) {
    const isC = await c.readContract({ address: V2, abi: V2ABI, functionName: 'isCustodian', args: [a] });
    if (isC) console.log(`registered custodian: ${n} ${a}`);
  }
  const act = await logs(parseAbiItem('event Activated(address indexed collection, uint256 indexed tokenId, address indexed owner, uint8 tier, uint256 chipBurned)'), 50208000n, latest);
  const flat = await logs(parseAbiItem('event ActivatedFlat(address indexed collection, uint256 indexed tokenId, address indexed owner, uint256 sacrificeId, uint256 chipCost, bool sacrificeTrueBurned)'), 50208000n, latest);
  const byOwner = {};
  for (const l of [...act, ...flat]) (byOwner[getAddress(l.args.owner)] ||= []).push({ collection: getAddress(l.args.collection), tokenId: l.args.tokenId });
  const collections = [...new Set([...act, ...flat].map((l) => getAddress(l.args.collection)))];
  console.log('collections', collections.map((x) => x + ' flat=' + flat.some((l) => getAddress(l.args.collection) === x)));
  console.log(`activations: ${act.length} tiered + ${flat.length} flat, collections ${collections.length}`);

  const owed = [...new Set(S.positions.map((p) => getAddress(p.owner)))];
  const rows = [];
  const cats = {};
  for (const w of owed) {
    const cols = process.env.EXCLUDE ? collections.filter((x) => x.toLowerCase() !== process.env.EXCLUDE.toLowerCase()) : collections;
    const bals = await Promise.all(cols.map((col) => c.readContract({ address: col, abi: NFT, functionName: 'balanceOf', args: [w] }).catch(() => 0n)));
    const held = bals.reduce((a, b) => a + b, 0n);
    const toks = (byOwner[w] || []).filter((t) => cols.includes(t.collection));
    const fate = [];
    for (const t of toks) {
      const [own, eff, [active]] = await Promise.all([
        c.readContract({ address: t.collection, abi: NFT, functionName: 'ownerOf', args: [t.tokenId] }).catch(() => null),
        c.readContract({ address: V2, abi: V2ABI, functionName: 'effectiveOwner', args: [t.collection, t.tokenId] }),
        c.readContract({ address: V2, abi: V2ABI, functionName: 'activation', args: [t.collection, t.tokenId] }),
      ]);
      const o = own ? getAddress(own) : null;
      const where = !o ? 'burned/none' : o === w ? 'still held' : KNOWN[o] ? `${KNOWN[o]}${getAddress(eff) === w ? ' (custody, still yours)' : ''}` : 'another wallet';
      fate.push(`${where}${active ? ' [active]' : ''}`);
    }
    if (held === 0n) {
      const k = fate.length ? [...new Set(fate)].sort().join(' + ') : 'no V2 activation by this address';
      cats[k] = (cats[k] || 0) + 1;
      rows.push({ wallet: w, nounsHeld: held.toString(), chippedTokens: toks.length, fate: k });
    }
  }
  console.log(`\nowed wallets: ${owed.length}; holding ZERO tokens in the chipped collections: ${rows.length}`);
  console.log(cats);
  console.table(rows);
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<rpc>')); process.exit(1); });
