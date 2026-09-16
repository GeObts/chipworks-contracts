// Live borrow/supply APY on Morpho Blue (Base): the Chipworks-stock markets, plus the biggest
// USDC-loan and WETH-loan markets, so "what would a lender earn" is a measured number.
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, parseAbiItem, formatUnits, getAddress } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const c = createPublicClient({ chain: base, transport: http(env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim()), batch: { multicall: true } });
const MORPHO = '0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb';
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const WETH = '0x4200000000000000000000000000000000000006';
const REGISTRY = '0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458';
const ERC20 = parseAbi(['function symbol() view returns (string)', 'function decimals() view returns (uint8)']);
const M = parseAbi(['function market(bytes32) view returns (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee)']);
const IRM = parseAbi([
  'struct MarketParams { address loanToken; address collateralToken; address oracle; address irm; uint256 lltv; }',
  'struct Market { uint128 totalSupplyAssets; uint128 totalSupplyShares; uint128 totalBorrowAssets; uint128 totalBorrowShares; uint128 lastUpdate; uint128 fee; }',
  'function borrowRateView(MarketParams marketParams, Market market) view returns (uint256)',
]);
const SECONDS_PER_YEAR = 31_536_000;
const apyFromPerSecond = (ratePerSecondWad) => (Math.exp((Number(ratePerSecondWad) / 1e18) * SECONDS_PER_YEAR) - 1) * 100;

async function rates(id, p) {
  const m = await c.readContract({ address: MORPHO, abi: M, functionName: 'market', args: [id] });
  const market = { totalSupplyAssets: m[0], totalSupplyShares: m[1], totalBorrowAssets: m[2], totalBorrowShares: m[3], lastUpdate: m[4], fee: m[5] };
  let borrowApy = null;
  try {
    const r = await c.readContract({ address: p.irm, abi: IRM, functionName: 'borrowRateView', args: [{ loanToken: p.loanToken, collateralToken: p.collateralToken, oracle: p.oracle, irm: p.irm, lltv: p.lltv }, market] });
    borrowApy = apyFromPerSecond(r);
  } catch {}
  const util = m[0] > 0n ? Number(m[2]) / Number(m[0]) : 0;
  const supplyApy = borrowApy === null ? null : borrowApy * util * (1 - Number(m[5]) / 1e18);
  return { m, util, borrowApy, supplyApy };
}

(async () => {
  const stocks = await c.readContract({ address: REGISTRY, abi: parseAbi(['function allTokens() view returns (address[])']), functionName: 'allTokens' });
  const mine = new Map();
  for (const s of stocks) mine.set(getAddress(s), await c.readContract({ address: s, abi: ERC20, functionName: 'symbol' }).catch(() => '?'));
  const symCache = new Map(mine);
  const sym = async (t) => { const k = getAddress(t); if (!symCache.has(k)) symCache.set(k, await c.readContract({ address: t, abi: ERC20, functionName: 'symbol' }).catch(() => k.slice(0, 8))); return symCache.get(k); };

  const latest = await c.getBlockNumber();
  const logs = await c.getLogs({ address: MORPHO, event: parseAbiItem('event CreateMarket(bytes32 indexed id, (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv) marketParams)'), fromBlock: 0n, toBlock: latest });

  console.log('=== Chipworks-stock collateral markets (USDC lenders earn this) ===');
  for (const l of logs.filter((x) => mine.has(getAddress(x.args.marketParams.collateralToken)))) {
    const p = l.args.marketParams;
    const { m, util, borrowApy, supplyApy } = await rates(l.args.id, p);
    if (m[0] === 0n) continue;
    console.log(`  ${mine.get(getAddress(p.collateralToken))} @${Number(p.lltv) / 1e16}%  supplied ${Number(formatUnits(m[0], 6)).toFixed(2)} USDC  util ${(util * 100).toFixed(1)}%  BORROW APY ${borrowApy?.toFixed(2)}%  SUPPLY APY ${supplyApy?.toFixed(2)}%`);
  }

  for (const [label, loanToken, dec] of [['USDC', USDC, 6], ['WETH', WETH, 18]]) {
    const rows = [];
    for (const l of logs.filter((x) => getAddress(x.args.marketParams.loanToken) === getAddress(loanToken))) {
      const p = l.args.marketParams;
      const m = await c.readContract({ address: MORPHO, abi: M, functionName: 'market', args: [l.args.id] });
      if (m[0] === 0n) continue;
      rows.push({ id: l.args.id, p, supply: m[0] });
    }
    rows.sort((a, b) => (b.supply > a.supply ? 1 : -1));
    console.log(`\n=== biggest ${label}-loan markets on Base (lenders supply ${label}) ===`);
    for (const r of rows.slice(0, 8)) {
      const { m, util, borrowApy, supplyApy } = await rates(r.id, r.p);
      console.log(`  collateral ${await sym(r.p.collateralToken)} @${Number(r.p.lltv) / 1e16}%  supplied ${Number(formatUnits(m[0], dec)).toLocaleString('en-US', { maximumFractionDigits: 0 })}  util ${(util * 100).toFixed(1)}%  BORROW ${borrowApy?.toFixed(2)}%  SUPPLY ${supplyApy?.toFixed(2)}%`);
    }
  }
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
