// Is the Chipworks USDC vault earning the best rate its markets offer?
//
// For each of the vault's 8 markets: live utilisation, borrow and supply APY, free liquidity, the vault's own
// position, the rate a NEW deposit would actually get (supplying pushes utilisation and so the rate down), and
// 7 days of history sampled every 12h so "consistently pays more" is measured, not guessed. Then the blended
// net APY a depositor gets at several deposit sizes under the CURRENT queue order, against the best possible
// allocation under the same caps.
//
//   node vault-rates.cjs
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const c = createPublicClient({ chain: base, transport: http(env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim()), batch: { multicall: true } });

const VAULT = '0x6B0EF5dd1cED6E26c384E4CcAf72f9dC0A1093d6';
const MORPHO = '0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb';
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const IRM = '0x46415998764C29aB2a25CbeA6254146D50D22687';
const VAULT_FEE = 0.15;
const MARKETS = [ // supply-queue order
  { sym: 'AAPL', collateralToken: '0xb200000000000000000000C2e324d24d7eEcd1fb', oracle: '0xEcC5c9bf18CB2CfC94C2f7EFf8BDd5837A60AB0e', lltv: 625000000000000000n, id: '0xae1a30486234bf7e7ac166c7c03d9bc5f2cd8a39be2c48e73c665ac7148c3c28' },
  { sym: 'GOOGL', collateralToken: '0xb2000000000000000000002D0BA3164cc74f58B7', oracle: '0x24DC11055aa5b2C5692E4B77d7285c4f0fd9Cf99', lltv: 770000000000000000n, id: '0xa3913d896b7e9c0e0a84f1be27d376cf2065616101cb7c44674af8a154e684cc' },
  { sym: 'NVDA', collateralToken: '0xb20000000000000000000078ee7ce2fE4908108C', oracle: '0x4F698C04d01d9CebCDd9494c189aBdD6C5453f84', lltv: 625000000000000000n, id: '0xb4b42dd66cef25614b94510a910d54b2c148e7621d22b4271566724beda63d13' },
  { sym: 'META', collateralToken: '0xb2000000000000000000008bC8786B856E61707C', oracle: '0x4752B27dFc1931eb9a5DFEFC7FBC9d0af9020dC7', lltv: 625000000000000000n, id: '0x44b343b5087c0bd34207cb5c199f12030777bf6b8c0a128438246f1212f37ca5' },
  { sym: 'cbBTC', collateralToken: '0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf', oracle: '0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9', lltv: 860000000000000000n, id: '0x9103c3b4e834476c9a62ea009ba2c884ee42e94e6e314a26f04d312434191836' },
  { sym: 'USDe', collateralToken: '0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34', oracle: '0xF4b17C79492d68775e22e8Dd0a2Bb22854A39A47', lltv: 915000000000000000n, id: '0x54cf9be57fdfa6457a660991907434ff9d295c465a603a50126ff647d50b7354' },
  { sym: 'WETH', collateralToken: '0x4200000000000000000000000000000000000006', oracle: '0xFEa2D58cEfCb9fcb597723c6bAE66fFE4193aFE4', lltv: 860000000000000000n, id: '0x8793cf302b8ffd655ab97bd1c695dbd967807e8367a65cb2f4edaf1380ba1bda' },
  { sym: 'cbXRP', collateralToken: '0xcb585250f852C6c6bf90434AB21A00f02833a4af', oracle: '0x031b2EFC8d70042Ac8d9f5c793c4149eC4b60fdE', lltv: 625000000000000000n, id: '0xd4a903dc6d949519060c7707f9604fdc9772c046e05c2e3a8fce0bd7196e4109' },
].map((m) => ({ ...m, params: { loanToken: USDC, collateralToken: m.collateralToken, oracle: m.oracle, irm: IRM, lltv: m.lltv } }));

const MB = parseAbi(['function market(bytes32) view returns (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee)', 'function position(bytes32,address) view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral)']);
const IRM_ABI = parseAbi([
  'struct MarketParams { address loanToken; address collateralToken; address oracle; address irm; uint256 lltv; }',
  'struct Market { uint128 totalSupplyAssets; uint128 totalSupplyShares; uint128 totalBorrowAssets; uint128 totalBorrowShares; uint128 lastUpdate; uint128 fee; }',
  'function borrowRateView(MarketParams marketParams, Market market) view returns (uint256)',
]);
const V = parseAbi(['function config(bytes32) view returns (uint184 cap, bool enabled, uint64 removableAt)', 'function totalAssets() view returns (uint256)']);
const YEAR = 31_536_000;
const apy = (perSec) => Math.exp((Number(perSec) / 1e18) * YEAR) - 1;
const pct = (x) => (x * 100).toFixed(2) + '%';
const usd = (x) => '$' + Math.round(x).toLocaleString('en-US');

async function marketAt(m, blockNumber) {
  const r = await c.readContract({ address: MORPHO, abi: MB, functionName: 'market', args: [m.id], blockNumber });
  const mk = { totalSupplyAssets: r[0], totalSupplyShares: r[1], totalBorrowAssets: r[2], totalBorrowShares: r[3], lastUpdate: r[4], fee: r[5] };
  const rate = await c.readContract({ address: IRM, abi: IRM_ABI, functionName: 'borrowRateView', args: [m.params, mk], blockNumber });
  return { mk, rate };
}
/** Supply APY a market pays if `add` USDC (6dp units, bigint) of new supply lands on it right now. */
async function supplyApyWith(m, mk, add) {
  const moved = { ...mk, totalSupplyAssets: mk.totalSupplyAssets + add };
  const rate = await c.readContract({ address: IRM, abi: IRM_ABI, functionName: 'borrowRateView', args: [m.params, moved] });
  const util = Number(moved.totalBorrowAssets) / Number(moved.totalSupplyAssets);
  return apy(rate) * util * (1 - Number(mk.fee) / 1e18);
}

(async () => {
  const head = await c.getBlockNumber();
  const vaultAssets = Number(await c.readContract({ address: VAULT, abi: V, functionName: 'totalAssets' })) / 1e6;
  console.log(`block ${head}   vault totalAssets ${usd(vaultAssets)}\n`);

  const rows = [];
  for (const m of MARKETS) {
    const { mk, rate } = await marketAt(m, head);
    const supply = Number(mk.totalSupplyAssets) / 1e6, borrow = Number(mk.totalBorrowAssets) / 1e6;
    const util = borrow / supply;
    const bApy = apy(rate);
    const sApy = bApy * util * (1 - Number(mk.fee) / 1e18);
    const cap = Number((await c.readContract({ address: VAULT, abi: V, functionName: 'config', args: [m.id] }))[0]) / 1e6;
    const pos = await c.readContract({ address: MORPHO, abi: MB, functionName: 'position', args: [m.id, VAULT] });
    const vaultIn = mk.totalSupplyShares === 0n ? 0 : (Number(pos[0]) * supply) / Number(mk.totalSupplyShares);
    // what a new deposit up to the cap actually earns there: rate after the whole cap lands
    const afterCap = await supplyApyWith(m, mk, BigInt(Math.round(Math.max(cap - vaultIn, 0) * 1e6)));
    const after1k = await supplyApyWith(m, mk, 1_000_000_000n);
    rows.push({ m, mk, supply, borrow, util, bApy, sApy, cap, vaultIn, afterCap, after1k });
  }

  console.log('LIVE, PER MARKET (supply APY = what lenders earn before the vault\'s 15%)');
  console.log('  market   supplied        util   borrow APY  supply APY  net to depositor | +$1k lands: net | cap        vault has  whole cap lands: net');
  for (const r of rows) {
    console.log(`  ${r.m.sym.padEnd(6)} ${usd(r.supply).padStart(15)}  ${pct(r.util).padStart(7)}  ${pct(r.bApy).padStart(9)}  ${pct(r.sApy).padStart(9)}  ${pct(r.sApy * (1 - VAULT_FEE)).padStart(9)}        | ${pct(r.after1k * (1 - VAULT_FEE)).padStart(8)}        | ${usd(r.cap).padStart(8)}  ${usd(r.vaultIn).padStart(8)}   ${pct(r.afterCap * (1 - VAULT_FEE)).padStart(8)}`);
  }

  // ---- 7 days of history, every 12h ----------------------------------------------------------
  console.log('\nLAST 7 DAYS, SUPPLY APY EVERY 12h (oldest -> now; before the 15% fee)');
  const STEP = 21_600n; // ~12h of 2s blocks
  const samples = 15;
  const hist = {};
  for (const r of rows) {
    hist[r.m.sym] = [];
    for (let i = samples - 1; i >= 0; i--) {
      const bn = head - STEP * BigInt(i);
      try {
        const { mk, rate } = await marketAt(r.m, bn);
        const u = Number(mk.totalBorrowAssets) / Number(mk.totalSupplyAssets || 1n);
        hist[r.m.sym].push(mk.totalSupplyAssets === 0n ? null : apy(rate) * u * (1 - Number(mk.fee) / 1e18));
      } catch { hist[r.m.sym].push(null); }
    }
    const v = hist[r.m.sym].filter((x) => x !== null);
    const avg = v.reduce((a, b) => a + b, 0) / (v.length || 1);
    console.log(`  ${r.m.sym.padEnd(6)} avg ${pct(avg).padStart(7)}  min ${pct(Math.min(...v)).padStart(7)}  max ${pct(Math.max(...v)).padStart(7)}   ${hist[r.m.sym].map((x) => (x === null ? '  -  ' : (x * 100).toFixed(1).padStart(5))).join(' ')}`);
    r.avg7 = avg;
  }

  // ---- blended: current queue order vs best possible under the same caps ---------------------
  // Fill in chunks so each market's rate falls as it absorbs supply, exactly as it would on chain.
  const CHUNK = 500;
  async function allocate(total, pickNext) {
    const state = rows.map((r) => ({ r, placed: 0, room: Math.max(r.cap - r.vaultIn, 0) }));
    let left = total, earned = 0;
    while (left > 0) {
      const target = await pickNext(state);
      if (!target) break;
      const amt = Math.min(CHUNK, left, target.room - target.placed);
      target.placed += amt; left -= amt;
    }
    for (const s of state) if (s.placed > 0) earned += s.placed * (await supplyApyWith(s.r.m, s.r.mk, BigInt(Math.round(s.placed * 1e6))));
    const placedTotal = total - left;
    return { apy: placedTotal ? earned / placedTotal : 0, state, unplaced: left };
  }
  const queueOrder = async (state) => state.find((s) => s.room - s.placed > 0);
  const greedy = async (state) => {
    let best = null, bestRate = -1;
    for (const s of state) {
      if (s.room - s.placed <= 0) continue;
      const rNext = await supplyApyWith(s.r.m, s.r.mk, BigInt(Math.round((s.placed + CHUNK) * 1e6)));
      if (rNext > bestRate) { bestRate = rNext; best = s; }
    }
    return best;
  };
  const byOrder = (names) => async (state) => {
    for (const n of names) {
      const t = state.find((x) => x.r.m.sym === n);
      if (t.room - t.placed > 0) return t;
    }
    return null;
  };
  const deepByRate = rows.slice(4).sort((x, y) => y.avg7 - x.avg7).map((r) => r.m.sym);
  const ORDERS = {
    'current (stocks, cbBTC, USDe, WETH, cbXRP)': null,
    'proposed (stocks, then deep by 7d rate)': ['AAPL', 'GOOGL', 'NVDA', 'META', ...deepByRate],
    'deep by 7d rate only, stocks last': [...deepByRate, 'AAPL', 'GOOGL', 'NVDA', 'META'],
  };
  const SIZES = [2_000, 8_000, 25_000, 58_000, 108_000, 208_000];
  console.log('\nSUPPLY-QUEUE ORDERS COMPARED: blended net APY to a depositor (after the 15% fee)');
  console.log('  ' + 'order'.padEnd(44) + SIZES.map((x) => usd(x).padStart(10)).join(''));
  for (const [label, names] of Object.entries(ORDERS)) {
    const cells = [];
    for (const size of SIZES) cells.push(pct((await allocate(size, names ? byOrder(names) : queueOrder)).apy * (1 - VAULT_FEE)).padStart(10));
    console.log('  ' + label.padEnd(44) + cells.join(''));
    if (names) console.log('      ' + names.join(' > '));
  }

  console.log('\nBLENDED NET APY TO A DEPOSITOR (after the 15% fee), current queue vs best possible allocation, same caps');
  for (const size of [2_000, 8_000, 25_000, 58_000, 208_000]) {
    const q = await allocate(size, queueOrder);
    const g = size <= 58_000 ? await allocate(size, greedy) : null;
    const where = q.state.filter((s) => s.placed > 0).map((s) => `${s.r.m.sym} ${usd(s.placed)}`).join(', ');
    console.log(`  deposit ${usd(size).padStart(9)}:  queue ${pct(q.apy * (1 - VAULT_FEE))}${g ? `   best ${pct(g.apy * (1 - VAULT_FEE))}   gap ${((g.apy - q.apy) * (1 - VAULT_FEE) * 10000).toFixed(0)} bps` : ''}   [queue puts it in: ${where}]`);
    if (g) console.log(`  ${' '.repeat(22)}best puts it in: ${g.state.filter((s) => s.placed > 0).map((s) => `${s.r.m.sym} ${usd(s.placed)}`).join(', ')}`);
  }
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
