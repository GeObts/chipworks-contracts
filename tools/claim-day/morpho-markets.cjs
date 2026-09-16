// Which Morpho Blue markets on Base involve the Chipworks stock tokens, and what state are they in?
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, parseAbiItem, formatUnits, getAddress, keccak256, encodeAbiParameters } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const c = createPublicClient({ chain: base, transport: http(env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim()) });

const MORPHO = '0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb'; // Morpho Blue, same address on every chain
const REGISTRY = '0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458';
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const ERC20 = parseAbi(['function symbol() view returns (string)', 'function decimals() view returns (uint8)', 'function balanceOf(address) view returns (uint256)']);
const MORPHO_ABI = parseAbi([
  'function market(bytes32) view returns (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee)',
  'function idToMarketParams(bytes32) view returns (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv)',
]);

(async () => {
  const code = await c.getBytecode({ address: MORPHO });
  console.log(`Morpho Blue at ${MORPHO}: ${code ? `${(code.length - 2) / 2} bytes of code` : 'NO CODE'}`);
  if (!code) return;

  const stocks = await c.readContract({ address: REGISTRY, abi: parseAbi(['function allTokens() view returns (address[])']), functionName: 'allTokens' });
  const mine = new Map();
  for (const s of stocks) mine.set(getAddress(s), await c.readContract({ address: s, abi: ERC20, functionName: 'symbol' }).catch(() => '?'));
  console.log(`Chipworks stock tokens: ${[...mine.values()].join(', ')}`);

  const ev = parseAbiItem('event CreateMarket(bytes32 indexed id, (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv) marketParams)');
  const latest = await c.getBlockNumber();
  let logs = [];
  try {
    logs = await c.getLogs({ address: MORPHO, event: ev, fromBlock: 0n, toBlock: latest });
  } catch (e) {
    console.log('full-range getLogs refused, chunking:', e.shortMessage);
    for (let a = 13000000n; a <= latest; a += 2000000n) {
      logs.push(...await c.getLogs({ address: MORPHO, event: ev, fromBlock: a, toBlock: a + 1999999n > latest ? latest : a + 1999999n }));
    }
  }
  console.log(`markets ever created on Base: ${logs.length}`);

  const sym = async (t) => mine.get(getAddress(t)) ?? (await c.readContract({ address: t, abi: ERC20, functionName: 'symbol' }).catch(() => t.slice(0, 8)));
  const hits = logs.filter((l) => mine.has(getAddress(l.args.marketParams.loanToken)) || mine.has(getAddress(l.args.marketParams.collateralToken)));
  console.log(`\nmarkets touching a Chipworks stock: ${hits.length}`);
  for (const l of hits) {
    const p = l.args.marketParams;
    const [m, ls, cs] = await Promise.all([
      c.readContract({ address: MORPHO, abi: MORPHO_ABI, functionName: 'market', args: [l.args.id] }),
      sym(p.loanToken), sym(p.collateralToken),
    ]);
    const ldec = await c.readContract({ address: p.loanToken, abi: ERC20, functionName: 'decimals' }).catch(() => 18);
    console.log(`  ${cs} collateral / ${ls} loan  lltv ${Number(p.lltv) / 1e16}%  supplied ${formatUnits(m[0], ldec)} borrowed ${formatUnits(m[2], ldec)}  id ${l.args.id.slice(0, 18)}…`);
  }

  // What else uses these tokens at all: any balance held by Morpho.
  console.log('\nMorpho Blue balances of the Chipworks stocks:');
  for (const [addr, s] of mine) {
    const b = await c.readContract({ address: addr, abi: ERC20, functionName: 'balanceOf', args: [MORPHO] }).catch(() => null);
    if (b && b > 0n) console.log(`  ${s}: ${formatUnits(b, 8)}`);
  }

  // Sanity: the biggest USDC-loan markets, to see what IS on Base.
  const usdcMarkets = logs.filter((l) => getAddress(l.args.marketParams.loanToken) === getAddress(USDC));
  const sized = [];
  for (const l of usdcMarkets) {
    const m = await c.readContract({ address: MORPHO, abi: MORPHO_ABI, functionName: 'market', args: [l.args.id] });
    if (m[0] > 0n) sized.push({ id: l.args.id, collateral: l.args.marketParams.collateralToken, supply: m[0], borrow: m[2] });
  }
  sized.sort((a, b) => (b.supply > a.supply ? 1 : -1));
  console.log(`\nlargest USDC-loan markets on Base (of ${usdcMarkets.length}):`);
  for (const s of sized.slice(0, 12)) console.log(`  collateral ${await sym(s.collateral)}  supplied ${Number(formatUnits(s.supply, 6)).toLocaleString('en-US')} USDC  borrowed ${Number(formatUnits(s.borrow, 6)).toLocaleString('en-US')}`);
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
