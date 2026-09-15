// Account for the POL holdback: what ChipRounds held back per round/stock, whether it is exactly
// holdbackBps of what was bought, whether it reached polTreasury, and what that wallet holds now.
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, parseAbiItem, formatUnits, getAddress } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const RPC = env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim();
const c = createPublicClient({ chain: base, transport: http(RPC, { batch: { batchSize: 50 } }) });

const ROUNDS = '0xa8192D4Ee3526CA8158cBE83b2FC05BdC205bed3';
const REGISTRY = '0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458';
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const RABI = parseAbi(['function polTreasury() view returns (address)', 'function holdbackBps() view returns (uint32)', 'function roundCount() view returns (uint256)',
  'function roundStocks(uint256) view returns (address[])']);
const REG = parseAbi(['function priceUsd(address) view returns (uint256, uint256)', 'function allTokens() view returns (address[])']);
const ERC20 = parseAbi(['function balanceOf(address) view returns (uint256)', 'function decimals() view returns (uint8)', 'function symbol() view returns (string)',
  'event Transfer(address indexed from, address indexed to, uint256 value)']);

const rpc = async (method, params) => {
  const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json(); if (j.error) throw new Error(j.error.message); return j.result;
};

(async () => {
  const latest = await c.getBlockNumber();
  const [pol, bps, n] = await Promise.all(['polTreasury', 'holdbackBps', 'roundCount'].map((f) => c.readContract({ address: ROUNDS, abi: RABI, functionName: f })));
  const POL = getAddress(pol);
  console.log(`polTreasury ${POL}  holdbackBps ${bps}  rounds ${n}`);
  const logs = async (event, address = ROUNDS, args) => { const out = []; for (let a = 50208000n; a <= latest; a += 100000n) out.push(...await c.getLogs({ address, event, args, fromBlock: a, toBlock: a + 99999n > latest ? latest : a + 99999n })); return out; };
  const bought = await logs(parseAbiItem('event StockBought(uint256 indexed roundId, address indexed stock, uint256 spent, uint256 received)'));
  const held = await logs(parseAbiItem('event HoldbackSent(uint256 indexed roundId, address indexed stock, uint256 amount)'));

  const meta = {};
  const info = async (t) => {
    if (meta[t]) return meta[t];
    const [sym, dec] = await Promise.all([c.readContract({ address: t, abi: ERC20, functionName: 'symbol' }), c.readContract({ address: t, abi: ERC20, functionName: 'decimals' })]);
    const px = t === USDC ? 1 : Number((await c.readContract({ address: REGISTRY, abi: REG, functionName: 'priceUsd', args: [t] }))[0]) / 1e18;
    return (meta[t] = { sym, dec: Number(dec), px });
  };

  const rows = [], problems = [];
  const perToken = {};
  const perRound = {};
  for (const b of bought) {
    const s = getAddress(b.args.stock), r = Number(b.args.roundId);
    const m = await info(s);
    const h = held.filter((x) => Number(x.args.roundId) === r && getAddress(x.args.stock) === s).reduce((a, x) => a + x.args.amount, 0n);
    const delivered = b.args.received; // StockBought's `received` is what reached the ledger, AFTER the holdback
    const gross = delivered + h;
    const expected = s === USDC ? 0n : (gross * BigInt(bps)) / 10000n;
    const spentUsd = Number(formatUnits(b.args.spent, 6));
    if (h !== expected) problems.push(`R${r} ${m.sym}: held ${h} expected ${expected}`);
    const heldUsdNow = Number(formatUnits(h, m.dec)) * m.px;
    const heldUsdAtCost = s === USDC ? 0 : spentUsd * Number(h) / Number(gross || 1n);
    rows.push({ round: r, sym: m.sym, spentUsd: spentUsd.toFixed(2), gross: formatUnits(gross, m.dec), toLedger: formatUnits(delivered, m.dec), heldBack: formatUnits(h, m.dec),
      pct: gross ? ((Number(h) / Number(gross)) * 100).toFixed(3) : '-', exact: h === expected, atCostUsd: heldUsdAtCost.toFixed(2), nowUsd: heldUsdNow.toFixed(2) });
    if (s !== USDC) {
      perToken[s] ||= { sym: m.sym, dec: m.dec, px: m.px, held: 0n };
      perToken[s].held += h;
      perRound[r] ||= { stockSpend: 0, heldAtCost: 0, heldNow: 0, usdcSlice: 0 };
      perRound[r].stockSpend += spentUsd; perRound[r].heldAtCost += heldUsdAtCost; perRound[r].heldNow += heldUsdNow;
    } else { perRound[r] ||= { stockSpend: 0, heldAtCost: 0, heldNow: 0, usdcSlice: 0 }; perRound[r].usdcSlice += spentUsd; }
  }
  rows.sort((a, b) => a.round - b.round || a.sym.localeCompare(b.sym));
  console.log('\n[per round / stock]'); console.table(rows);
  console.log('[per round]');
  console.table(Object.entries(perRound).map(([r, v]) => ({ round: r, usdcSliceUsd: v.usdcSlice.toFixed(2), stockSpendUsd: v.stockSpend.toFixed(2), expected15pctUsd: (v.stockSpend * Number(bps) / 10000).toFixed(2), heldAtCostUsd: v.heldAtCost.toFixed(2), heldNowUsd: v.heldNow.toFixed(2) })));

  // Did it arrive? Transfer logs ChipRounds -> POL per token, and what POL holds now / sent onward
  const walletRows = [];
  let totalHeldNow = 0, totalBalNow = 0;
  for (const [t, v] of Object.entries(perToken)) {
    const inLogs = await logs(parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'), t, { from: ROUNDS, to: POL });
    const arrived = inLogs.reduce((a, l) => a + l.args.value, 0n);
    const bal = await c.readContract({ address: t, abi: ERC20, functionName: 'balanceOf', args: [POL] });
    if (arrived !== v.held) problems.push(`${v.sym}: HoldbackSent ${v.held} but Transfer ChipRounds->POL ${arrived}`);
    totalHeldNow += Number(formatUnits(v.held, v.dec)) * v.px;
    totalBalNow += Number(formatUnits(bal, v.dec)) * v.px;
    walletRows.push({ sym: v.sym, heldBackTotal: formatUnits(v.held, v.dec), transferLogsToWallet: formatUnits(arrived, v.dec), walletBalanceNow: formatUnits(bal, v.dec),
      price: v.px.toFixed(2), heldBackUsdNow: (Number(formatUnits(v.held, v.dec)) * v.px).toFixed(2), walletUsdNow: (Number(formatUnits(bal, v.dec)) * v.px).toFixed(2) });
  }
  console.log(`\n[wallet ${POL}]`); console.table(walletRows);
  console.log(`total held back, valued now: $${totalHeldNow.toFixed(2)}   wallet holds of those tokens now: $${totalBalNow.toFixed(2)}`);

  // Anything leave the wallet in those tokens?
  const outs = await rpc('alchemy_getAssetTransfers', [{ fromAddress: POL, fromBlock: '0x2fe1e40', category: ['erc20'], contractAddresses: Object.keys(perToken), withMetadata: true, maxCount: '0x3e8' }]);
  console.log(`outgoing stock-token transfers from wallet: ${outs.transfers.length}`);
  for (const t of outs.transfers.slice(0, 15)) console.log(`  ${t.metadata.blockTimestamp} ${t.value} ${t.asset} -> ${t.to}`);
  console.log(`\nproblems: ${JSON.stringify(problems)}`);
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
