// The exact setMaxPrincipal amounts at the live $CHIP price, plus a real chipped Noun to fork-test with.
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, parseAbiItem, formatUnits, parseUnits, getAddress } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const c = createPublicClient({ chain: base, transport: http(env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim()) });

const STATEVIEW = '0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71';
const POOL_ID = '0xbcdd8383e38069f626846b94e93ee4d2c00cadfcce4b9457b0b8b04289030345';
const ETH_USD = '0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70';
const V3Q = '0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a';
const V4Q = '0x0d5e0F971ED27FBfF6c2837bf31316121532048D';
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const WETH = '0x4200000000000000000000000000000000000006';
const CHIP = '0x75Af968d2e58749FDA1b42C58186B76f5E511bA3';
const V2 = '0x762984092Cb9404982835551970C73b5838d5411';
const LOANS = '0x123Bc476594A80B0d99Ca6510e87E249b1C5EC5f';
const BASED = '0xBf57D0535E10E7033447174404b9bEd3D9eF4C88';
const DARK = '0xd45E54B1A5e77d6E9469a4174d34f27D5D16270C';

const SV = parseAbi(['function getSlot0(bytes32) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)']);
const FEED = parseAbi(['function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)', 'function decimals() view returns (uint8)']);
const V3ABI = parseAbi(['function quoteExactInputSingle((address tokenIn,address tokenOut,uint256 amountIn,uint24 fee,uint160 sqrtPriceLimitX96)) returns (uint256,uint160,uint32,uint256)']);
const V4ABI = parseAbi(['struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }',
  'struct QuoteExactSingleParams { PoolKey poolKey; bool zeroForOne; uint128 exactAmount; bytes hookData; }',
  'function quoteExactInputSingle(QuoteExactSingleParams params) returns (uint256 amountOut, uint256 gasEstimate)']);
const KEY = { currency0: WETH, currency1: CHIP, fee: 8388608, tickSpacing: 200, hooks: '0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544' };
const NFT = parseAbi(['function ownerOf(uint256) view returns (address)']);
const ACT = parseAbi(['function activation(address,uint256) view returns (bool active, uint32 tierBps, address owner)']);

(async () => {
  // ---- price: pool mid, and a $1 round trip for sanity
  const [slot0, feed, fdec] = await Promise.all([
    c.readContract({ address: STATEVIEW, abi: SV, functionName: 'getSlot0', args: [POOL_ID] }),
    c.readContract({ address: ETH_USD, abi: FEED, functionName: 'latestRoundData' }),
    c.readContract({ address: ETH_USD, abi: FEED, functionName: 'decimals' }),
  ]);
  const ethUsd = Number(feed[1]) / 10 ** Number(fdec);
  const sq = Number(slot0[0]) / 2 ** 96;
  const chipPerWeth = sq * sq;           // currency0 = WETH, currency1 = CHIP
  const chipUsdMid = ethUsd / chipPerWeth;
  const { result: q3 } = await c.simulateContract({ address: V3Q, abi: V3ABI, functionName: 'quoteExactInputSingle', args: [{ tokenIn: USDC, tokenOut: WETH, amountIn: parseUnits('1', 6), fee: 500, sqrtPriceLimitX96: 0n }] });
  const { result: q4 } = await c.simulateContract({ address: V4Q, abi: V4ABI, functionName: 'quoteExactInputSingle', args: [{ poolKey: KEY, zeroForOne: true, exactAmount: q3[0], hookData: '0x' }] });
  const chipPerDollarTraded = Number(formatUnits(q4[0], 18));
  console.log(`ETH/USD ${ethUsd.toFixed(2)}`);
  console.log(`$CHIP mid price  $${chipUsdMid.toExponential(4)}  (${(1 / chipUsdMid).toLocaleString('en-US', { maximumFractionDigits: 0 })} CHIP per $1)`);
  console.log(`$CHIP traded $1  -> ${chipPerDollarTraded.toLocaleString('en-US', { maximumFractionDigits: 0 })} CHIP  ($${(1 / chipPerDollarTraded).toExponential(4)} each, after fees)`);
  console.log(`implied circulating value at 100B supply: $${(chipUsdMid * 100e9).toLocaleString('en-US', { maximumFractionDigits: 0 })}`);

  // ---- caps at 60% LTV, on the MID price (conservative: the tradeable price is slightly worse)
  console.log('\n--- setMaxPrincipal at 60% LTV ---');
  for (const [label, floorUsd] of [['Based', 38], ['Dark', 80]]) {
    const maxLoanUsd = floorUsd * 0.6;
    const chip = maxLoanUsd / chipUsdMid;
    const wei = BigInt(Math.floor(chip)) * 10n ** 18n;
    console.log(`  ${label.padEnd(6)} floor $${floorUsd}  60% = $${maxLoanUsd.toFixed(2)}  ->  ${Math.floor(chip).toLocaleString('en-US')} CHIP`);
    console.log(`         setMaxPrincipal arg (wei): ${wei}`);
  }

  // ---- a real, currently-chipped Noun for the fork test
  console.log('\n--- fork-test fixtures: live activated Nouns ---');
  const latest = await c.getBlockNumber();
  const logs = [];
  for (let a = 50208000n; a <= latest; a += 100000n) {
    logs.push(...await c.getLogs({ address: V2, event: parseAbiItem('event Activated(address indexed collection, uint256 indexed tokenId, address indexed owner, uint8 tier, uint256 chipBurned)'), fromBlock: a, toBlock: a + 99999n > latest ? latest : a + 99999n }));
  }
  for (const [label, col] of [['Based', BASED], ['Dark', DARK]]) {
    const mine = logs.filter((l) => getAddress(l.args.collection) === getAddress(col));
    let found = 0;
    for (const l of mine) {
      const id = l.args.tokenId;
      const [act, owner] = await Promise.all([
        c.readContract({ address: V2, abi: ACT, functionName: 'activation', args: [col, id] }),
        c.readContract({ address: col, abi: NFT, functionName: 'ownerOf', args: [id] }).catch(() => null),
      ]);
      if (!act[0] || !owner) continue;
      if (getAddress(owner) === getAddress(LOANS)) continue;
      console.log(`  ${label} #${id}  owner ${owner}  tierBps ${act[1]}`);
      if (++found === 3) break;
    }
    if (!found) console.log(`  ${label}: no live activated token found`);
  }
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
