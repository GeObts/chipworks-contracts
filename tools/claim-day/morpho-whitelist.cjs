// The whitelist for the Chipworks USDC vault: deep blue-chip markets plus the Chipworks stock
// markets, with the exact ids, LLTVs, depth and live rates a curator needs to set caps.
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, parseAbiItem, formatUnits, getAddress } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const c = createPublicClient({ chain: base, transport: http(env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim()) });
const MORPHO = '0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb';
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const REGISTRY = '0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458';
const ERC20 = parseAbi(['function symbol() view returns (string)']);
const M = parseAbi(['function market(bytes32) view returns (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee)']);
const IRM = parseAbi([
  'struct MarketParams { address loanToken; address collateralToken; address oracle; address irm; uint256 lltv; }',
  'struct Market { uint128 totalSupplyAssets; uint128 totalSupplyShares; uint128 totalBorrowAssets; uint128 totalBorrowShares; uint128 lastUpdate; uint128 fee; }',
  'function borrowRateView(MarketParams marketParams, Market market) view returns (uint256)',
]);
/** Blue chips to carry the size. Collateral symbols, matched case-insensitively. */
const DEEP = ['cbBTC', 'USDe', 'cbXRP', 'WETH'];
const apy = (r) => (Math.exp((Number(r) / 1e18) * 31_536_000) - 1) * 100;

(async () => {
  const stocks = new Map();
  for (const s of await c.readContract({ address: REGISTRY, abi: parseAbi(['function allTokens() view returns (address[])']), functionName: 'allTokens' })) {
    stocks.set(getAddress(s), await c.readContract({ address: s, abi: ERC20, functionName: 'symbol' }).catch(() => '?'));
  }
  const latest = await c.getBlockNumber();
  const logs = await c.getLogs({ address: MORPHO, event: parseAbiItem('event CreateMarket(bytes32 indexed id, (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv) marketParams)'), fromBlock: 0n, toBlock: latest });
  const usdcLoan = logs.filter((l) => getAddress(l.args.marketParams.loanToken) === getAddress(USDC));

  const rows = [];
  for (const l of usdcLoan) {
    const p = l.args.marketParams;
    const col = getAddress(p.collateralToken);
    const sym = stocks.get(col) ?? (await c.readContract({ address: col, abi: ERC20, functionName: 'symbol' }).catch(() => col.slice(0, 8)));
    const isStock = stocks.has(col);
    const isDeep = DEEP.some((d) => d.toLowerCase() === String(sym).toLowerCase());
    if (!isStock && !isDeep) continue;
    const m = await c.readContract({ address: MORPHO, abi: M, functionName: 'market', args: [l.args.id] });
    if (m[0] === 0n) continue;
    let borrowApy = null;
    try { borrowApy = apy(await c.readContract({ address: p.irm, abi: IRM, functionName: 'borrowRateView', args: [{ loanToken: p.loanToken, collateralToken: p.collateralToken, oracle: p.oracle, irm: p.irm, lltv: p.lltv }, { totalSupplyAssets: m[0], totalSupplyShares: m[1], totalBorrowAssets: m[2], totalBorrowShares: m[3], lastUpdate: m[4], fee: m[5] }] })); } catch {}
    const util = Number(m[2]) / Number(m[0]);
    rows.push({ id: l.args.id, sym: String(sym), isStock, lltv: Number(p.lltv) / 1e16, supply: Number(formatUnits(m[0], 6)), util: util * 100, borrowApy, supplyApy: borrowApy === null ? null : borrowApy * util, params: p });
  }
  rows.sort((a, b) => (a.isStock === b.isStock ? b.supply - a.supply : a.isStock ? 1 : -1));
  console.log('DEEP MARKETS (carry the size)');
  for (const r of rows.filter((x) => !x.isStock)) console.log(`  ${r.sym.padEnd(6)} @${String(r.lltv).padStart(5)}%  supplied ${r.supply.toLocaleString('en-US', { maximumFractionDigits: 0 }).padStart(13)}  util ${r.util.toFixed(1).padStart(5)}%  supply APY ${r.supplyApy?.toFixed(2)}%\n     id ${r.id}`);
  console.log('\nCHIPWORKS STOCK MARKETS (higher yield, thin)');
  for (const r of rows.filter((x) => x.isStock)) console.log(`  ${r.sym.padEnd(6)} @${String(r.lltv).padStart(5)}%  supplied ${r.supply.toLocaleString('en-US', { maximumFractionDigits: 2 }).padStart(13)}  util ${r.util.toFixed(1).padStart(5)}%  supply APY ${r.supplyApy?.toFixed(2)}%\n     id ${r.id}`);

  const out = path.join(__dirname, 'vault-whitelist.json');
  fs.writeFileSync(out, JSON.stringify(rows.map((r) => ({ id: r.id, symbol: r.sym, isStock: r.isStock, lltvPct: r.lltv, suppliedUsdc: r.supply, utilPct: r.util, supplyApy: r.supplyApy, marketParams: { loanToken: r.params.loanToken, collateralToken: r.params.collateralToken, oracle: r.params.oracle, irm: r.params.irm, lltv: r.params.lltv.toString() } })), null, 2));
  console.log(`\nwritten: ${out}  (${rows.length} markets)`);
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
