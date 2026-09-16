// Which MetaMorpho factory is real on Base, how many vaults exist, and what fee a curator takes.
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, parseAbiItem, formatUnits, getAddress } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const c = createPublicClient({ chain: base, transport: http(env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim()) });
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const FACTORIES = ['0xFf62A7c278C62eD665133147129245053Bbf5918', '0xA9c3D3a366466Fa809d1Ae982Fb2c46E5fC41101'];
const V = parseAbi([
  'function asset() view returns (address)', 'function fee() view returns (uint96)', 'function feeRecipient() view returns (address)',
  'function totalAssets() view returns (uint256)', 'function name() view returns (string)', 'function curator() view returns (address)', 'function owner() view returns (address)',
  'function timelock() view returns (uint256)',
]);

(async () => {
  const latest = await c.getBlockNumber();
  for (const f of FACTORIES) {
    for (const ev of [
      parseAbiItem('event CreateMetaMorpho(address indexed metaMorpho, address indexed caller, address initialOwner, uint256 initialTimelock, address indexed asset, string name, string symbol, bytes32 salt)'),
    ]) {
      let logs = [];
      try { logs = await c.getLogs({ address: f, event: ev, fromBlock: 0n, toBlock: latest }); } catch (e) { console.log(`${f}: getLogs failed ${e.shortMessage}`); continue; }
      console.log(`\nfactory ${f}: ${logs.length} vaults created`);
      const usdcVaults = logs.filter((l) => getAddress(l.args.asset) === getAddress(USDC));
      console.log(`  USDC vaults: ${usdcVaults.length}`);
      const rows = [];
      for (const l of usdcVaults) {
        const v = l.args.metaMorpho;
        const [ta, fee, rec, name, tl] = await Promise.all([
          c.readContract({ address: v, abi: V, functionName: 'totalAssets' }).catch(() => 0n),
          c.readContract({ address: v, abi: V, functionName: 'fee' }).catch(() => null),
          c.readContract({ address: v, abi: V, functionName: 'feeRecipient' }).catch(() => null),
          c.readContract({ address: v, abi: V, functionName: 'name' }).catch(() => '?'),
          c.readContract({ address: v, abi: V, functionName: 'timelock' }).catch(() => null),
        ]);
        rows.push({ v, name, ta, fee, rec, tl });
      }
      rows.sort((a, b) => (b.ta > a.ta ? 1 : -1));
      for (const r of rows.slice(0, 8)) {
        console.log(`   ${r.name.slice(0, 34).padEnd(34)} assets ${Number(formatUnits(r.ta, 6)).toLocaleString('en-US', { maximumFractionDigits: 0 }).padStart(13)} USDC  fee ${r.fee === null ? '?' : (Number(r.fee) / 1e16).toFixed(1) + '%'}  timelock ${r.tl ? Number(r.tl) / 3600 + 'h' : '?'}`);
      }
    }
  }
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
