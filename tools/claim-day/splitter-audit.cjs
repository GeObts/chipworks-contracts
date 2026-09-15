// FeeSplitter audit: config, every inflow by source (all time), every distribution and whether each leg
// landed, what is sitting in it now, and which wired income sources point at it.
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, parseAbiItem, formatUnits, formatEther, getAddress } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const RPC = env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim();
const c = createPublicClient({ chain: base, transport: http(RPC, { batch: { batchSize: 50 } }) });

const SPLITTER = '0xb9b76e1835afE05e5A73065FE01A19B14869F8A3';
const POT = '0x3918a9B479Ce9B58238584c645079AB3bB49855B';
const SAFE = '0xe1096B727499a3f70FaD8bc0267F5e69d01373C7';
const ANVIL = '0x93Ac0B6C249c1497429Bc4863C697475DF0Acd4c';
const LOANS = '0x123Bc476594A80B0d99Ca6510e87E249b1C5EC5f';
const V2 = '0x762984092Cb9404982835551970C73b5838d5411';
const CHIP = '0x75Af968d2e58749FDA1b42C58186B76f5E511bA3';
const WETH = '0x4200000000000000000000000000000000000006';
const DISTRIBUTOR = '0x9982538F41f2ae29ddb9d3D9307010052984FDbB';
const NAMES = { [SPLITTER]: 'FeeSplitter', [POT]: 'Pot', [SAFE]: 'Safe', [ANVIL]: 'Anvil', [LOANS]: 'NounLoans', [V2]: 'ChipActivationV2', [DISTRIBUTOR]: 'BankrDistributor',
  '0xcd2f7B2272f860A7a60e25ff6cdd0BdD0A9FCEFa': 'your wallet 0xcd2f', '0x6571E3412553Fada40C3D96e61E7Cfd20A0695B9': 'KEEPER', '0x7Bc1C03e843C37845d89B54667382b4577Ead5C0': 'ChipBurner',
  '0x411a505b81546beA83305298c14EF5F8c9b10bA5': 'Furnace', '0x35325dD7e972780C3aDef20E9675a4264a8a57fb': 'POL wallet 0x3532' };
const nm = (a) => (a ? NAMES[getAddress(a)] || a : '?');
const rpc = async (method, params) => {
  const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json(); if (j.error) throw new Error(`${method}: ${j.error.message}`); return j.result;
};
async function transfers(q) {
  const out = []; let pageKey;
  do { const r = await rpc('alchemy_getAssetTransfers', [{ fromBlock: '0x2fe1e40', ...q, withMetadata: true, excludeZeroValue: true, maxCount: '0x3e8', ...(pageKey ? { pageKey } : {}) }]); out.push(...r.transfers); pageKey = r.pageKey; } while (pageKey);
  return out;
}
const read = (address, sig, args = []) => c.readContract({ address, abi: parseAbi([sig]), functionName: sig.match(/function (\w+)/)[1], args }).catch((e) => `ERR ${e.shortMessage}`);

(async () => {
  const now = Number((await c.getBlock()).timestamp);
  const ago = (iso) => `${((now - Date.parse(iso) / 1000) / 3600).toFixed(1)}h`;

  // ---- config
  const cfg = {
    opsBps: await read(SPLITTER, 'function opsBps() view returns (uint32)'), polShareBps: await read(SPLITTER, 'function polShareBps() view returns (uint32)'),
    potBps: await read(SPLITTER, 'function potBps() view returns (uint32)'), maxOpsBps: await read(SPLITTER, 'function maxOpsBps() view returns (uint32)'),
    MAX_POL_SHARE_BPS: await read(SPLITTER, 'function MAX_POL_SHARE_BPS() view returns (uint32)'), pot: nm(await read(SPLITTER, 'function pot() view returns (address)')),
    ops: nm(await read(SPLITTER, 'function ops() view returns (address)')), polTreasury: await read(SPLITTER, 'function polTreasury() view returns (address)'),
    totalOwedEth: await read(SPLITTER, 'function totalOwedEth() view returns (uint256)'), owner: nm(await read(SPLITTER, 'function owner() view returns (address)')),
  };
  console.log('[config]', cfg);

  // ---- who is wired to pay it
  console.log('[wired income sources]');
  console.log('  Anvil.feeSplitter          =', nm(await read(ANVIL, 'function feeSplitter() view returns (address)')));
  console.log('  NounLoans.feeSplitter      =', nm(await read(LOANS, 'function feeSplitter() view returns (address)')));
  console.log('  ChipActivationV2.feeCollector =', nm(await read(V2, 'function feeCollector() view returns (address)')), ' burnBps', await read(V2, 'function burnBps() view returns (uint32)'));
  const shares = await read(DISTRIBUTOR, 'function getShares(bytes32, address) view returns (uint256)', ['0xbcdd8383e38069f626846b94e93ee4d2c00cadfcce4b9457b0b8b04289030345', SPLITTER]);
  console.log('  Bankr getShares(FeeSplitter) =', typeof shares === 'bigint' ? `${(Number(shares) / 1e16).toFixed(2)}%` : shares);

  // ---- every inflow, all time
  const inn = await transfers({ toAddress: SPLITTER, category: ['external', 'internal', 'erc20', 'erc721', 'erc1155'] });
  const g = {};
  for (const t of inn) {
    const k = `${t.asset || t.rawContract?.address || t.category} from ${nm(t.from)}`;
    g[k] ||= { count: 0, total: 0, first: t.metadata.blockTimestamp, last: t.metadata.blockTimestamp };
    g[k].count++; g[k].total += Number(t.value || 0); g[k].last = t.metadata.blockTimestamp;
  }
  console.log(`\n[ALL inflows to FeeSplitter since deploy: ${inn.length}]`);
  console.table(Object.entries(g).map(([k, v]) => ({ flow: k, count: v.count, total: v.total.toFixed(8), firstAgoH: ago(v.first), lastAgoH: ago(v.last) })));

  // ---- every outflow
  const out = await transfers({ fromAddress: SPLITTER, category: ['external', 'internal', 'erc20'] });
  const og = {};
  for (const t of out) { const k = `${t.asset} to ${nm(t.to)}`; og[k] ||= { count: 0, total: 0, last: '' }; og[k].count++; og[k].total += Number(t.value || 0); og[k].last = ago(t.metadata.blockTimestamp); }
  console.log(`[ALL outflows from FeeSplitter]`);
  console.table(Object.entries(og).map(([k, v]) => ({ flow: k, count: v.count, total: v.total.toFixed(8), lastAgoH: v.last })));

  // ---- each Distributed event: ratio, and did the legs land (match outflows in the same tx)
  const latest = await c.getBlockNumber();
  const dist = [], esc = [];
  for (let a = 50208000n; a <= latest; a += 100000n) {
    const to = a + 99999n > latest ? latest : a + 99999n;
    dist.push(...await c.getLogs({ address: SPLITTER, event: parseAbiItem('event Distributed(address indexed asset, uint256 potAmount, uint256 opsAmount, uint256 polAmount, address indexed caller)'), fromBlock: a, toBlock: to }));
    esc.push(...await c.getLogs({ address: SPLITTER, event: parseAbiItem('event EthEscrowed(address indexed recipient, uint256 amount, uint256 totalOwed)'), fromBlock: a, toBlock: to }));
  }
  console.log(`\n[Distributed events: ${dist.length}; EthEscrowed events: ${esc.length}]`);
  console.table(dist.map((d) => {
    const legs = out.filter((t) => t.hash === d.transactionHash);
    const potGot = legs.filter((t) => getAddress(t.to) === POT).reduce((a, t) => a + Number(t.value), 0);
    const opsGot = legs.filter((t) => getAddress(t.to) === SAFE).reduce((a, t) => a + Number(t.value), 0);
    const tot = d.args.potAmount + d.args.opsAmount + d.args.polAmount;
    const dec = 18;
    return { tx: d.transactionHash.slice(0, 12), asset: d.args.asset === '0x0000000000000000000000000000000000000000' ? 'ETH' : nm(d.args.asset), caller: nm(d.args.caller),
      total: formatUnits(tot, dec), potPct: ((Number(d.args.potAmount) / Number(tot)) * 100).toFixed(3), opsPct: ((Number(d.args.opsAmount) / Number(tot)) * 100).toFixed(3),
      polPct: ((Number(d.args.polAmount) / Number(tot)) * 100).toFixed(3), potLanded: potGot.toFixed(8) === Number(formatUnits(d.args.potAmount, dec)).toFixed(8),
      opsLanded: opsGot.toFixed(8) === Number(formatUnits(d.args.opsAmount, dec)).toFixed(8) };
  }));

  // ---- what sits in it now
  const bal = await rpc('alchemy_getTokenBalances', [SPLITTER, 'erc20']);
  const ethBal = await c.getBalance({ address: SPLITTER });
  console.log(`\n[sitting in FeeSplitter now] ETH ${formatEther(ethBal)}`);
  for (const t of bal.tokenBalances.filter((x) => BigInt(x.tokenBalance) > 0n)) {
    const m = await rpc('alchemy_getTokenMetadata', [t.contractAddress]);
    console.log(`  ${m.symbol} (${t.contractAddress}) ${formatUnits(BigInt(t.tokenBalance), m.decimals ?? 18)}`);
  }

  // ---- loan fees: have any been charged at all?
  const loanChipToSplitter = inn.filter((t) => getAddress(t.from) === LOANS);
  console.log(`\n[NounLoans -> FeeSplitter CHIP fee transfers: ${loanChipToSplitter.length}]`);
  const loanEvents = await transfers({ fromAddress: LOANS, category: ['erc20'], contractAddresses: [CHIP] });
  console.log(`[NounLoans CHIP outflows total: ${loanEvents.length} (loans disbursed / fees / liquidations)]`);
  const loanDests = {};
  for (const t of loanEvents) { const k = nm(t.to); loanDests[k] = (loanDests[k] || 0) + 1; }
  console.log(Object.entries(loanDests).sort((a, b) => b[1] - a[1]).slice(0, 8));
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
