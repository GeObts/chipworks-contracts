// The Safe bundle that deploys and configures the Chipworks USDC vault - a stock MetaMorpho V1.1
// vault from Morpho's own factory - simulated end to end from the Safe on the live node, then
// used: a depositor deposits, 30 days pass, they withdraw, and the Safe redeems its fee.
//
// Nothing is signed or sent. Writes safecalls-morpho-vault.json at the repo root for Transaction
// Builder, and prints every call decoded so the bundle can be read before it is signed.
//
//   node vault-bundle.cjs
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { encodeFunctionData, decodeFunctionResult, decodeErrorResult, parseAbi, getAddress, formatUnits, stringToHex, keccak256, encodeAbiParameters } = req('viem');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const RPC = env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim();

// ---- every value that goes on chain, in one place -------------------------------------------
const FACTORY = '0xFf62A7c278C62eD665133147129245053Bbf5918'; // MetaMorpho Factory V1.1 (docs.morpho.org addresses, Base)
const MORPHO = '0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb'; // Morpho (Blue)
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const SAFE = '0xe1096B727499a3f70FaD8bc0267F5e69d01373C7';
const IRM = '0x46415998764C29aB2a25CbeA6254146D50D22687'; // AdaptiveCurveIrm
const NAME = 'Chipworks USDC';
const SYMBOL = 'cwUSDC';
const SALT = stringToHex('chipworks-usdc-1', { size: 32 });
const FEE = 150000000000000000n; // 0.15e18 = 15% of interest
const TIMELOCK = 86400n; // 1 day, set as the LAST call
const DEEP_CAP = 5_000_000n * 10n ** 6n;
const STOCK_CAP = 2_000n * 10n ** 6n;

// Supply-queue order is the order listed: STOCKS FIRST (see MorphoVaultRehearsal.t.sol for why).
const MARKETS = [
  { sym: 'AAPLc', collateral: '0xb200000000000000000000C2e324d24d7eEcd1fb', oracle: '0xEcC5c9bf18CB2CfC94C2f7EFf8BDd5837A60AB0e', lltv: 625000000000000000n, cap: STOCK_CAP },
  { sym: 'GOOGLc', collateral: '0xb2000000000000000000002D0BA3164cc74f58B7', oracle: '0x24DC11055aa5b2C5692E4B77d7285c4f0fd9Cf99', lltv: 770000000000000000n, cap: STOCK_CAP },
  { sym: 'NVDAc', collateral: '0xb20000000000000000000078ee7ce2fE4908108C', oracle: '0x4F698C04d01d9CebCDd9494c189aBdD6C5453f84', lltv: 625000000000000000n, cap: STOCK_CAP },
  { sym: 'METAc', collateral: '0xb2000000000000000000008bC8786B856E61707C', oracle: '0x4752B27dFc1931eb9a5DFEFC7FBC9d0af9020dC7', lltv: 625000000000000000n, cap: STOCK_CAP },
  { sym: 'cbBTC', collateral: '0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf', oracle: '0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9', lltv: 860000000000000000n, cap: DEEP_CAP },
  { sym: 'USDe', collateral: '0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34', oracle: '0xF4b17C79492d68775e22e8Dd0a2Bb22854A39A47', lltv: 915000000000000000n, cap: DEEP_CAP },
  { sym: 'WETH', collateral: '0x4200000000000000000000000000000000000006', oracle: '0xFEa2D58cEfCb9fcb597723c6bAE66fFE4193aFE4', lltv: 860000000000000000n, cap: DEEP_CAP },
  { sym: 'cbXRP', collateral: '0xcb585250f852C6c6bf90434AB21A00f02833a4af', oracle: '0x031b2EFC8d70042Ac8d9f5c793c4149eC4b60fdE', lltv: 625000000000000000n, cap: DEEP_CAP },
].map((m) => {
  const params = { loanToken: USDC, collateralToken: m.collateral, oracle: m.oracle, irm: IRM, lltv: m.lltv };
  const id = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'address' }, { type: 'address' }, { type: 'address' }, { type: 'uint256' }], [params.loanToken, params.collateralToken, params.oracle, params.irm, params.lltv]));
  return { ...m, params, id };
});

const MP = 'struct MarketParams { address loanToken; address collateralToken; address oracle; address irm; uint256 lltv; }';
const F = parseAbi(['function createMetaMorpho(address initialOwner, uint256 initialTimelock, address asset, string name, string symbol, bytes32 salt) returns (address)', 'function isMetaMorpho(address) view returns (bool)']);
const V = parseAbi([
  MP,
  'function setFeeRecipient(address newFeeRecipient)',
  'function setFee(uint256 newFee)',
  'function submitCap(MarketParams marketParams, uint256 newSupplyCap)',
  'function acceptCap(MarketParams marketParams)',
  'function setSupplyQueue(bytes32[] newSupplyQueue)',
  'function updateWithdrawQueue(uint256[] indexes)',
  'function withdrawQueue(uint256) view returns (bytes32)',
  'function submitTimelock(uint256 newTimelock)',
  'function owner() view returns (address)', 'function curator() view returns (address)', 'function guardian() view returns (address)',
  'function fee() view returns (uint96)', 'function feeRecipient() view returns (address)', 'function timelock() view returns (uint256)',
  'function asset() view returns (address)', 'function name() view returns (string)', 'function symbol() view returns (string)', 'function MORPHO() view returns (address)',
  'function config(bytes32) view returns (uint184 cap, bool enabled, uint64 removableAt)',
  'function supplyQueueLength() view returns (uint256)', 'function supplyQueue(uint256) view returns (bytes32)',
  'function withdrawQueueLength() view returns (uint256)',
  'function deposit(uint256 assets, address receiver) returns (uint256)', 'function redeem(uint256 shares, address receiver, address owner) returns (uint256)',
  'function balanceOf(address) view returns (uint256)', 'function totalAssets() view returns (uint256)',
]);
const ERC20 = parseAbi(['function transfer(address,uint256) returns (bool)', 'function approve(address,uint256) returns (bool)', 'function balanceOf(address) view returns (uint256)']);
const MB = parseAbi(['function market(bytes32) view returns (uint128,uint128,uint128,uint128,uint128,uint128)', 'function position(bytes32,address) view returns (uint256,uint128,uint128)']);
const hex = (n) => '0x' + BigInt(n).toString(16);
const GAS = hex(3_000_000);
const CREATE_GAS = hex(15_000_000); // a MetaMorpho deploy is ~5M; at 3M it fails and every later call "succeeds" against empty code
const rpc = async (method, params) => {
  const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(JSON.stringify(j.error));
  return j.result;
};
const usd = (x) => Number(formatUnits(x, 6)).toLocaleString('en-US', { maximumFractionDigits: 2 });

(async () => {
  const problems = [];
  const block = BigInt(await rpc('eth_blockNumber', []));
  const now = BigInt((await rpc('eth_getBlockByNumber', [hex(block), false])).timestamp);

  // The vault address is CREATE2 over (factory, salt, init code + args): the same for any caller.
  const createData = encodeFunctionData({ abi: F, functionName: 'createMetaMorpho', args: [SAFE, 0n, USDC, NAME, SYMBOL, SALT] });
  const vault = getAddress(decodeFunctionResult({ abi: F, functionName: 'createMetaMorpho', data: await rpc('eth_call', [{ from: SAFE, to: FACTORY, data: createData }, hex(block)]) }));
  if ((await rpc('eth_getCode', [vault, hex(block)])) !== '0x') problems.push(`${vault} already has code - someone created this vault; change SALT`);

  const txs = [
    { label: `factory.createMetaMorpho(owner=Safe, timelock=0, USDC, "${NAME}", "${SYMBOL}", salt="chipworks-usdc-1") -> ${vault}`, to: FACTORY, data: createData },
    { label: 'vault.setFeeRecipient(Safe)', to: vault, data: encodeFunctionData({ abi: V, functionName: 'setFeeRecipient', args: [SAFE] }) },
    { label: 'vault.setFee(0.15e18) = 15% of interest', to: vault, data: encodeFunctionData({ abi: V, functionName: 'setFee', args: [FEE] }) },
  ];
  for (const m of MARKETS) {
    txs.push({ label: `vault.submitCap(${m.sym} @ ${Number(m.lltv) / 1e16}% LLTV, ${usd(m.cap)} USDC)   id ${m.id}`, to: vault, data: encodeFunctionData({ abi: V, functionName: 'submitCap', args: [m.params, m.cap] }) });
    txs.push({ label: `vault.acceptCap(${m.sym})  (timelock is still 0, so valid in the same block)`, to: vault, data: encodeFunctionData({ abi: V, functionName: 'acceptCap', args: [m.params] }) });
  }
  txs.push({ label: `vault.setSupplyQueue([${MARKETS.map((m) => m.sym).join(', ')}])  stocks first`, to: vault, data: encodeFunctionData({ abi: V, functionName: 'setSupplyQueue', args: [MARKETS.map((m) => m.id)] }) });
  /*
    WITHDRAWALS DRAIN THE WITHDRAW QUEUE IN ORDER, and _setCap appends markets in the order their
    caps were accepted - stocks first. Left alone, every withdrawal would pull the thin stock-market
    liquidity that Chipworks borrowers draw on before touching a cent of cbBTC. Reorder it deep
    first: deposits land in the stock markets (supply queue), withdrawals leave from the deep ones.
    Not timelocked. Indexes are positions in the CURRENT queue: [4,5,6,7] are the deep four.
  */
  txs.push({ label: 'vault.updateWithdrawQueue([4,5,6,7,0,1,2,3]) = withdraw from cbBTC, USDe, WETH, cbXRP first, stocks last', to: vault, data: encodeFunctionData({ abi: V, functionName: 'updateWithdrawQueue', args: [[4n, 5n, 6n, 7n, 0n, 1n, 2n, 3n]] }) });
  txs.push({ label: 'vault.submitTimelock(86400) = 1 day. LAST, and raising it applies immediately', to: vault, data: encodeFunctionData({ abi: V, functionName: 'submitTimelock', args: [TIMELOCK] }) });

  // ---- block 1: the bundle, as the Safe, then read everything back --------------------------
  const r = (fn, args = [], to = vault, abi = V) => ({ from: SAFE, to, data: encodeFunctionData({ abi, functionName: fn, args }), fn, abi });
  const reads = [
    r('isMetaMorpho', [vault], FACTORY, F), r('MORPHO'), r('owner'), r('curator'), r('guardian'), r('asset'), r('name'), r('symbol'),
    r('fee'), r('feeRecipient'), r('timelock'), r('supplyQueueLength'), r('withdrawQueueLength'),
    ...MARKETS.map((m) => ({ ...r('config', [m.id]), m })),
    ...MARKETS.map((_, i) => ({ ...r('supplyQueue', [BigInt(i)]), i })),
    ...MARKETS.map((_, i) => ({ ...r('withdrawQueue', [BigInt(i)]), wi: i })),
  ];
  // ---- block 2: a depositor uses it --------------------------------------------------------
  const DEP = '0x00000000000000000000000000000000c41b0002';
  const AMOUNT = 50_000n * 10n ** 6n;
  const b2 = [
    { from: MORPHO, to: USDC, data: encodeFunctionData({ abi: ERC20, functionName: 'transfer', args: [DEP, AMOUNT] }), gas: GAS }, // harness funding
    { from: DEP, to: USDC, data: encodeFunctionData({ abi: ERC20, functionName: 'approve', args: [vault, AMOUNT] }), gas: GAS },
    { from: DEP, to: vault, data: encodeFunctionData({ abi: V, functionName: 'deposit', args: [AMOUNT, DEP] }), gas: GAS },
    ...MARKETS.map((m) => ({ from: DEP, to: MORPHO, data: encodeFunctionData({ abi: MB, functionName: 'position', args: [m.id, vault] }) })),
    { from: DEP, to: vault, data: encodeFunctionData({ abi: V, functionName: 'totalAssets' }) },
  ];
  // ---- block 3: 30 days later the depositor leaves and the Safe cashes its fee ---------------
  const b3 = [
    { from: DEP, to: vault, data: encodeFunctionData({ abi: V, functionName: 'balanceOf', args: [DEP] }) },
  ];

  const sim = async (blocks) => rpc('eth_simulateV1', [{ blockStateCalls: blocks, validation: false }, hex(block)]);
  const first = await sim([
    { calls: [...txs.map((t, i) => ({ from: SAFE, to: t.to, data: t.data, gas: i === 0 ? CREATE_GAS : GAS })), ...reads.map(({ from, to, data }) => ({ from, to, data }))] },
    { calls: b2 },
    { blockOverrides: { time: hex(now + 30n * 86400n) }, calls: b3 },
  ]);
  const c1 = first[0].calls;
  console.log(`block ${block}   vault ${vault}\n\nTHE BUNDLE (${txs.length} calls, all from the Safe ${SAFE}), simulated:`);
  txs.forEach((t, i) => {
    const ok = c1[i].status === '0x1';
    if (!ok) problems.push(`call ${i + 1} reverted: ${t.label}  ${c1[i].returnData}`);
    console.log(`  ${String(i + 1).padStart(2)}. ${ok ? 'OK  ' : 'FAIL'} ${t.label}`);
  });
  const got = {};
  reads.forEach((rd, i) => {
    const c = c1[txs.length + i];
    const v = c.status === '0x1' ? decodeFunctionResult({ abi: rd.abi, functionName: rd.fn, data: c.returnData }) : 'REVERT';
    if (rd.m) got[`config ${rd.m.sym}`] = v; else if (rd.wi !== undefined) got[`withdrawQueue[${rd.wi}]`] = v; else if (rd.i !== undefined) got[`supplyQueue[${rd.i}]`] = v; else got[rd.fn] = v;
  });
  console.log('\nSTATE AFTER THE BUNDLE:');
  const expect = (k, want, show = got[k]) => {
    const ok = String(got[k]).toLowerCase() === String(want).toLowerCase();
    if (!ok) problems.push(`${k} = ${got[k]}, expected ${want}`);
    console.log(`  ${ok ? 'ok ' : 'BAD'} ${k.padEnd(20)} ${show}`);
  };
  if (c1[0].status !== '0x1') problems.push('the vault was never created - every later OK is a call to empty code');
  expect('isMetaMorpho', true, `${got.isMetaMorpho}  (Morpho's factory recognises it)`);
  expect('MORPHO', MORPHO); expect('owner', SAFE); expect('asset', USDC); expect('name', NAME); expect('symbol', SYMBOL);
  expect('curator', '0x0000000000000000000000000000000000000000', `${got.curator}  (none: the owner holds curator and allocator powers)`);
  expect('guardian', '0x0000000000000000000000000000000000000000', `${got.guardian}  (none)`);
  expect('fee', FEE, `${got.fee}  (15%)`); expect('feeRecipient', SAFE); expect('timelock', TIMELOCK, `${got.timelock}  (1 day)`);
  expect('supplyQueueLength', MARKETS.length); expect('withdrawQueueLength', MARKETS.length);
  for (const [i, m] of MARKETS.entries()) {
    const cfg = got[`config ${m.sym}`];
    const ok = cfg !== 'REVERT' && cfg[0] === m.cap && cfg[1] === true && cfg[2] === 0n;
    if (!ok) problems.push(`config ${m.sym} = ${cfg}`);
    if (String(got[`supplyQueue[${i}]`]).toLowerCase() !== m.id.toLowerCase()) problems.push(`supplyQueue[${i}] is not ${m.sym}`);
    const wq = (i + 4) % 8; // deep ones at 0..3, stocks at 4..7
    if (String(got[`withdrawQueue[${wq}]`]).toLowerCase() !== m.id.toLowerCase()) problems.push(`withdrawQueue[${wq}] is not ${m.sym}`);
    console.log(`  ${ok ? 'ok ' : 'BAD'} ${m.sym.padEnd(7)} cap ${usd(m.cap).padStart(12)}  enabled  supply #${i + 1}  withdraw #${wq + 1}`);
  }

  const c2 = first[1].calls;
  if (c2[2].status !== '0x1') problems.push(`deposit reverted ${c2[2].returnData}`);
  console.log(`\nA DEPOSIT OF ${usd(AMOUNT)} USDC:  ${c2[2].status === '0x1' ? 'ok' : 'REVERTED'}`);
  MARKETS.forEach((m, i) => {
    const pos = decodeFunctionResult({ abi: MB, functionName: 'position', data: c2[3 + i].returnData });
    if (i < 4 && pos[0] === 0n) problems.push(`${m.sym} got nothing from the deposit`);
    if (pos[0] > 0n) console.log(`  landed in ${m.sym}`);
  });
  const shares = decodeFunctionResult({ abi: V, functionName: 'balanceOf', data: first[2].calls[0].returnData });

  // Second pass now the share count is known: redeem everything 30 days later, then the Safe's fee.
  const second = await sim([
    { calls: txs.map((t, i) => ({ from: SAFE, to: t.to, data: t.data, gas: i === 0 ? CREATE_GAS : GAS })) },
    { calls: b2.slice(0, 3) },
    { blockOverrides: { time: hex(now + 30n * 86400n) }, calls: [
      ...MARKETS.slice(0, 4).map((m) => ({ from: DEP, to: MORPHO, data: encodeFunctionData({ abi: MB, functionName: 'position', args: [m.id, vault] }) })),
      { from: DEP, to: vault, data: encodeFunctionData({ abi: V, functionName: 'redeem', args: [shares / 5n, DEP, DEP] }), gas: GAS },
      ...MARKETS.slice(0, 4).map((m) => ({ from: DEP, to: MORPHO, data: encodeFunctionData({ abi: MB, functionName: 'position', args: [m.id, vault] }) })),
      { from: DEP, to: vault, data: encodeFunctionData({ abi: V, functionName: 'redeem', args: [shares - shares / 5n, DEP, DEP] }), gas: GAS },
      { from: DEP, to: USDC, data: encodeFunctionData({ abi: ERC20, functionName: 'balanceOf', args: [DEP] }) },
      { from: SAFE, to: vault, data: encodeFunctionData({ abi: V, functionName: 'balanceOf', args: [SAFE] }) },
    ] },
  ]);
  const c3x = second[2].calls;
  if (c3x[4].status !== '0x1') problems.push(`partial redeem reverted ${c3x[4].returnData}`);
  let stockTouched = 0;
  for (let i = 0; i < 4; i++) {
    const a = decodeFunctionResult({ abi: MB, functionName: 'position', data: c3x[i].returnData })[0];
    const b = decodeFunctionResult({ abi: MB, functionName: 'position', data: c3x[5 + i].returnData })[0];
    if (a !== b) { stockTouched++; problems.push(`a 10,000 USDC withdrawal pulled from ${MARKETS[i].sym}`); }
  }
  console.log(`
A 10,000 USDC PARTIAL WITHDRAWAL: ${c3x[4].status === '0x1' ? 'ok' : 'REVERTED'}, stock-market supply touched: ${stockTouched} of 4 (deep markets paid it)`);
  const c3 = c3x.slice(9);
  if (c3[0].status !== '0x1') problems.push(`redeem reverted ${c3[0].returnData}`);
  const out = decodeFunctionResult({ abi: ERC20, functionName: 'balanceOf', data: c3[1].returnData });
  const safeShares = decodeFunctionResult({ abi: V, functionName: 'balanceOf', data: c3[2].returnData });
  const third = await sim([
    { calls: txs.map((t, i) => ({ from: SAFE, to: t.to, data: t.data, gas: i === 0 ? CREATE_GAS : GAS })) },
    { calls: b2.slice(0, 3) },
    { blockOverrides: { time: hex(now + 30n * 86400n) }, calls: [
      { from: DEP, to: vault, data: encodeFunctionData({ abi: V, functionName: 'redeem', args: [shares, DEP, DEP] }), gas: GAS },
      { from: SAFE, to: USDC, data: encodeFunctionData({ abi: ERC20, functionName: 'balanceOf', args: [SAFE] }) },
      { from: SAFE, to: vault, data: encodeFunctionData({ abi: V, functionName: 'redeem', args: [safeShares, SAFE, SAFE] }), gas: GAS },
      { from: SAFE, to: USDC, data: encodeFunctionData({ abi: ERC20, functionName: 'balanceOf', args: [SAFE] }) },
    ] },
  ]);
  const c4 = third[2].calls;
  if (c4[2].status !== '0x1') problems.push(`Safe fee redeem reverted ${c4[2].returnData}`);
  const safeGot = decodeFunctionResult({ abi: ERC20, functionName: 'balanceOf', data: c4[3].returnData }) - decodeFunctionResult({ abi: ERC20, functionName: 'balanceOf', data: c4[1].returnData });
  if (out < AMOUNT) problems.push(`depositor got back ${out} < ${AMOUNT}`);
  if (safeGot === 0n) problems.push('Safe fee redeemed to nothing');
  const interest = out - AMOUNT;
  console.log(`\n30 DAYS LATER:\n  depositor redeemed all: ${usd(out)} USDC (+${usd(interest)})\n  Safe redeemed its fee shares: +${usd(safeGot)} USDC in the Safe`);
  console.log(`  fee share of gross interest: ${(Number(safeGot) / Number(interest + safeGot) * 100).toFixed(2)}%`);

  const bundle = {
    version: '1.0',
    chainId: '8453',
    createdAt: Date.now(),
    meta: {
      name: 'deploy-chipworks-usdc-vault',
      description: `MetaMorpho V1.1 "${NAME}" (${SYMBOL}) at ${vault}: owner+fee to Safe, 15% fee, 8 markets (4 stocks at 2,000 USDC first in supply, 4 deep at 5M first in withdraw), then 1-day timelock`,
      txBuilderVersion: '1.16.5',
      createdFromSafeAddress: SAFE,
      createdFromOwnerAddress: '',
    },
    transactions: txs.map((t) => ({ to: t.to, value: '0', data: t.data, contractMethod: null, contractInputsValues: null })),
  };
  const file = path.join(__dirname, '../../safecalls-morpho-vault.json');
  fs.writeFileSync(file, JSON.stringify(bundle, null, 2) + '\n');
  console.log(`\nSafe Transaction Builder file: ${file}`);
  console.log('\nraw calldata, in order:');
  txs.forEach((t, i) => console.log(`  ${i + 1}. to ${t.to}\n     ${t.data}`));
  console.log('\nproblems:', problems);
  if (problems.length) process.exit(1);
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
