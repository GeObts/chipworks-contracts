// Decode transactions: target, function, status, gas, and every ERC-20 Transfer / Approval in the receipt.
// Usage: node decode-txs.cjs <hash> [hash...]
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, parseEventLogs, formatUnits, keccak256, toHex, getAddress, decodeFunctionData } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const c = createPublicClient({ chain: base, transport: http(env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim()) });

const NAMES = {
  '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913': 'USDC', '0x75Af968d2e58749FDA1b42C58186B76f5E511bA3': 'CHIP', '0x4200000000000000000000000000000000000006': 'WETH',
  '0x000000000022D473030F116dDEE9F6B43aC78BA3': 'Permit2', '0x6fF5693b99212Da76ad316178A184AB56D299b43': 'UniversalRouter', '0x498581fF718922c3f8e6A244956aF099B2652b2b': 'v4 PoolManager',
  '0xd0b53D9277642d899DF5C87A3966A349A798F224': 'USDC/WETH v3 pool', '0xcA11bde05977b3631167028862bE2a173976CA11': 'Multicall3', '0x9bD35c70a80F132d087719305E37A888204d4c80': 'ChipClaims',
};
const nm = (a) => NAMES[getAddress(a)] || a;
const DEC = { USDC: 6, CHIP: 18, WETH: 18 };
const ABI = parseAbi([
  'function approve(address spender, uint256 amount)',
  'function approve(address token, address spender, uint160 amount, uint48 expiration)',
  'function execute(bytes commands, bytes[] inputs, uint256 deadline)',
  'event Transfer(address indexed from, address indexed to, uint256 value)',
  'event Approval(address indexed owner, address indexed spender, uint256 value)',
  'event Approval(address indexed owner, address indexed token, address indexed spender, uint160 amount, uint48 expiration)',
]);
const fmt = (token, v) => { const s = nm(token); return DEC[s] !== undefined ? `${formatUnits(v, DEC[s])} ${s}` : `${v} of ${s}`; };

(async () => {
  for (const hash of process.argv.slice(2)) {
    const [tx, r] = await Promise.all([c.getTransaction({ hash }), c.getTransactionReceipt({ hash })]);
    const blk = await c.getBlock({ blockNumber: r.blockNumber });
    let fn = tx.input.slice(0, 10), args = '';
    try {
      const d = decodeFunctionData({ abi: ABI, data: tx.input });
      fn = d.functionName;
      args = d.args.map((a) => (typeof a === 'string' && a.length === 42 ? nm(a) : typeof a === 'bigint' ? (a > 10n ** 40n ? 'MAX' : a.toString()) : Array.isArray(a) ? `[${a.length}]` : String(a).slice(0, 20))).join(', ');
    } catch {}
    console.log(`\n${hash}\n  ${new Date(Number(blk.timestamp) * 1000).toISOString()}  from ${tx.from}  nonce ${tx.nonce}\n  to ${nm(tx.to)}  ${fn}(${args})  status ${r.status}  gas ${r.gasUsed}`);
    const transfers = parseEventLogs({ abi: ABI, eventName: 'Transfer', logs: r.logs, strict: false });
    for (const t of transfers) console.log(`  Transfer ${fmt(t.address, t.args.value)}  ${nm(t.args.from)} -> ${nm(t.args.to)}`);
    const approvals = parseEventLogs({ abi: ABI, eventName: 'Approval', logs: r.logs, strict: false });
    for (const a of approvals) console.log(`  Approval on ${nm(a.address)}: ${JSON.stringify(a.args, (k, v) => (typeof v === 'bigint' ? (v > 10n ** 40n ? 'MAX' : v.toString()) : typeof v === 'string' && v.length === 42 ? nm(v) : v))}`);
  }
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
