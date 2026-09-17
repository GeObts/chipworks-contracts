// OPTIONAL follow-up to safecalls-morpho-vault.json: lower the vault's four deep-market caps from
// 5,000,000 to a conservative starting size. The stock markets stay at 2,000 each.
//
// Kept as a SEPARATE Safe transaction so the reviewed vault bundle (sha256 5435c567...) is untouched.
// Lowering a cap applies immediately (MetaMorpho submitCap: decreases skip the timelock); raising it
// later is submitCap -> wait the 1-day timelock -> acceptCap (anyone may call accept).
//
// Simulated on top of the vault bundle itself: block 1 runs safecalls-morpho-vault.json from the Safe,
// block 2 runs this, then reads every cap and how much the vault will accept in total.
//
//   DEEP_CAP_USDC=50000 node vault-caps-bundle.cjs
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { encodeFunctionData, decodeFunctionResult, parseAbi, formatUnits } = req('viem');
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '../..');
const env = fs.readFileSync(path.join(ROOT, '.env'), 'utf8');
const RPC = env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim();

const SAFE = '0xe1096B727499a3f70FaD8bc0267F5e69d01373C7';
const VAULT = '0x6B0EF5dd1cED6E26c384E4CcAf72f9dC0A1093d6';
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const IRM = '0x46415998764C29aB2a25CbeA6254146D50D22687';
const DEEP_CAP = BigInt(process.env.DEEP_CAP_USDC || 50000) * 10n ** 6n;
const DEEP = [
  { sym: 'cbBTC', collateralToken: '0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf', oracle: '0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9', lltv: 860000000000000000n, id: '0x9103c3b4e834476c9a62ea009ba2c884ee42e94e6e314a26f04d312434191836' },
  { sym: 'USDe', collateralToken: '0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34', oracle: '0xF4b17C79492d68775e22e8Dd0a2Bb22854A39A47', lltv: 915000000000000000n, id: '0x54cf9be57fdfa6457a660991907434ff9d295c465a603a50126ff647d50b7354' },
  { sym: 'WETH', collateralToken: '0x4200000000000000000000000000000000000006', oracle: '0xFEa2D58cEfCb9fcb597723c6bAE66fFE4193aFE4', lltv: 860000000000000000n, id: '0x8793cf302b8ffd655ab97bd1c695dbd967807e8367a65cb2f4edaf1380ba1bda' },
  { sym: 'cbXRP', collateralToken: '0xcb585250f852C6c6bf90434AB21A00f02833a4af', oracle: '0x031b2EFC8d70042Ac8d9f5c793c4149eC4b60fdE', lltv: 625000000000000000n, id: '0xd4a903dc6d949519060c7707f9604fdc9772c046e05c2e3a8fce0bd7196e4109' },
];
const STOCK_IDS = { AAPLc: '0xae1a30486234bf7e7ac166c7c03d9bc5f2cd8a39be2c48e73c665ac7148c3c28', GOOGLc: '0xa3913d896b7e9c0e0a84f1be27d376cf2065616101cb7c44674af8a154e684cc', NVDAc: '0xb4b42dd66cef25614b94510a910d54b2c148e7621d22b4271566724beda63d13', METAc: '0x44b343b5087c0bd34207cb5c199f12030777bf6b8c0a128438246f1212f37ca5' };
const V = parseAbi([
  'struct MarketParams { address loanToken; address collateralToken; address oracle; address irm; uint256 lltv; }',
  'function submitCap(MarketParams marketParams, uint256 newSupplyCap)',
  'function config(bytes32) view returns (uint184 cap, bool enabled, uint64 removableAt)',
  'function maxDeposit(address) view returns (uint256)',
]);
const hex = (n) => '0x' + BigInt(n).toString(16);
const rpc = async (method, params) => {
  const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(JSON.stringify(j.error));
  return j.result;
};
const usd = (x) => Number(formatUnits(x, 6)).toLocaleString('en-US');

(async () => {
  const problems = [];
  const vaultBundle = JSON.parse(fs.readFileSync(path.join(ROOT, 'safecalls-morpho-vault.json'), 'utf8'));
  const txs = DEEP.map((m) => ({ label: `vault.submitCap(${m.sym}, ${usd(DEEP_CAP)} USDC)  (was 5,000,000; a decrease applies immediately)`, to: VAULT,
    data: encodeFunctionData({ abi: V, functionName: 'submitCap', args: [{ loanToken: USDC, collateralToken: m.collateralToken, oracle: m.oracle, irm: IRM, lltv: m.lltv }, DEEP_CAP] }) }));
  const allIds = [...Object.entries(STOCK_IDS).map(([sym, id]) => ({ sym, id })), ...DEEP];
  const reads = [
    ...allIds.map((m) => ({ from: SAFE, to: VAULT, data: encodeFunctionData({ abi: V, functionName: 'config', args: [m.id] }), m })),
    { from: SAFE, to: VAULT, data: encodeFunctionData({ abi: V, functionName: 'maxDeposit', args: [SAFE] }) },
  ];
  const res = await rpc('eth_simulateV1', [{ blockStateCalls: [
    { calls: vaultBundle.transactions.map((t, i) => ({ from: SAFE, to: t.to, data: t.data, gas: hex(i === 0 ? 15_000_000 : 3_000_000) })) },
    { calls: [...txs.map((t) => ({ from: SAFE, to: t.to, data: t.data, gas: hex(500_000) })), ...reads.map(({ from, to, data }) => ({ from, to, data }))] },
  ], validation: false }, 'latest']);
  res[0].calls.forEach((c, i) => { if (c.status !== '0x1') problems.push(`vault bundle call ${i + 1} reverted`); });
  const c = res[1].calls;
  console.log('ON TOP OF THE REVIEWED VAULT BUNDLE, simulated from the Safe:');
  txs.forEach((t, i) => { const ok = c[i].status === '0x1'; if (!ok) problems.push(`${t.label} reverted`); console.log(`  ${i + 1}. ${ok ? 'OK  ' : 'FAIL'} ${t.label}`); });
  console.log('\nCAPS AFTERWARDS:');
  let total = 0n;
  allIds.forEach((m, i) => {
    const cfg = decodeFunctionResult({ abi: V, functionName: 'config', data: c[txs.length + i].returnData });
    const want = m.sym in STOCK_IDS ? 2_000n * 10n ** 6n : DEEP_CAP;
    if (cfg[0] !== want || !cfg[1]) problems.push(`${m.sym} cap ${cfg[0]} enabled ${cfg[1]}`);
    total += cfg[0];
    console.log(`  ${cfg[0] === want ? 'ok ' : 'BAD'} ${m.sym.padEnd(7)} ${usd(cfg[0]).padStart(9)} USDC`);
  });
  const maxDep = decodeFunctionResult({ abi: V, functionName: 'maxDeposit', data: c[c.length - 1].returnData });
  console.log(`\nthe most the vault will accept in total: ${usd(maxDep)} USDC (caps sum ${usd(total)})`);
  if (maxDep !== total) problems.push(`maxDeposit ${maxDep} != caps sum ${total}`);

  if (!problems.length) {
    const bundle = { version: '1.0', chainId: '8453', createdAt: Date.now(),
      meta: { name: 'vault-caps-conservative', description: `Lower the Chipworks USDC vault's cbBTC/USDe/WETH/cbXRP caps to ${usd(DEEP_CAP)} USDC each (stocks stay 2,000): total capacity ${usd(total)} USDC. Sign AFTER the vault bundle has executed.`, txBuilderVersion: '1.16.5', createdFromSafeAddress: SAFE, createdFromOwnerAddress: '' },
      transactions: txs.map((t) => ({ to: t.to, value: '0', data: t.data, contractMethod: null, contractInputsValues: null })) };
    fs.writeFileSync(path.join(ROOT, 'safecalls-vault-caps-conservative.json'), JSON.stringify(bundle, null, 2) + '\n');
    console.log('\nwritten: safecalls-vault-caps-conservative.json');
  }
  console.log('\nproblems:', problems);
  if (problems.length) process.exit(1);
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
