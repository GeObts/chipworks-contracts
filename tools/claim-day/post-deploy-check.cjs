// After the Safe executes the Morpho bundles: receipts, the Safe's own inner success event, and the live
// state of the vault and the borrow helper, compared against what the bundles were simulated to produce.
//   node post-deploy-check.cjs <txhash> [<txhash> ...]
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, keccak256, toHex, getAddress, formatUnits } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '../..');
const env = fs.readFileSync(path.join(ROOT, '.env'), 'utf8');
const c = createPublicClient({ chain: base, transport: http(env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim()) });

const SAFE = '0xe1096B727499a3f70FaD8bc0267F5e69d01373C7';
const VAULT = '0x6B0EF5dd1cED6E26c384E4CcAf72f9dC0A1093d6';
const HELPER = '0x36C7f9Ed1ffF7FD6305874837b257C3Bfa8FDff6';
const MORPHO = '0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb';
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const FACTORY = '0xFf62A7c278C62eD665133147129245053Bbf5918';
const ZERO = '0x0000000000000000000000000000000000000000';
// Safe v1.3+/1.4 emit ExecutionSuccess(bytes32 txHash, uint256 payment) / ExecutionFailure(...)
const SUCCESS = keccak256(toHex('ExecutionSuccess(bytes32,uint256)'));
const FAILURE = keccak256(toHex('ExecutionFailure(bytes32,uint256)'));
const M = {
  AAPLc: '0xae1a30486234bf7e7ac166c7c03d9bc5f2cd8a39be2c48e73c665ac7148c3c28',
  GOOGLc: '0xa3913d896b7e9c0e0a84f1be27d376cf2065616101cb7c44674af8a154e684cc',
  NVDAc: '0xb4b42dd66cef25614b94510a910d54b2c148e7621d22b4271566724beda63d13',
  METAc: '0x44b343b5087c0bd34207cb5c199f12030777bf6b8c0a128438246f1212f37ca5',
  cbBTC: '0x9103c3b4e834476c9a62ea009ba2c884ee42e94e6e314a26f04d312434191836',
  USDe: '0x54cf9be57fdfa6457a660991907434ff9d295c465a603a50126ff647d50b7354',
  WETH: '0x8793cf302b8ffd655ab97bd1c695dbd967807e8367a65cb2f4edaf1380ba1bda',
  cbXRP: '0xd4a903dc6d949519060c7707f9604fdc9772c046e05c2e3a8fce0bd7196e4109',
};
const STOCKS = ['AAPLc', 'GOOGLc', 'NVDAc', 'METAc'];
const DEEPS = ['cbBTC', 'USDe', 'WETH', 'cbXRP'];
const V = parseAbi([
  'function owner() view returns (address)', 'function curator() view returns (address)', 'function guardian() view returns (address)',
  'function fee() view returns (uint96)', 'function feeRecipient() view returns (address)', 'function timelock() view returns (uint256)',
  'function asset() view returns (address)', 'function name() view returns (string)', 'function symbol() view returns (string)',
  'function config(bytes32) view returns (uint184 cap, bool enabled, uint64 removableAt)',
  'function pendingCap(bytes32) view returns (uint192 value, uint64 validAt)',
  'function supplyQueueLength() view returns (uint256)', 'function supplyQueue(uint256) view returns (bytes32)',
  'function withdrawQueueLength() view returns (uint256)', 'function withdrawQueue(uint256) view returns (bytes32)',
  'function totalAssets() view returns (uint256)',
]);
const art = JSON.parse(fs.readFileSync(path.join(ROOT, 'out/ChipBorrowHelper.sol/ChipBorrowHelper.json'), 'utf8'));
const H = art.abi;
const problems = [];
const check = (label, got, want) => {
  const ok = String(got).toLowerCase() === String(want).toLowerCase();
  if (!ok) problems.push(`${label}: got ${got}, want ${want}`);
  console.log(`  ${ok ? 'ok ' : 'BAD'} ${label.padEnd(30)} ${got}`);
};
const nameOf = (id) => Object.keys(M).find((k) => M[k] === String(id).toLowerCase()) || id;

(async () => {
  console.log('RECEIPTS');
  for (const h of process.argv.slice(2)) {
    const r = await c.getTransactionReceipt({ hash: h });
    const safeLogs = r.logs.filter((l) => getAddress(l.address) === getAddress(SAFE));
    const inner = safeLogs.some((l) => l.topics[0] === SUCCESS) ? 'ExecutionSuccess' : safeLogs.some((l) => l.topics[0] === FAILURE) ? 'ExecutionFailure' : 'no Safe event';
    const touched = new Set(r.logs.map((l) => getAddress(l.address)));
    const what = touched.has(getAddress(HELPER)) ? 'helper deploy + listings' : touched.has(getAddress(FACTORY)) ? 'vault create + configure' : touched.has(getAddress(VAULT)) ? 'vault caps change' : 'UNRECOGNISED';
    if (r.status !== 'success' || inner !== 'ExecutionSuccess') problems.push(`${h}: receipt ${r.status}, ${inner}`);
    console.log(`  ${h}\n    block ${r.blockNumber}  receipt=${r.status}  Safe=${inner}  logs=${r.logs.length}  -> ${what}`);
  }

  console.log(`\nVAULT ${VAULT}`);
  const rv = (fn, args = []) => c.readContract({ address: VAULT, abi: V, functionName: fn, args });
  check('has code', ((await c.getCode({ address: VAULT })) || '0x').length > 2, true);
  check("Morpho factory's isMetaMorpho", await c.readContract({ address: FACTORY, abi: parseAbi(['function isMetaMorpho(address) view returns (bool)']), functionName: 'isMetaMorpho', args: [VAULT] }), true);
  check('owner', await rv('owner'), SAFE);
  check('curator', await rv('curator'), ZERO);
  check('guardian', await rv('guardian'), ZERO);
  check('asset', await rv('asset'), USDC);
  check('name', await rv('name'), 'Chipworks USDC');
  check('symbol', await rv('symbol'), 'cwUSDC');
  check('fee', await rv('fee'), 150000000000000000n);
  check('feeRecipient', await rv('feeRecipient'), SAFE);
  check('timelock', await rv('timelock'), 86400n);
  const deepCap = (await rv('config', [M.cbBTC]))[0];
  const conservative = deepCap === 50_000n * 10n ** 6n;
  for (const sym of [...STOCKS, ...DEEPS]) {
    const [cap, enabled, removableAt] = await rv('config', [M[sym]]);
    const want = STOCKS.includes(sym) ? 2_000n : conservative ? 50_000n : 5_000_000n;
    check(`cap ${sym}`, `${formatUnits(cap, 6)} enabled=${enabled} removable=${removableAt}`, `${want} enabled=true removable=0`);
    const [, validAt] = await rv('pendingCap', [M[sym]]);
    if (validAt !== 0n) problems.push(`${sym} has a pending cap change`);
  }
  check('supplyQueueLength', await rv('supplyQueueLength'), 8n);
  check('withdrawQueueLength', await rv('withdrawQueueLength'), 8n);
  const sq = [], wq = [];
  for (let i = 0n; i < 8n; i++) { sq.push(nameOf(await rv('supplyQueue', [i]))); wq.push(nameOf(await rv('withdrawQueue', [i]))); }
  check('supply queue (stocks first)', sq.join(','), [...STOCKS, ...DEEPS].join(','));
  check('withdraw queue (deep first)', wq.join(','), [...DEEPS, ...STOCKS].join(','));
  console.log(`  deep-market caps: ${conservative ? '50,000 each (conservative bundle executed), vault max 208,000 USDC' : '5,000,000 each (conservative bundle NOT executed)'}`);
  console.log(`  totalAssets: ${formatUnits(await rv('totalAssets'), 6)} USDC`);

  console.log(`\nBORROW HELPER ${HELPER}`);
  const code = (await c.getCode({ address: HELPER })) || '0x';
  let a = art.deployedBytecode.object.slice(2), b = code.slice(2);
  for (const refs of Object.values(art.deployedBytecode.immutableReferences || {})) {
    for (const { start, length } of refs) {
      const z = '0'.repeat(length * 2);
      a = a.slice(0, start * 2) + z + a.slice((start + length) * 2);
      b = b.slice(0, start * 2) + z + b.slice((start + length) * 2);
    }
  }
  check('runtime code == audited build', a.length > 0 && a === b, true);
  const rh = (fn, args = []) => c.readContract({ address: HELPER, abi: H, functionName: fn, args });
  check('owner', await rh('owner'), SAFE);
  check('pendingOwner', await rh('pendingOwner'), ZERO);
  check('MORPHO', await rh('MORPHO'), MORPHO);
  check('LOAN_TOKEN', await rh('LOAN_TOKEN'), USDC);
  check('FEE_RECIPIENT', await rh('FEE_RECIPIENT'), SAFE);
  check('FEE_BPS', await rh('FEE_BPS'), 100n);
  check('MAX_LLTV_USE', await rh('MAX_LLTV_USE'), 900000000000000000n);
  for (const s of STOCKS) check(`isListed ${s}`, await rh('isListed', [M[s]]), true);
  for (const s of DEEPS) check(`isListed ${s} (not offered)`, await rh('isListed', [M[s]]), false);

  console.log('\nproblems:', problems);
  if (problems.length) process.exit(1);
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
