// How much does a round-sized USDC -> WETH -> $CHIP buy move the price? Live quoters, no state change.
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, formatUnits, parseUnits } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const c = createPublicClient({ chain: base, transport: http(env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim()) });

const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const WETH = '0x4200000000000000000000000000000000000006';
const LOTTERY = '0x2F68874F0D09A1319059Eb34868E4d2e770670F0';
const V3Q = '0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a';
const V4Q = '0x0d5e0F971ED27FBfF6c2837bf31316121532048D';
const STATEVIEW = '0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71';
const POOL_ID = '0xbcdd8383e38069f626846b94e93ee4d2c00cadfcce4b9457b0b8b04289030345';

const V3ABI = parseAbi(['struct P { address tokenIn; address tokenOut; uint256 amountIn; uint24 fee; uint160 sqrtPriceLimitX96; }',
  'function quoteExactInputSingle(P params) returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)']);
const V4ABI = parseAbi(['struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }',
  'struct QuoteExactSingleParams { PoolKey poolKey; bool zeroForOne; uint128 exactAmount; bytes hookData; }',
  'function quoteExactInputSingle(QuoteExactSingleParams params) returns (uint256 amountOut, uint256 gasEstimate)']);
const LOT = parseAbi(['struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }', 'function poolKey() view returns (PoolKey)', 'function v3Fee() view returns (uint24)']);
const SV = parseAbi(['function getLiquidity(bytes32) view returns (uint128)', 'function getSlot0(bytes32) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)']);

(async () => {
  const key = await c.readContract({ address: LOTTERY, abi: LOT, functionName: 'poolKey' });
  const v3Fee = await c.readContract({ address: LOTTERY, abi: LOT, functionName: 'v3Fee' }).catch(() => 500);
  const [liq, slot0] = await Promise.all([c.readContract({ address: STATEVIEW, abi: SV, functionName: 'getLiquidity', args: [POOL_ID] }), c.readContract({ address: STATEVIEW, abi: SV, functionName: 'getSlot0', args: [POOL_ID] })]);
  console.log(`poolKey fee ${key.fee} tickSpacing ${key.tickSpacing} hooks ${key.hooks}; active liquidity ${liq}; lpFee ${slot0[3]}; tick ${slot0[1]}`);
  const zeroForOne = key.currency0.toLowerCase() === WETH.toLowerCase(); // selling WETH for CHIP

  const quote = async (usd) => {
    const { result: v3 } = await c.simulateContract({ address: V3Q, abi: V3ABI, functionName: 'quoteExactInputSingle', args: [{ tokenIn: USDC, tokenOut: WETH, amountIn: parseUnits(String(usd), 6), fee: Number(v3Fee), sqrtPriceLimitX96: 0n }] });
    const weth = v3[0];
    const { result: v4 } = await c.simulateContract({ address: V4Q, abi: V4ABI, functionName: 'quoteExactInputSingle', args: [{ poolKey: key, zeroForOne, exactAmount: weth, hookData: '0x' }] });
    return { weth, chip: v4[0] };
  };
  const ref = await quote(10);
  const refPx = Number(formatUnits(ref.chip, 18)) / 10; // CHIP per $ at a $10 buy
  const rows = [];
  for (const usd of [100, 500, 1000, 2500, 5000, 10000, 25000]) {
    try {
      const q = await quote(usd);
      const perUsd = Number(formatUnits(q.chip, 18)) / usd;
      rows.push({ usdIn: usd, wethLeg: Number(formatUnits(q.weth, 18)).toFixed(5), chipOut: Math.round(Number(formatUnits(q.chip, 18))).toLocaleString('en-US'),
        avgPriceVsSmallBuy: `${(((refPx / perUsd) - 1) * 100).toFixed(2)}% worse` });
    } catch (e) { rows.push({ usdIn: usd, error: (e.shortMessage || e.message).slice(0, 80) }); }
  }
  console.log(`reference: $10 buys ${Math.round(Number(formatUnits(ref.chip, 18))).toLocaleString('en-US')} CHIP ( $${(10 / Number(formatUnits(ref.chip, 18))).toExponential(3)} per CHIP incl. fees )`);
  console.table(rows);
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
