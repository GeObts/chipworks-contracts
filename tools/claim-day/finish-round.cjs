// Build ONE transaction that settles every unsettled stock of a round and finalizes it, via
// Multicall3.aggregate3 (each call allowFailure=true, so a stock the keeper settles first cannot
// sink the rest). Simulates it on the live node, then prints the tx fields and a Safe batch file.
// Usage: ROUND=4 node finish-round.cjs
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, encodeFunctionData, decodeFunctionResult, decodeErrorResult } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const RPC = env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim();
const c = createPublicClient({ chain: base, transport: http(RPC) });

const ROUNDS = '0xa8192D4Ee3526CA8158cBE83b2FC05BdC205bed3';
const MC3 = '0xcA11bde05977b3631167028862bE2a173976CA11';
const ROUND = BigInt(process.env.ROUND || 4);
const R = parseAbi([
  'function roundStocks(uint256) view returns (address[])', 'function stockSettled(uint256,address) view returns (bool)',
  'function settleStock(uint256 roundId, address stock)', 'function finalizeRound(uint256 roundId)',
  'function getRound(uint256) view returns ((uint8 state, uint64 openedAt, uint64 finalizedAt, uint128 budget, uint128 spent, uint256 totalWeight))',
  'error WrongState(uint256 roundId, uint8 actual, uint8 expected)', 'error AlreadySettled(uint256 roundId, address stock)', 'error NotSettled(uint256 roundId, address stock)',
]);
const MC = parseAbi(['struct Call3 { address target; bool allowFailure; bytes callData; }', 'struct Result { bool success; bytes returnData; }',
  'function aggregate3(Call3[] calls) payable returns (Result[] returnData)']);

(async () => {
  const round = await c.readContract({ address: ROUNDS, abi: R, functionName: 'getRound', args: [ROUND] });
  if (round.state !== 2) { console.log(`round ${ROUND} state ${round.state} - not Buying, nothing to do`); return; }
  const stocks = await c.readContract({ address: ROUNDS, abi: R, functionName: 'roundStocks', args: [ROUND] });
  const todo = [];
  for (const s of stocks) if (!(await c.readContract({ address: ROUNDS, abi: R, functionName: 'stockSettled', args: [ROUND, s] }))) todo.push(s);
  console.log(`round ${ROUND}: ${todo.length} unsettled of ${stocks.length}: ${todo.join(', ')}`);

  const calls = [
    ...todo.map((s) => ({ target: ROUNDS, allowFailure: true, callData: encodeFunctionData({ abi: R, functionName: 'settleStock', args: [ROUND, s] }) })),
    { target: ROUNDS, allowFailure: true, callData: encodeFunctionData({ abi: R, functionName: 'finalizeRound', args: [ROUND] }) },
  ];
  const data = encodeFunctionData({ abi: MC, functionName: 'aggregate3', args: [calls] });

  // Simulate from an arbitrary EOA on the live node, then read the round afterwards in the same block.
  const from = '0x000000000000000000000000000000000000bEEF';
  const readRound = encodeFunctionData({ abi: R, functionName: 'getRound', args: [ROUND] });
  const sim = await c.request({ method: 'eth_simulateV1', params: [{ blockStateCalls: [{ calls: [
    { from, to: MC3, data, gas: '0x1c9c380' }, { from, to: ROUNDS, data: readRound },
  ] }], validation: false }, 'latest'] });
  const [agg, after] = sim[0].calls;
  if (agg.status !== '0x1') { console.log('aggregate3 reverted:', agg.error); process.exit(1); }
  const results = decodeFunctionResult({ abi: MC, functionName: 'aggregate3', data: agg.returnData });
  results.forEach((r, i) => {
    const label = i < todo.length ? `settleStock(${todo[i]})` : 'finalizeRound';
    let why = '';
    if (!r.success) { try { const e = decodeErrorResult({ abi: R, data: r.returnData }); why = `${e.errorName}`; } catch { why = r.returnData.slice(0, 10); } }
    console.log(`  ${r.success ? 'OK  ' : 'FAIL'} ${label} ${why}`);
  });
  const st = decodeFunctionResult({ abi: R, functionName: 'getRound', data: after.returnData });
  console.log(`simulated: gasUsed ${BigInt(agg.gasUsed)}; round ${ROUND} state after = ${st.state} (3 = Finalized), spent ${Number(st.spent) / 1e6} of ${Number(round.budget) / 1e6}`);

  const gasLimit = (BigInt(agg.gasUsed) * 13n) / 10n;
  console.log(`\nSEND THIS (from ANY wallet, value 0):\n  to:   ${MC3}\n  data: ${data}\n  gas:  ${gasLimit}`);
  const out = path.join(__dirname, `finish-round-${ROUND}.safe.json`);
  fs.writeFileSync(out, JSON.stringify({ version: '1.0', chainId: '8453', createdAt: Date.now(), meta: { name: `Finish round ${ROUND}`, description: `settleStock x${todo.length} + finalizeRound(${ROUND}) via Multicall3, each allowFailure` },
    transactions: [{ to: MC3, value: '0', data, contractMethod: null, contractInputsValues: null }] }, null, 2));
  console.log(`Safe Transaction Builder file: ${out}`);
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
