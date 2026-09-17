// Re-order the Chipworks USDC vault's queues by what the markets actually pay (see vault-rates.cjs).
//
//   supply queue:   stocks first (unchanged: the borrow product), then deep markets HIGHEST rate first
//   withdraw queue: deep markets LOWEST rate first, stocks last - so withdrawals leave from the worst payers
//
// Neither call is timelocked in MetaMorpho (setSupplyQueue / updateWithdrawQueue are allocator actions).
// Simulated from the Safe against live state, then a 25,000 deposit and a 5,000 withdrawal show where money goes.
//
//   node vault-queue-bundle.cjs
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { encodeFunctionData, decodeFunctionResult, parseAbi } = req('viem');
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '../..');
const env = fs.readFileSync(path.join(ROOT, '.env'), 'utf8');
const RPC = env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim();

const SAFE = '0xe1096B727499a3f70FaD8bc0267F5e69d01373C7';
const VAULT = '0x6B0EF5dd1cED6E26c384E4CcAf72f9dC0A1093d6';
const MORPHO = '0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb';
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const ID = {
  AAPL: '0xae1a30486234bf7e7ac166c7c03d9bc5f2cd8a39be2c48e73c665ac7148c3c28', GOOGL: '0xa3913d896b7e9c0e0a84f1be27d376cf2065616101cb7c44674af8a154e684cc',
  NVDA: '0xb4b42dd66cef25614b94510a910d54b2c148e7621d22b4271566724beda63d13', META: '0x44b343b5087c0bd34207cb5c199f12030777bf6b8c0a128438246f1212f37ca5',
  cbBTC: '0x9103c3b4e834476c9a62ea009ba2c884ee42e94e6e314a26f04d312434191836', USDe: '0x54cf9be57fdfa6457a660991907434ff9d295c465a603a50126ff647d50b7354',
  WETH: '0x8793cf302b8ffd655ab97bd1c695dbd967807e8367a65cb2f4edaf1380ba1bda', cbXRP: '0xd4a903dc6d949519060c7707f9604fdc9772c046e05c2e3a8fce0bd7196e4109',
};
const NEW_SUPPLY = ['AAPL', 'GOOGL', 'NVDA', 'META', 'cbXRP', 'WETH', 'cbBTC', 'USDe'];
const NEW_WITHDRAW = ['USDe', 'cbBTC', 'WETH', 'cbXRP', 'AAPL', 'GOOGL', 'NVDA', 'META'];
const V = parseAbi([
  'function setSupplyQueue(bytes32[] newSupplyQueue)', 'function updateWithdrawQueue(uint256[] indexes)',
  'function supplyQueue(uint256) view returns (bytes32)', 'function withdrawQueue(uint256) view returns (bytes32)',
  'function deposit(uint256,address) returns (uint256)', 'function withdraw(uint256,address,address) returns (uint256)',
]);
const ERC20 = parseAbi(['function transfer(address,uint256) returns (bool)', 'function approve(address,uint256) returns (bool)']);
const MB = parseAbi(['function position(bytes32,address) view returns (uint256,uint128,uint128)', 'function market(bytes32) view returns (uint128,uint128,uint128,uint128,uint128,uint128)']);
const hex = (n) => '0x' + BigInt(n).toString(16);
const rpc = async (method, params) => {
  const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(JSON.stringify(j.error));
  return j.result;
};
const call = async (to, abi, fn, args = []) => decodeFunctionResult({ abi, functionName: fn, data: await rpc('eth_call', [{ to, data: encodeFunctionData({ abi, functionName: fn, args }) }, 'latest']) });
const nameOf = (id) => Object.keys(ID).find((k) => ID[k] === String(id).toLowerCase());

(async () => {
  const problems = [];
  // Read the LIVE withdraw queue: updateWithdrawQueue takes indexes into it, so they must come from chain.
  const liveW = [];
  for (let i = 0n; i < 8n; i++) liveW.push(nameOf(await call(VAULT, V, 'withdrawQueue', [i])));
  const liveS = [];
  for (let i = 0n; i < 8n; i++) liveS.push(nameOf(await call(VAULT, V, 'supplyQueue', [i])));
  console.log(`live supply queue:   ${liveS.join(' > ')}\nlive withdraw queue: ${liveW.join(' > ')}`);
  const indexes = NEW_WITHDRAW.map((n) => BigInt(liveW.indexOf(n)));
  if (indexes.some((i) => i < 0n)) throw new Error('a market is missing from the live withdraw queue');

  const txs = [
    { label: `vault.setSupplyQueue([${NEW_SUPPLY.join(', ')}])`, data: encodeFunctionData({ abi: V, functionName: 'setSupplyQueue', args: [NEW_SUPPLY.map((n) => ID[n])] }) },
    { label: `vault.updateWithdrawQueue([${indexes.join(',')}]) = ${NEW_WITHDRAW.join(' > ')}`, data: encodeFunctionData({ abi: V, functionName: 'updateWithdrawQueue', args: [indexes] }) },
  ];
  const DEP = '0x00000000000000000000000000000000c41b0003';
  const reads = (who) => Object.keys(ID).map((n) => ({ from: who, to: MORPHO, data: encodeFunctionData({ abi: MB, functionName: 'position', args: [ID[n], VAULT] }), n }));
  const qReads = [...[0, 1, 2, 3, 4, 5, 6, 7].map((i) => ({ from: SAFE, to: VAULT, data: encodeFunctionData({ abi: V, functionName: 'supplyQueue', args: [BigInt(i)] }), q: 's' })),
    ...[0, 1, 2, 3, 4, 5, 6, 7].map((i) => ({ from: SAFE, to: VAULT, data: encodeFunctionData({ abi: V, functionName: 'withdrawQueue', args: [BigInt(i)] }), q: 'w' }))];
  const strip = ({ from, to, data, gas }) => ({ from, to, data, ...(gas ? { gas } : {}) });
  const res = await rpc('eth_simulateV1', [{ blockStateCalls: [
    { calls: [...txs.map((t) => ({ from: SAFE, to: VAULT, data: t.data, gas: hex(1_000_000) })), ...qReads.map(strip), { from: '0x000000000000000000000000000000000000bEEF', to: VAULT, data: txs[0].data, gas: hex(500000) }] },
    { calls: [
      { from: MORPHO, to: USDC, data: encodeFunctionData({ abi: ERC20, functionName: 'transfer', args: [DEP, 25_000_000_000n] }), gas: hex(200000) },
      { from: DEP, to: USDC, data: encodeFunctionData({ abi: ERC20, functionName: 'approve', args: [VAULT, 25_000_000_000n] }), gas: hex(200000) },
      ...reads(DEP).map(strip),
      { from: DEP, to: VAULT, data: encodeFunctionData({ abi: V, functionName: 'deposit', args: [25_000_000_000n, DEP] }), gas: hex(3_000_000) },
      ...reads(DEP).map(strip),
      { from: DEP, to: VAULT, data: encodeFunctionData({ abi: V, functionName: 'withdraw', args: [5_000_000_000n, DEP, DEP] }), gas: hex(3_000_000) },
      ...reads(DEP).map(strip),
    ] },
  ], validation: false }, 'latest']);

  const c1 = res[0].calls;
  console.log('\nTHE BUNDLE (2 calls from the Safe), simulated:');
  txs.forEach((t, i) => { const ok = c1[i].status === '0x1'; if (!ok) problems.push(`${t.label} reverted`); console.log(`  ${i + 1}. ${ok ? 'OK  ' : 'FAIL'} ${t.label}`); });
  const gotS = c1.slice(2, 10).map((x) => nameOf(decodeFunctionResult({ abi: V, functionName: 'supplyQueue', data: x.returnData })));
  const gotW = c1.slice(10, 18).map((x) => nameOf(decodeFunctionResult({ abi: V, functionName: 'withdrawQueue', data: x.returnData })));
  console.log(`  supply queue after:   ${gotS.join(' > ')}\n  withdraw queue after: ${gotW.join(' > ')}`);
  if (gotS.join() !== NEW_SUPPLY.join()) problems.push('supply queue not as intended');
  if (gotW.join() !== NEW_WITHDRAW.join()) problems.push('withdraw queue not as intended');
  const stranger = c1[18];
  if (stranger.status === '0x1') problems.push('a stranger could set the supply queue');
  console.log(`  ${stranger.status === '0x1' ? 'BAD' : 'ok '} a stranger cannot change the queue`);

  const c2 = res[1].calls;
  const names = Object.keys(ID);
  const pos = (from) => names.map((n, i) => BigInt(decodeFunctionResult({ abi: MB, functionName: 'position', data: c2[from + i].returnData })[0]));
  const p0 = pos(2), p1 = pos(11), p2 = pos(20);
  if (c2[10].status !== '0x1') problems.push('deposit reverted');
  if (c2[19].status !== '0x1') problems.push('withdraw reverted');
  const moved = (a, b) => names.filter((_, i) => a[i] !== b[i]);
  const depInto = moved(p0, p1), wdFrom = moved(p1, p2);
  console.log(`\nA 25,000 USDC DEPOSIT lands in: ${depInto.join(', ')}`);
  console.log(`A 5,000 USDC WITHDRAWAL comes out of: ${wdFrom.join(', ') || '(nothing?)'}`);
  if (!depInto.includes('cbXRP') || depInto.includes('cbBTC') || depInto.includes('USDe')) problems.push('deposit did not overflow into cbXRP first');
  if (wdFrom.some((n) => ['AAPL', 'GOOGL', 'NVDA', 'META'].includes(n))) problems.push('a withdrawal touched a stock market');

  if (!problems.length) {
    const bundle = { version: '1.0', chainId: '8453', createdAt: Date.now(),
      meta: { name: 'vault-queues-by-rate', description: `Supply: ${NEW_SUPPLY.join(' > ')}. Withdraw: ${NEW_WITHDRAW.join(' > ')}. Stocks stay first in / last out; deep markets ordered by 7-day rate.`, txBuilderVersion: '1.16.5', createdFromSafeAddress: SAFE, createdFromOwnerAddress: '' },
      transactions: txs.map((t) => ({ to: VAULT, value: '0', data: t.data, contractMethod: null, contractInputsValues: null })) };
    fs.writeFileSync(path.join(ROOT, 'safecalls-vault-queues-by-rate.json'), JSON.stringify(bundle, null, 2) + '\n');
    console.log('\nwritten: safecalls-vault-queues-by-rate.json');
  }
  console.log('\nproblems:', problems);
  if (problems.length) process.exit(1);
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
