// Is the keeper actually funding the Pot? Chain + explorer, not the keeper's own /health.
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, parseAbiItem, formatUnits, formatEther, getAddress, decodeFunctionData } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const RPC = env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim();
const SCANKEY = (env.match(/^BASESCAN_API_KEY=(.*)$/m) || [])[1]?.trim();
const c = createPublicClient({ chain: base, transport: http(RPC, { batch: { batchSize: 50 } }) });

const KEEPER = '0x6571E3412553Fada40C3D96e61E7Cfd20A0695B9';
const POT = '0x3918a9B479Ce9B58238584c645079AB3bB49855B';
const SPLITTER = '0xb9b76e1835afE05e5A73065FE01A19B14869F8A3';
const ROUNDS = '0xa8192D4Ee3526CA8158cBE83b2FC05BdC205bed3';
const SAFE = '0xe1096B727499a3f70FaD8bc0267F5e69d01373C7';
const WETH = '0x4200000000000000000000000000000000000006';
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const NAMES = {
  [POT]: 'Pot', [SPLITTER]: 'FeeSplitter', [ROUNDS]: 'ChipRounds', '0x9982538F41f2ae29ddb9d3D9307010052984FDbB': 'BankrDistributor',
  '0x7Bc1C03e843C37845d89B54667382b4577Ead5C0': 'ChipBurner', '0x9bD35c70a80F132d087719305E37A888204d4c80': 'ChipClaims',
  '0x123Bc476594A80B0d99Ca6510e87E249b1C5EC5f': 'NounLoans', [SAFE]: 'Safe',
};
const nm = (a) => NAMES[getAddress(a)] || a;
const ERC20 = parseAbi(['function balanceOf(address) view returns (uint256)']);
const POTABI = parseAbi([
  'function available() view returns (uint256)', 'function routedTokens() view returns (address[])',
  'function convertibleBalance(address) view returns (uint256)', 'function nextConversionAmount(address) view returns (uint256)',
  'function convertibleBalance() view returns (uint256)',
]);
const SPLITABI = parseAbi(['function distributableEth() view returns (uint256)']);
const SELECTORS = {};
for (const f of ['collectFees(bytes32)', 'convert()', 'convert(uint256)', 'convert(address)', 'convert(address,uint256)', 'distributeETH()', 'distributeAll(address[])',
  'distributeTokens(address[])', 'distributeToken(address)', 'openRound()', 'contributeWeights(uint256,address,uint256[])', 'closeAccumulation(uint256)',
  'settleStock(uint256,address)', 'finalizeRound(uint256)', 'burn()', 'burnAll()', 'sweepExpired(uint256,address,uint256)', 'sweepExpired(uint256,address)']) {
  const { keccak256, toHex } = req('viem');
  SELECTORS[keccak256(toHex(f)).slice(0, 10)] = f;
}

const scan = async (params) => {
  if (!SCANKEY) return { status: '0', result: 'no BASESCAN_API_KEY' };
  const u = new URL('https://api.etherscan.io/v2/api');
  Object.entries({ chainid: 8453, apikey: SCANKEY, ...params }).forEach(([k, v]) => u.searchParams.set(k, v));
  return (await fetch(u)).json();
};

(async () => {
  const blk = await c.getBlock();
  const now = Number(blk.timestamp);
  const ago = (t) => `${((now - Number(t)) / 3600).toFixed(1)}h ago`;
  console.log(`block ${blk.number} ${new Date(now * 1000).toISOString()}`);

  // ---- 1 + 5: keeper nonce trajectory and gas
  const hrs = [0, 1, 3, 6, 12, 24, 48];
  const traj = [];
  for (const h of hrs) {
    const bn = blk.number - BigInt(h * 1800);
    const [n, b] = await Promise.all([c.getTransactionCount({ address: KEEPER, blockNumber: bn }), c.getBalance({ address: KEEPER, blockNumber: bn })]);
    traj.push({ hoursAgo: h, nonce: n, eth: Number(formatEther(b)).toFixed(6) });
  }
  const pending = await c.getTransactionCount({ address: KEEPER, blockTag: 'pending' });
  console.log('\n[keeper nonce + ETH over time]'); console.table(traj);
  console.log(`pending nonce ${pending} (latest ${traj[0].nonce}) -> ${pending > traj[0].nonce ? 'STUCK/QUEUED TXS IN MEMPOOL' : 'no queued txs'}`);
  const gasPrice = await c.getGasPrice();
  console.log(`gasPrice ${formatUnits(gasPrice, 9)} gwei`);

  // ---- keeper tx history from the explorer
  const tx = await scan({ module: 'account', action: 'txlist', address: KEEPER, startblock: 0, endblock: 99999999, sort: 'desc', page: 1, offset: 400 });
  if (Array.isArray(tx.result)) {
    const rows = tx.result;
    const since48 = rows.filter((r) => now - Number(r.timeStamp) < 48 * 3600);
    const byFn = {};
    let gasEth = 0n;
    for (const r of since48) {
      const fn = SELECTORS[r.input.slice(0, 10)] || r.functionName?.split('(')[0] || r.input.slice(0, 10);
      const k = `${fn} -> ${nm(r.to)}`;
      byFn[k] ||= { ok: 0, failed: 0, last: 0 };
      byFn[k][r.isError === '0' ? 'ok' : 'failed']++;
      byFn[k].last = Math.max(byFn[k].last, Number(r.timeStamp));
      gasEth += BigInt(r.gasUsed) * BigInt(r.gasPrice);
    }
    console.log(`\n[keeper txs, last 48h: ${since48.length}; last tx ${rows[0] ? ago(rows[0].timeStamp) : 'never'}; gas spent 48h ${formatEther(gasEth)} ETH]`);
    console.table(Object.entries(byFn).map(([k, v]) => ({ call: k, ok: v.ok, failed: v.failed, last: ago(v.last) })));
    console.log('[last 12 txs]');
    console.table(rows.slice(0, 12).map((r) => ({ when: ago(r.timeStamp), nonce: r.nonce, call: SELECTORS[r.input.slice(0, 10)] || r.input.slice(0, 10), to: nm(r.to), ok: r.isError === '0' })));
  } else console.log('explorer txlist failed:', String(tx.result).slice(0, 120));

  // ---- 2: Pot state
  const [ethBal, wethBal, usdc, routed, nextWeth] = await Promise.all([
    c.getBalance({ address: POT }), c.readContract({ address: WETH, abi: ERC20, functionName: 'balanceOf', args: [POT] }),
    c.readContract({ address: POT, abi: POTABI, functionName: 'available' }), c.readContract({ address: POT, abi: POTABI, functionName: 'routedTokens' }),
    c.readContract({ address: POT, abi: POTABI, functionName: 'nextConversionAmount', args: [WETH] }).catch((e) => `ERR ${e.shortMessage}`),
  ]);
  console.log(`\n[Pot now] ETH ${formatEther(ethBal)}  WETH ${formatEther(wethBal)}  USDC available ${formatUnits(usdc, 6)}  nextConversionAmount(WETH) ${typeof nextWeth === 'bigint' ? formatEther(nextWeth) : nextWeth}`);
  for (const t of routed) {
    const cb = await c.readContract({ address: POT, abi: POTABI, functionName: 'convertibleBalance', args: [t] }).catch((e) => `ERR ${e.shortMessage}`);
    console.log(`  route ${t}: convertibleBalance ${typeof cb === 'bigint' ? cb.toString() : cb}`);
  }

  // Pot history: conversions, budget pulls, returns, over 7 days
  const from = blk.number - BigInt(7 * 86400 * 2);
  const getl = async (address, event) => { const out = []; for (let a = from; a <= blk.number; a += 100000n) out.push(...await c.getLogs({ address, event, fromBlock: a, toBlock: a + 99999n > blk.number ? blk.number : a + 99999n })); return out; };
  const tsOf = {};
  const when = async (l) => (tsOf[l.blockNumber] ||= Number((await c.getBlock({ blockNumber: l.blockNumber })).timestamp));
  const conv = await getl(POT, parseAbiItem('event Converted(address indexed token, uint256 amountIn, uint256 quoteOut, uint256 minOut, address indexed caller)'));
  const pulled = await getl(POT, parseAbiItem('event BudgetPulled(address indexed to, uint256 amount)'));
  const ret = await getl(POT, parseAbiItem('event Returned(address indexed from, uint256 amount)'));
  console.log(`\n[Pot Converted events, 7d: ${conv.length}]`);
  console.table(await Promise.all(conv.map(async (l) => ({ when: ago(await when(l)), token: nm(l.args.token), in: formatEther(l.args.amountIn), usdcOut: formatUnits(l.args.quoteOut, 6), caller: l.args.caller === KEEPER ? 'KEEPER' : nm(l.args.caller) }))));
  console.log(`[BudgetPulled 7d]`); console.table(await Promise.all(pulled.map(async (l) => ({ when: ago(await when(l)), usdc: formatUnits(l.args.amount, 6) }))));
  console.log(`[Returned 7d]`); console.table(await Promise.all(ret.map(async (l) => ({ when: ago(await when(l)), usdc: formatUnits(l.args.amount, 6), from: nm(l.args.from) }))));

  // ETH arriving at the Pot (internal txs) and tokens arriving
  const itx = await scan({ module: 'account', action: 'txlistinternal', address: POT, startblock: 0, endblock: 99999999, sort: 'desc', page: 1, offset: 200 });
  if (Array.isArray(itx.result)) {
    const inbound = itx.result.filter((r) => getAddress(r.to) === getAddress(POT) && r.value !== '0');
    const out = itx.result.filter((r) => getAddress(r.from) === getAddress(POT) && r.value !== '0');
    console.log(`\n[ETH into Pot (internal): ${inbound.length}, total ${formatEther(inbound.reduce((a, r) => a + BigInt(r.value), 0n))} ETH; out: ${out.length}]`);
    console.table(inbound.slice(0, 10).map((r) => ({ when: ago(r.timeStamp), eth: formatEther(r.value), from: nm(r.from) })));
  } else console.log('internal txlist:', String(itx.result).slice(0, 100));
  const ttx = await scan({ module: 'account', action: 'tokentx', address: POT, startblock: 0, endblock: 99999999, sort: 'desc', page: 1, offset: 200 });
  if (Array.isArray(ttx.result)) {
    const agg = {};
    for (const r of ttx.result) {
      const dir = getAddress(r.to) === getAddress(POT) ? 'IN' : 'OUT';
      const k = `${dir} ${r.tokenSymbol} ${dir === 'IN' ? 'from ' + nm(r.from) : 'to ' + nm(r.to)}`;
      agg[k] ||= { n: 0, amount: 0, last: 0 };
      agg[k].n++; agg[k].amount += Number(formatUnits(BigInt(r.value), Number(r.tokenDecimal))); agg[k].last = Math.max(agg[k].last, Number(r.timeStamp));
    }
    console.log(`\n[Pot token transfers, all time]`);
    console.table(Object.entries(agg).map(([k, v]) => ({ flow: k, count: v.n, amount: v.amount.toFixed(6), last: ago(v.last) })));
  }

  // ---- 4: fees + distribution
  const [spEth, spDist, spWeth] = await Promise.all([c.getBalance({ address: SPLITTER }), c.readContract({ address: SPLITTER, abi: SPLITABI, functionName: 'distributableEth' }).catch(() => null), c.readContract({ address: WETH, abi: ERC20, functionName: 'balanceOf', args: [SPLITTER] })]);
  console.log(`\n[FeeSplitter now] ETH ${formatEther(spEth)} distributable ${spDist === null ? '?' : formatEther(spDist)} WETH ${formatEther(spWeth)}`);
  const dist = await getl(SPLITTER, parseAbiItem('event Distributed(address indexed asset, uint256 potAmount, uint256 opsAmount, uint256 polAmount, address indexed caller)')).catch((e) => { console.log('Distributed log read failed (signature guess):', e.shortMessage); return []; });
  console.log(`[FeeSplitter Distributed 7d: ${dist.length}]`);
  console.table(await Promise.all(dist.slice(-10).map(async (l) => ({ when: ago(await when(l)), asset: nm(l.args.asset), pot: l.args.potAmount.toString(), ops: l.args.opsAmount.toString(), pol: l.args.polAmount.toString(), caller: l.args.caller === KEEPER ? 'KEEPER' : nm(l.args.caller) }))));
  const sitx = await scan({ module: 'account', action: 'txlistinternal', address: SPLITTER, startblock: 0, endblock: 99999999, sort: 'desc', page: 1, offset: 100 });
  if (Array.isArray(sitx.result)) {
    const inbound = sitx.result.filter((r) => getAddress(r.to) === getAddress(SPLITTER) && r.value !== '0');
    console.log(`[ETH into FeeSplitter (internal): ${inbound.length}, total ${formatEther(inbound.reduce((a, r) => a + BigInt(r.value), 0n))}; latest ${inbound[0] ? ago(inbound[0].timeStamp) + ' from ' + nm(inbound[0].from) : 'none'}]`);
  }
  const safeEth = await c.getBalance({ address: SAFE });
  console.log(`[Safe ETH ${formatEther(safeEth)}]`);
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
