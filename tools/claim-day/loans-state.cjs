// Everything that decides whether NounLoans can be opened safely, read live.
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, formatUnits, getAddress } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const c = createPublicClient({ chain: base, transport: http(env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim()) });

const LOANS = '0x123Bc476594A80B0d99Ca6510e87E249b1C5EC5f';
const CHIP = '0x75Af968d2e58749FDA1b42C58186B76f5E511bA3';
const COLLECTIONS = {
  Based: '0xBf57D0535E10E7033447174404b9bEd3D9eF4C88',
  Dark: '0xd45E54B1A5e77d6E9469a4174d34f27D5D16270C',
  Lil: '0xe3c5Ef27B80481518a2363406e354a9361415556',
  Chiplets: '0xC7c114191aa3b2225F9bb053Bc55b3d6F145Bd33',
};
const NAMES = { '0xe1096B727499a3f70FaD8bc0267F5e69d01373C7': 'Safe', '0xb9b76e1835afE05e5A73065FE01A19B14869F8A3': 'FeeSplitter', '0x7Bc1C03e843C37845d89B54667382b4577Ead5C0': 'ChipBurner', '0x762984092Cb9404982835551970C73b5838d5411': 'ChipActivationV2' };
const nm = (a) => NAMES[getAddress(a)] || a;
const read = (sig, args = []) => c.readContract({ address: LOANS, abi: parseAbi([`function ${sig}`]), functionName: sig.match(/^(\w+)/)[1], args }).catch((e) => `ERR ${e.shortMessage}`);

(async () => {
  const chipPx = 1 / 334000; // ~$1 buys ~334k CHIP, from the live pool quote earlier
  console.log('--- wiring / state ---');
  for (const s of ['owner() view returns (address)', 'borrowingPaused() view returns (bool)', 'feeSplitter() view returns (address)', 'treasury() view returns (address)',
    'poolBalance() view returns (uint256)', 'totalBorrowed() view returns (uint256)', 'totalFees() view returns (uint256)', 'openLoanCount() view returns (uint256)',
    'originationFeeBps() view returns (uint32)', 'lateFeeBps() view returns (uint32)', 'activationSource() view returns (address)']) {
    const v = await read(s);
    const name = s.match(/^(\w+)/)[1];
    const shown = typeof v === 'bigint' ? (name.includes('Balance') || name.includes('Borrowed') || name.includes('Fees') ? `${Number(formatUnits(v, 18)).toLocaleString('en-US', { maximumFractionDigits: 0 })} CHIP` : v.toString()) : typeof v === 'string' && v.startsWith('0x') && v.length === 42 ? nm(v) : String(v);
    console.log(`  ${name.padEnd(20)} ${shown}`);
  }

  console.log('\n--- caps vs collateral value (the parity check) ---');
  const floors = { Based: 30, Dark: 160, Lil: 12, Chiplets: null }; // floors the keeper uses
  for (const [label, col] of Object.entries(COLLECTIONS)) {
    const max = await read('maxPrincipal(address) view returns (uint256)', [col]);
    if (typeof max !== 'bigint') { console.log(`  ${label}: ${max}`); continue; }
    const usd = Number(formatUnits(max, 18)) * chipPx;
    const floor = floors[label];
    console.log(`  ${label.padEnd(9)} maxPrincipal ${Number(formatUnits(max, 18)).toLocaleString('en-US', { maximumFractionDigits: 0 }).padStart(12)} CHIP = $${usd.toFixed(2).padStart(8)}  floor $${floor ?? '?'}  LTV ${floor ? ((usd / floor) * 100).toFixed(1) + '%' : '-'}  -> 60% cap would be ${floor ? Math.round((floor * 0.6) / chipPx).toLocaleString('en-US') + ' CHIP' : '-'}`);
  }

  console.log('\n--- terms ---');
  for (let i = 0; i < 5; i++) {
    const t = await read('terms(uint256) view returns (uint64 duration, uint32 aprBps, uint32 ltvBps)', [BigInt(i)]);
    if (typeof t === 'string') { console.log(`  term ${i}: ${t}`); break; }
    console.log(`  term ${i}: ${JSON.stringify(t, (k, v) => (typeof v === 'bigint' ? v.toString() : v))}`);
  }
  const bal = await c.readContract({ address: CHIP, abi: parseAbi(['function balanceOf(address) view returns (uint256)']), functionName: 'balanceOf', args: [LOANS] });
  console.log(`\nCHIP actually held by NounLoans: ${Number(formatUnits(bal, 18)).toLocaleString('en-US', { maximumFractionDigits: 0 })}`);
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
