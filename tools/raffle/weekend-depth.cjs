// SPEC-v2 §2.5 pre-deploy check: pool depth and pricing across weekends, READ-ONLY.
// For every enabled stock's Slipstream pool, samples every SAMPLE_HOURS across each window:
// active liquidity, the pool's USDC balance, spot vs TWAP (15/30/60 min), and — the real test —
// eth_call of a $BUY_USD exactInputSingle on the REAL router at that historical block (USDC
// balance/allowance via state override; nothing is sent), evaluated against Raffle v2's four
// checks with the contract's own maths (TWAP-available, |spot-TWAP| <= dev, fill >= floor,
// buy <= share of pool USDC). Also counts Swap/Mint/Burn events per window and compares the
// pool price with Chainlink at Monday's open (fairness of weekend pricing).
//   node tools/raffle/weekend-depth.cjs            -> prints the report, writes JSON next to it
// Windows (UTC) can be overridden: WINDOWS='name:startISO:endISO,...'
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, encodeFunctionData, decodeFunctionResult, keccak256, encodeAbiParameters, pad, toHex, parseAbi, parseAbiItem } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs'), path = require('path');
const ROOT = path.resolve(__dirname, '../..');
const RPC = fs.readFileSync(path.join(ROOT, '.env'), 'utf8').match(/^BASE_RPC_URL=(.*)$/m)[1].trim();
const c = createPublicClient({ chain: base, transport: http(RPC, { batch: false, retryCount: 5, retryDelay: 400 }) });

const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', REGISTRY = '0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458';
const ROUTER = '0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F', SIM = '0x00000000000000000000000000000000005157e5';
const BUY_USD = BigInt(process.env.BUY_USD ?? 1000);
const SAMPLE_HOURS = Number(process.env.SAMPLE_HOURS ?? 2);
// Raffle v2 launch guard
const GUARD = { twap: 1800, dev: 100, slipBps: 150n, shareBps: 100n };
const WINDOWS = (process.env.WINDOWS ?? [
  'weekend-0926:2026-09-25T20:00:00Z:2026-09-28T13:30:00Z',
  'weekend-1003:2026-10-02T20:00:00Z:2026-10-05T13:30:00Z',
  'weekday-1006:2026-10-06T13:30:00Z:2026-10-08T20:00:00Z',
  'weekend-1010-sofar:2026-10-09T20:00:00Z:now',
].join(',')).split(',').map((s) => { const [name, a, b] = s.split(/:(?=\d{4}-|now)/); return { name, start: a, end: b }; });

const REG = parseAbi([
  'function enabledTokens() view returns (address[])',
  'function getStock(address) view returns ((address pool,uint24 fee,int24 tickSpacing,bool registered,bool enabled,uint8 venue,address feed,uint8 tokenDecimals,uint8 feedDecimals,uint128 minLiquidityUsd))',
  'function priceUsd(address) view returns (uint256,uint256)',
]);
const ERC = parseAbi(['function symbol() view returns (string)', 'function balanceOf(address) view returns (uint256)']);
const POOL = parseAbi(['function slot0() view returns (uint160,int24,uint16,uint16,uint16,bool)', 'function liquidity() view returns (uint128)', 'function observe(uint32[]) view returns (int56[],uint160[])']);
const ROUTER_ABI = parseAbi(['function exactInputSingle((address tokenIn,address tokenOut,int24 tickSpacing,address recipient,uint256 deadline,uint256 amountIn,uint256 amountOutMinimum,uint160 sqrtPriceLimitX96)) payable returns (uint256)']);
const SWAP = parseAbiItem('event Swap(address indexed sender, address indexed recipient, int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick)');
const MINT = parseAbiItem('event Mint(address sender, address indexed owner, int24 indexed tickLower, int24 indexed tickUpper, uint128 amount, uint256 amount0, uint256 amount1)');
const BURN = parseAbiItem('event Burn(address indexed owner, int24 indexed tickLower, int24 indexed tickUpper, uint128 amount, uint256 amount0, uint256 amount1)');

// ---- Raffle v2's own price maths, ported 1:1 (Raffle._spotOut/_tickPowWad/_refOut/_twapTick) ----
const WAD = 10n ** 18n, Q64 = 1n << 64n, Q128 = 1n << 128n, Q192 = 1n << 192n, U128 = (1n << 128n) - 1n;
const spotOut = (sqrtP, amountIn, zeroForOne) => {
  if (sqrtP <= U128) { const r = sqrtP * sqrtP; return zeroForOne ? (r * amountIn) / Q192 : (Q192 * amountIn) / r; }
  const r = (sqrtP * sqrtP) / Q64; return zeroForOne ? (r * amountIn) / Q128 : (Q128 * amountIn) / r;
};
const tickPow = (n) => { let res = WAD, b = 10001n * 10n ** 14n; while (n > 0n) { if (n & 1n) res = (res * b) / WAD; b = (b * b) / WAD; n >>= 1n; } return res; };
const refOut = (sqrtP, spotTick, twapTick, amountIn, usdcIsToken0) => {
  const s = spotOut(sqrtP, amountIn, usdcIsToken0);
  let k = BigInt(twapTick - spotTick); if (!usdcIsToken0) k = -k;
  return k >= 0n ? (s * tickPow(k)) / WAD : (s * WAD) / tickPow(-k);
};
const meanTick = (cumOld, cumNew, w) => { const d = cumNew - cumOld; let m = d / BigInt(w); if (d < 0n && d % BigInt(w) !== 0n) m -= 1n; return Number(m); };

const usdcBal = (who) => keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [who, 9n]));
const usdcAllow = (owner, spender) => keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'bytes32' }], [spender, keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [owner, 10n]))]));
const pct = (xs, p) => { if (!xs.length) return NaN; const s = [...xs].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.floor((p / 100) * (s.length - 1) + 0.5))]; };
const limit = (n) => { let a = 0; const q = []; return (fn) => new Promise((res, rej) => { const run = () => { a++; fn().then(res, rej).finally(() => { a--; q.length && q.shift()(); }); }; a < n ? run() : q.push(run); }); };
const lim = limit(6);

(async () => {
  const head = await c.getBlock();
  const headN = head.number, headT = Number(head.timestamp);
  const blockAt = async (iso) => {
    const t = iso === 'now' ? headT - 60 : Math.floor(Date.parse(iso) / 1000);
    let n = headN - BigInt(Math.floor((headT - t) / 2)); // Base: 2 s blocks
    for (let i = 0; i < 4; i++) { const bt = Number((await c.getBlock({ blockNumber: n })).timestamp); if (bt === t) break; n += BigInt(Math.trunc((t - bt) / 2)); if (Math.abs(t - bt) < 2) break; }
    return n;
  };
  const tokens = await c.readContract({ address: REGISTRY, abi: REG, functionName: 'enabledTokens' });
  const stocks = [];
  for (const t of tokens) {
    const s = await c.readContract({ address: REGISTRY, abi: REG, functionName: 'getStock', args: [t] });
    const sym = await c.readContract({ address: t, abi: ERC, functionName: 'symbol' });
    stocks.push({ token: t, sym, pool: s.pool, spacing: s.tickSpacing, dec: s.tokenDecimals });
  }
  const budget = BUY_USD * 10n ** 6n;

  const sampleOne = async (st, blockNumber) => lim(async () => {
    const at = { blockNumber };
    const [s0, L, usdcPool] = await Promise.all([
      c.readContract({ address: st.pool, abi: POOL, functionName: 'slot0', ...at }),
      c.readContract({ address: st.pool, abi: POOL, functionName: 'liquidity', ...at }),
      c.readContract({ address: USDC, abi: ERC, functionName: 'balanceOf', args: [st.pool], ...at }),
    ]);
    let twap = {}, twapOk = true;
    try {
      const [cum] = await c.readContract({ address: st.pool, abi: POOL, functionName: 'observe', args: [[3600, 1800, 900, 0]], ...at });
      twap = { m60: meanTick(cum[0], cum[3], 3600), m30: meanTick(cum[1], cum[3], 1800), m15: meanTick(cum[2], cum[3], 900) };
    } catch { twapOk = false; }
    let fill = null, swapErr = null;
    try {
      const data = encodeFunctionData({ abi: ROUTER_ABI, functionName: 'exactInputSingle', args: [{ tokenIn: USDC, tokenOut: st.token, tickSpacing: st.spacing, recipient: SIM, deadline: 2n ** 40n, amountIn: budget, amountOutMinimum: 0n, sqrtPriceLimitX96: 0n }] });
      const r = await c.call({ account: SIM, to: ROUTER, data, blockNumber, stateOverride: [{ address: USDC, stateDiff: [{ slot: usdcBal(SIM), value: pad(toHex(budget * 10n)) }, { slot: usdcAllow(SIM, ROUTER), value: pad(toHex(budget * 10n)) }] }] });
      fill = decodeFunctionResult({ abi: ROUTER_ABI, functionName: 'exactInputSingle', data: r.data });
    } catch (e) { swapErr = String(e.shortMessage ?? e.message).slice(0, 80); }
    const sqrtP = s0[0], spot = Number(s0[1]);
    const o = { block: Number(blockNumber), spot, card: Number(s0[3]), L: L.toString(), usdcPool: Number(usdcPool) / 1e6, twapOk, ...twap, fill: fill?.toString(), swapErr };
    if (twapOk) {
      o.dev30 = Math.abs(spot - twap.m30); o.dev15 = Math.abs(spot - twap.m15); o.dev60 = Math.abs(spot - twap.m60);
      const ref = refOut(sqrtP, spot, twap.m30, budget, true);
      o.ref = ref.toString();
      o.minOut = ((ref * (10000n - GUARD.slipBps)) / 10000n).toString();
      if (fill !== null) o.fillVsRefBps = Number(((fill - ref) * 1000000n) / ref) / 100;
    }
    o.pass = { twap: twapOk, dev: twapOk && o.dev30 <= GUARD.dev, share: budget * 10000n <= usdcPool * GUARD.shareBps, floor: fill !== null && twapOk && fill >= BigInt(o.minOut) };
    o.passAll = o.pass.twap && o.pass.dev && o.pass.share && o.pass.floor;
    return o;
  });

  const out = { generatedAt: new Date().toISOString(), head: Number(headN), buyUsd: Number(BUY_USD), guard: { ...GUARD, slipBps: Number(GUARD.slipBps), shareBps: Number(GUARD.shareBps) }, windows: [] };
  for (const w of WINDOWS) {
    const b0 = await blockAt(w.start), b1 = await blockAt(w.end);
    const step = BigInt(Math.round((SAMPLE_HOURS * 3600) / 2));
    const blocks = []; for (let b = b0; b <= b1; b += step) blocks.push(b); if (blocks[blocks.length - 1] !== b1) blocks.push(b1);
    const pools = stocks.map((s) => s.pool);
    // events, in 1,500-block chunks (RPC body-size limit), all pools at once
    const counts = Object.fromEntries(stocks.map((s) => [s.pool.toLowerCase(), { swap: 0, mint: 0, burn: 0 }]));
    for (let a = b0; a <= b1; a += 1500n) {
      const z = a + 1499n < b1 ? a + 1499n : b1;
      const [sw, mi, bu] = await Promise.all([SWAP, MINT, BURN].map((ev) => lim(() => c.getLogs({ address: pools, event: ev, fromBlock: a, toBlock: z }))));
      for (const l of sw) counts[l.address.toLowerCase()].swap++;
      for (const l of mi) counts[l.address.toLowerCase()].mint++;
      for (const l of bu) counts[l.address.toLowerCase()].burn++;
    }
    const perStock = [];
    for (const st of stocks) {
      const samples = await Promise.all(blocks.map((b) => sampleOne(st, b)));
      perStock.push({ sym: st.sym, token: st.token, pool: st.pool, events: counts[st.pool.toLowerCase()], samples });
    }
    // fairness at the window end (Monday open for weekends): pool vs Chainlink
    for (const p of perStock) {
      try {
        const [pr, upd] = await c.readContract({ address: REGISTRY, abi: REG, functionName: 'priceUsd', args: [p.token], blockNumber: b1 });
        const last = p.samples[p.samples.length - 1];
        const ratio = 0; // stock raw per usdc raw = sqrtP^2/2^192 — recompute from slot0 at b1
        const s0 = await c.readContract({ address: p.pool, abi: POOL, functionName: 'slot0', blockNumber: b1 });
        const r = Number((s0[0] * s0[0] * 10n ** 12n) / Q192) / 1e12; // raw stock per raw USDC
        const poolUsd = 100 / r; // (1e8 raw stock) / (r * 1e6)
        p.endVsChainlinkPct = ((poolUsd / (Number(pr) / 1e18)) - 1) * 100;
        p.chainlinkAgeMin = Math.round((Number((await c.getBlock({ blockNumber: b1 })).timestamp) - Number(upd)) / 60);
        void ratio; void last;
      } catch { p.endVsChainlinkPct = null; }
    }
    out.windows.push({ ...w, fromBlock: Number(b0), toBlock: Number(b1), samplesPerStock: blocks.length, stocks: perStock });
    process.stderr.write(`window ${w.name}: ${blocks.length} samples x ${stocks.length} pools done\n`);
  }
  const file = path.join(ROOT, `specs/raffle/predeploy/weekend-depth-${process.env.OUT ?? new Date().toISOString().slice(0, 10)}.json`);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(out, null, 1));

  // ---------------- report ----------------
  const f = (x, d = 0) => (x === null || x === undefined || Number.isNaN(x) ? '-' : Number(x).toFixed(d));
  for (const w of out.windows) {
    console.log(`\n=== ${w.name}  ${w.start} -> ${w.end}  (${w.samplesPerStock} samples/pool, blocks ${w.fromBlock}-${w.toBlock})`);
    console.log('stock  | pass$1k | minUSDC$k medUSDC$k | minL/medL | dev30 p50/p95/max | dev15 max dev60 max | fill-vs-ref bps worst/med | swaps mints burns | end vs CL %');
    for (const s of w.stocks) {
      const S = s.samples, ok = S.filter((x) => x.passAll).length;
      const usd = S.map((x) => x.usdcPool), Ls = S.map((x) => Number(x.L));
      const d30 = S.filter((x) => x.twapOk).map((x) => x.dev30), d15 = S.filter((x) => x.twapOk).map((x) => x.dev15), d60 = S.filter((x) => x.twapOk).map((x) => x.dev60);
      const fr = S.filter((x) => x.fillVsRefBps !== undefined).map((x) => x.fillVsRefBps);
      const fails = [...new Set(S.filter((x) => !x.passAll).flatMap((x) => Object.entries(x.pass).filter(([, v]) => !v).map(([k]) => k)))];
      console.log(`${s.sym.padEnd(6)} | ${String(ok).padStart(2)}/${S.length}${fails.length ? ' ' + fails.join('+') : ''} | ${f(Math.min(...usd) / 1e3)} ${f(pct(usd, 50) / 1e3)} | ${f(Math.min(...Ls) / pct(Ls, 50), 2)} | ${pct(d30, 50)}/${pct(d30, 95)}/${Math.max(...d30)} | ${Math.max(...d15)} ${Math.max(...d60)} | ${f(Math.min(...fr), 1)}/${f(pct(fr, 50), 1)} | ${s.events.swap} ${s.events.mint} ${s.events.burn} | ${f(s.endVsChainlinkPct, 2)} (CL ${s.chainlinkAgeMin ?? '-'}m old)`);
    }
  }
  console.log(`\nraw: ${path.relative(ROOT, file)}`);
})().catch((e) => { console.error(e.shortMessage ?? e.message ?? e); process.exit(1); });
