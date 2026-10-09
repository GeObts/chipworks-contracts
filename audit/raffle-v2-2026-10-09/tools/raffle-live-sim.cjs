// Real-swap proof for Raffle v2, on the LIVE Base node via eth_simulateV1 (nothing is sent).
// Forge forks cannot execute B20 stocks, so this is where the prize is really BOUGHT:
//   pass A, block 1: deploy Raffle v2 (owner = a test EOA; real registry, router, Entropy, USDC,
//            Pot), set the keeper, create a $100 NVDAc raffle (real pool + real 30-min TWAP
//            checked), two buyers (USDC via state override) buy all 110 tickets, then the keeper
//            calls acquirePrize: the REAL Slipstream router swaps exactly 100 USDC for REAL NVDAc
//            in the REAL pool behind the TWAP guard, and the REAL Entropy is asked (seeded).
//   pass A, block 2: the reveal delivered AS Entropy, settle, balances read back.
//   pass B: same setup, but a whale pushes the real pool >1% off its TWAP in the same block
//            before the keeper's buy: acquirePrize must refuse with SpotDeviates, moving nothing.
// Run after `forge build`:  node tools/raffle/raffle-live-sim.cjs
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, encodeFunctionData, encodeDeployData, decodeFunctionResult, decodeErrorResult, getContractAddress, keccak256, encodeAbiParameters, pad, toHex, parseAbi, formatUnits } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs'), path = require('path');
const ROOT = path.resolve(__dirname, '../..');
const RPC = fs.readFileSync(path.join(ROOT, '.env'), 'utf8').match(/^BASE_RPC_URL=(.*)$/m)[1].trim();
const art = JSON.parse(fs.readFileSync(path.join(ROOT, 'out/Raffle.sol/Raffle.json'), 'utf8'));
const c = createPublicClient({ chain: base, transport: http(RPC) });

const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', ENTROPY = '0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb';
const REGISTRY = '0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458', POT = '0x3918a9B479Ce9B58238584c645079AB3bB49855B';
const ROUTER = '0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F';
const NVDA = '0xb20000000000000000000078ee7ce2fE4908108C', NVDA_POOL = '0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9';
const DEPLOYER = '0x00000000000000000000000000000000dEb10Ae1', OWNER = '0x0000000000000000000000000000000000000a11';
const KEEPER = '0x000000000000000000000000000000000000cee9', WHALE = '0x00000000000000000000000000000000000000a7';
const B1 = '0x00000000000000000000000000000000000B0001', B2 = '0x00000000000000000000000000000000000B0002';
const RAFFLE = getContractAddress({ from: DEPLOYER, nonce: 0n });
const E20 = parseAbi(['function approve(address,uint256) returns (bool)', 'function balanceOf(address) view returns (uint256)']);
const ROUTER_ABI = parseAbi(['function exactInputSingle((address tokenIn,address tokenOut,int24 tickSpacing,address recipient,uint256 deadline,uint256 amountIn,uint256 amountOutMinimum,uint160 sqrtPriceLimitX96)) payable returns (uint256)']);
const POOL_ABI = parseAbi(['function slot0() view returns (uint160,int24,uint16,uint16,uint16,bool)', 'function observe(uint32[]) view returns (int56[],uint160[])']);
const usdcSlot = (who) => keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [who, 9n]));
const WHALE_USDC = 1_000_000n * 10n ** 6n;

(async () => {
  const blockNumber = await c.getBlockNumber(); // pin every pass to one block
  const block = await c.getBlock({ blockNumber });
  const abiFor = (to) => (to === RAFFLE ? art.abi : to === ROUTER ? ROUTER_ABI : to === NVDA_POOL ? POOL_ABI : E20);
  const call = (from, to, fn, args, value) => ({ from, to, data: encodeFunctionData({ abi: abiFor(to), functionName: fn, args }), ...(value ? { value: toHex(value) } : {}) });
  const view = (to, fn, args) => call(DEPLOYER, to, fn, args);
  const deploy = { from: DEPLOYER, data: encodeDeployData({ abi: art.abi, bytecode: art.bytecode.object, args: [OWNER, USDC, ENTROPY, REGISTRY, POT, ROUTER, 86400n, 21600n] }) };
  const overrides = {
    [DEPLOYER]: { balance: toHex(10n ** 18n), nonce: '0x0' },
    [OWNER]: { balance: toHex(10n ** 18n) },
    [KEEPER]: { balance: toHex(10n ** 18n) },
    [WHALE]: { balance: toHex(10n ** 18n) },
    [USDC]: { stateDiff: { // a map, not an array
      [usdcSlot(B1)]: pad(toHex(1_000n * 10n ** 6n)), [usdcSlot(B2)]: pad(toHex(1_000n * 10n ** 6n)),
      [usdcSlot(WHALE)]: pad(toHex(WHALE_USDC)) } },
  };
  const setup = (reserve) => [
    deploy,
    call(OWNER, RAFFLE, 'setKeeper', [KEEPER]),
    call(OWNER, RAFFLE, 'createRaffle', [NVDA, 100n], reserve),
    call(B1, USDC, 'approve', [RAFFLE, 10n ** 12n]),
    call(B2, USDC, 'approve', [RAFFLE, 10n ** 12n]),
    call(B1, RAFFLE, 'buy', [1n, 50n]),
    call(B2, RAFFLE, 'buy', [1n, 60n]), // ticket 110 of 110 -> SoldOut (no swap, no draw)
    view(RAFFLE, 'quotePrize', [NVDA, 100n * 10n ** 6n]),
  ];
  const sim = async (blocks) => c.request({ method: 'eth_simulateV1', params: [{ blockStateCalls: blocks, validation: false }, toHex(blockNumber)] });
  const must = (calls, label) => calls.forEach((x, i) => { if (x.status !== '0x1') throw new Error(`${label} call ${i} reverted: ${x.error?.message ?? x.returnData}`); });
  const ok = (cond, msg) => { console.log(`${cond ? 'ok  ' : 'FAIL'} ${msg}`); if (!cond) process.exitCode = 1; };

  const q = await sim([{ stateOverrides: overrides, calls: [deploy, view(RAFFLE, 'requiredReserve', [])] }]);
  const reserve = decodeFunctionResult({ abi: art.abi, functionName: 'requiredReserve', data: q[0].calls[1].returnData });

  // ---------------- pass A: the real buy, draw and settle ----------------
  const block1 = { stateOverrides: overrides, calls: [
    ...setup(reserve),
    view(USDC, 'balanceOf', [NVDA_POOL]),
    call(KEEPER, RAFFLE, 'acquirePrize', [1n]), // THE REAL SWAP
    view(RAFFLE, 'getRaffle', [1n]),
    view(USDC, 'balanceOf', [NVDA_POOL]),
    view(NVDA, 'balanceOf', [RAFFLE]),
    view(USDC, 'balanceOf', [RAFFLE]),
  ] };
  const pA1 = await sim([block1]);
  const b1 = pA1[0].calls;
  must(b1, 'block1');
  const quote = decodeFunctionResult({ abi: art.abi, functionName: 'quotePrize', data: b1[7].returnData });
  const r1 = decodeFunctionResult({ abi: art.abi, functionName: 'getRaffle', data: b1[10].returnData });
  const bal = (i) => decodeFunctionResult({ abi: E20, functionName: 'balanceOf', data: b1[i].returnData });
  console.log(`block ${blockNumber} (${new Date(Number(block.timestamp) * 1000).toISOString()}) | Raffle v2 at ${RAFFLE} | reserve ${reserve} wei`);
  console.log(`acquirePrize gas: ${BigInt(b1[9].gasUsed)} | TWAP quote for $100: ${formatUnits(quote, 8)} NVDAc | bought: ${formatUnits(r1.prize.amount, 8)} NVDAc`);
  ok(r1.state === 4, `after the buy the raffle is Drawing (state ${r1.state}) - randomness requested only now`);
  ok(bal(11) - bal(8) === 100n * 10n ** 6n, `the REAL pool received exactly 100 USDC (the prize budget)`);
  ok(bal(12) === r1.prize.amount && r1.prize.amount > 0n, `the raffle HOLDS the ${formatUnits(r1.prize.amount, 8)} REAL NVDAc it bought before any winner exists`);
  ok(bal(13) === 10n * 10n ** 6n, `only the 10 USDC fee remains in USDC`);
  const devBps = Number((r1.prize.amount - quote) * 100000n / quote) / 10;
  ok(r1.prize.amount * 10000n >= quote * 9850n, `fill is ${devBps} bps vs the TWAP quote (floor allows -150)`);
  ok(r1.sequence > 0n, `REAL Entropy sequence ${r1.sequence} from provider ${r1.provider}`);

  const rnd = BigInt(110 * 1_000_003 + 77); // ticket 77 -> B2 (tickets 50..109)
  const pA2 = await sim([block1, { calls: [
    view(NVDA, 'balanceOf', [B2]), view(USDC, 'balanceOf', [POT]),
    { from: ENTROPY, to: RAFFLE, data: encodeFunctionData({ abi: art.abi, functionName: '_entropyCallback', args: [r1.sequence, r1.provider, pad(toHex(rnd))] }) },
    call(B1, RAFFLE, 'settle', [1n]),
    view(NVDA, 'balanceOf', [B2]), view(USDC, 'balanceOf', [POT]),
    view(NVDA, 'balanceOf', [RAFFLE]), view(USDC, 'balanceOf', [RAFFLE]), view(RAFFLE, 'getRaffle', [1n]),
    view(RAFFLE, 'ethOwed', [OWNER]),
  ] }]);
  const b2 = pA2[1].calls;
  must(b2, 'block2');
  const n = (i) => decodeFunctionResult({ abi: E20, functionName: 'balanceOf', data: b2[i].returnData });
  const r2 = decodeFunctionResult({ abi: art.abi, functionName: 'getRaffle', data: b2[8].returnData });
  ok(r2.state === 6 && r2.winner.toLowerCase() === B2.toLowerCase() && r2.winningTicket === 77n, `settled: winning ticket ${r2.winningTicket}, winner ${r2.winner}`);
  ok(n(4) - n(0) === r1.prize.amount, `winner received the ${formatUnits(n(4) - n(0), 8)} REAL NVDAc that was bought`);
  ok(n(5) - n(1) === 10n * 10n ** 6n, `Pot received ${formatUnits(n(5) - n(1), 6)} USDC (the 10% on top)`);
  ok(n(6) === 0n && n(7) === 0n, 'raffle holds no NVDAc and no USDC afterwards');
  const owed = decodeFunctionResult({ abi: art.abi, functionName: 'ethOwed', data: b2[9].returnData });
  ok(owed > 0n, `leftover reserve ${owed} wei credited to the creator`);

  // ---------------- pass B: the manipulation guard on the real pool ----------------
  const pushAt = Number(blockNumber);
  const pB = await sim([{ stateOverrides: overrides, calls: [
    ...setup(reserve),
    view(NVDA_POOL, 'slot0', []),
    call(WHALE, USDC, 'approve', [ROUTER, WHALE_USDC]),
    call(WHALE, ROUTER, 'exactInputSingle', [{ tokenIn: USDC, tokenOut: NVDA, tickSpacing: 10, recipient: WHALE, deadline: block.timestamp + 3600n, amountIn: WHALE_USDC, amountOutMinimum: 0n, sqrtPriceLimitX96: 0n }]),
    view(NVDA_POOL, 'slot0', []),
    call(KEEPER, RAFFLE, 'acquirePrize', [1n]),
    view(RAFFLE, 'getRaffle', [1n]),
    view(USDC, 'balanceOf', [RAFFLE]),
  ] }]);
  const bb = pB[0].calls;
  [0, 1, 2, 3, 4, 5, 6, 8, 9, 10].forEach((i) => { if (bb[i].status !== '0x1') throw new Error(`pass B call ${i} reverted: ${bb[i].error?.message ?? bb[i].returnData}`); });
  const s0 = decodeFunctionResult({ abi: POOL_ABI, functionName: 'slot0', data: bb[8].returnData });
  const s1 = decodeFunctionResult({ abi: POOL_ABI, functionName: 'slot0', data: bb[11].returnData });
  console.log(`pass B @${pushAt}: a $${formatUnits(WHALE_USDC, 6)} whale buy moved the real pool's tick ${s0[1]} -> ${s1[1]} (${Number(s1[1]) - Number(s0[1])} ticks)`);
  ok(bb[12].status === '0x0', 'the keeper\'s buy against the pushed pool reverted');
  // eth_simulateV1 puts a failed call's revert data in error.data, not returnData.
  const revertData = bb[12].error?.data ?? bb[12].returnData;
  let err;
  try { err = decodeErrorResult({ abi: art.abi, data: revertData }); } catch (e) { err = { errorName: 'undecoded', args: [revertData] }; }
  ok(err.errorName === 'AcquireRefused' && Number(err.args[1]) === 5, `refused with ${err.errorName}(${err.args?.map(String).join(', ')}) - 5 = SpotDeviates`);
  const rB = decodeFunctionResult({ abi: art.abi, functionName: 'getRaffle', data: bb[13].returnData });
  const usdcB = decodeFunctionResult({ abi: E20, functionName: 'balanceOf', data: bb[14].returnData });
  ok(rB.state === 2 && usdcB === 110n * 10n ** 6n, 'nothing moved: still SoldOut, all 110 USDC still held');
})().catch((e) => { console.error(e.message ?? e); process.exit(1); });
