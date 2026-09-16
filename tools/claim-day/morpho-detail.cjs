// Detail on the Chipworks-stock Morpho markets: free liquidity, oracle, IRM, fee, and whether any
// market anywhere uses a stock as the LOAN asset (which is what "lend your stock for yield" needs).
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, parseAbiItem, formatUnits, getAddress } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const c = createPublicClient({ chain: base, transport: http(env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim()) });
const MORPHO = '0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb';
const REGISTRY = '0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458';
const ERC20 = parseAbi(['function symbol() view returns (string)']);
const M = parseAbi([
  'function market(bytes32) view returns (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee)',
]);
const ORACLE = parseAbi(['function price() view returns (uint256)']);

(async () => {
  const stocks = await c.readContract({ address: REGISTRY, abi: parseAbi(['function allTokens() view returns (address[])']), functionName: 'allTokens' });
  const mine = new Map();
  for (const s of stocks) mine.set(getAddress(s), await c.readContract({ address: s, abi: ERC20, functionName: 'symbol' }).catch(() => '?'));

  const ev = parseAbiItem('event CreateMarket(bytes32 indexed id, (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv) marketParams)');
  const latest = await c.getBlockNumber();
  const logs = await c.getLogs({ address: MORPHO, event: ev, fromBlock: 0n, toBlock: latest });

  const asLoan = logs.filter((l) => mine.has(getAddress(l.args.marketParams.loanToken)));
  console.log(`markets where a Chipworks stock is the LOAN asset (needed to lend the stock itself): ${asLoan.length}`);
  for (const l of asLoan) {
    const m = await c.readContract({ address: MORPHO, abi: M, functionName: 'market', args: [l.args.id] });
    console.log(`  loan ${mine.get(getAddress(l.args.marketParams.loanToken))} supplied ${formatUnits(m[0], 8)} borrowed ${formatUnits(m[2], 8)}`);
  }

  const asCollateral = logs.filter((l) => mine.has(getAddress(l.args.marketParams.collateralToken)));
  console.log(`\nmarkets where a Chipworks stock is COLLATERAL: ${asCollateral.length}`);
  let freeTotal = 0;
  for (const l of asCollateral) {
    const p = l.args.marketParams;
    const m = await c.readContract({ address: MORPHO, abi: M, functionName: 'market', args: [l.args.id] });
    const free = Number(formatUnits(m[0] - m[2], 6));
    freeTotal += free;
    const px = await c.readContract({ address: p.oracle, abi: ORACLE, functionName: 'price' }).catch(() => null);
    const util = m[0] > 0n ? (Number(m[2]) / Number(m[0])) * 100 : 0;
    console.log(`  ${mine.get(getAddress(p.collateralToken))} @ LLTV ${Number(p.lltv) / 1e16}%  supplied ${formatUnits(m[0], 6)} borrowed ${formatUnits(m[2], 6)} FREE TO BORROW ${free.toFixed(2)} USDC  util ${util.toFixed(1)}%  marketFee ${Number(m[5]) / 1e16}%`);
    console.log(`     oracle ${p.oracle} price ${px === null ? 'unreadable' : px.toString()}  irm ${p.irm}`);
  }
  console.log(`\nTOTAL USDC that could be borrowed against Chipworks stocks right now: ${freeTotal.toFixed(2)}`);

  // For contrast: what a stock holder could borrow if Chipworks supplied the USDC itself.
  console.log('\nMarkets are permissionless to supply: anyone can add USDC and set the borrowable depth.');
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
