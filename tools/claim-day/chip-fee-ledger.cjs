// The $CHIP pool's LP-fee ledger at the Doppler/Bankr distributor, per beneficiary.
//
// The distributor (RehypeDopplerHookInitializer 0x9982…FDbB, verified; fee logic in its
// FeesManager.sol) is MasterChef-style: collectFees() pulls the pool's fees in and releases a
// beneficiary's share ONLY to msg.sender, if msg.sender is a beneficiary. A beneficiary's unpaid
// share is  (cumulatedFees - lastCumulatedFees[b]) * shares[b] / 1e18, plus its share of whatever
// is still uncollected in the pool. The only exits are collectFees() and updateBeneficiary(),
// and both must be called BY the beneficiary. The FeeSplitter cannot call anything.
//
// Reads only; nothing is signed or sent.   node tools/claim-day/chip-fee-ledger.cjs
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, keccak256, toHex, formatUnits, getAddress } = req('viem');
const fs = require('fs');
const path = require('path');

const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const RPC = env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim();
const KEY = env.match(/^BASESCAN_API_KEY=(.*)$/m)[1].trim();
const client = createPublicClient({ transport: http(RPC) });

const DIST = '0x9982538F41f2ae29ddb9d3D9307010052984FDbB';
const POOL_ID = '0xbcdd8383e38069f626846b94e93ee4d2c00cadfcce4b9457b0b8b04289030345';
const STATE_VIEW = '0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71';
const ETH_FEED = '0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70';
const KNOWN = {
  '0xb9b76e1835afe05e5a73065fe01a19b14869f8a3': 'FeeSplitter (ours, 80% Pot / 20% ops)',
  '0xe1096b727499a3f70fad8bc0267f5e69d01373c7': 'Safe (ours)',
  '0x6571e3412553fada40c3d96e61e7cfd20a0695b9': 'keeper (ours)',
};

const D = parseAbi([
  'function getCumulatedFees0(bytes32) view returns (uint256)',
  'function getCumulatedFees1(bytes32) view returns (uint256)',
  'function getLastCumulatedFees0(bytes32,address) view returns (uint256)',
  'function getLastCumulatedFees1(bytes32,address) view returns (uint256)',
  'function getShares(bytes32,address) view returns (uint256)',
  'function collectFees(bytes32) returns (uint128,uint128)',
]);
const RELEASE = keccak256(toHex('Release(bytes32,address,uint256,uint256)'));
const UPDATE = keccak256(toHex('UpdateBeneficiary(bytes32,address,address)'));
const COLLECT = keccak256(toHex('Collect(bytes32,uint256,uint256)'));

async function scan(topic0, topic1) {
  const out = [];
  for (let page = 1; ; page++) {
    // Blockscout: Etherscan-compatible and free for Base (Basescan's free tier refuses Base logs).
    const q = `https://base.blockscout.com/api?module=logs&action=getlogs&address=${DIST}&topic0=${topic0}`
      + (topic1 ? `&topic0_1_opr=and&topic1=${topic1}` : '') + `&fromBlock=0&toBlock=latest&page=${page}&offset=1000`;
    const j = await (await fetch(q)).json();
    if (!Array.isArray(j.result)) { if (/No records/i.test(j.message)) break; throw new Error(JSON.stringify(j).slice(0, 300)); }
    out.push(...j.result);
    if (j.result.length < 1000) break;
  }
  return out;
}
const word = (data, i) => BigInt('0x' + data.slice(2 + 64 * i, 2 + 64 * (i + 1)));

(async () => {
  const block = await client.getBlockNumber();
  const read = (fn, args) => client.readContract({ address: DIST, abi: D, functionName: fn, args, blockNumber: block });

  // Everyone who ever held or received shares, from the distributor's own events for this pool.
  const releases = await scan(RELEASE, POOL_ID);
  const collects = await scan(COLLECT, POOL_ID);
  const updates = (await scan(UPDATE)).filter((l) => l.data.slice(2, 66).toLowerCase() === POOL_ID.slice(2).toLowerCase());
  const who = new Set(Object.keys(KNOWN));
  for (const l of releases) who.add(getAddress('0x' + l.topics[2].slice(26)).toLowerCase());
  for (const l of updates) { who.add(getAddress('0x' + l.data.slice(90, 130)).toLowerCase()); who.add(getAddress('0x' + l.data.slice(154, 194)).toLowerCase()); }

  const [cum0, cum1] = await Promise.all([read('getCumulatedFees0', [POOL_ID]), read('getCumulatedFees1', [POOL_ID])]);
  // Still sitting in the pool, not yet collected: what a collectFees() now would add.
  const { result: [pend0, pend1] } = await client.simulateContract({ address: DIST, abi: D, functionName: 'collectFees', args: [POOL_ID], account: '0x000000000000000000000000000000000000dEaD', blockNumber: block });

  // Prices: ETH from Chainlink; $CHIP from the v4 slot0 (currency0 WETH, currency1 CHIP).
  const [, eth] = await client.readContract({ address: ETH_FEED, abi: parseAbi(['function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)']), functionName: 'latestRoundData', blockNumber: block });
  const [sqrtP] = await client.readContract({ address: STATE_VIEW, abi: parseAbi(['function getSlot0(bytes32) view returns (uint160,int24,uint24,uint24)']), functionName: 'getSlot0', args: [POOL_ID], blockNumber: block });
  const ethUsd = Number(eth) / 1e8;
  const chipPerWeth = (Number(sqrtP) / 2 ** 96) ** 2;
  const chipUsd = ethUsd / chipPerWeth;
  const usd = (w, c) => Number(formatUnits(w, 18)) * ethUsd + Number(formatUnits(c, 18)) * chipUsd;

  const released = {};
  for (const l of releases) {
    const b = getAddress('0x' + l.topics[2].slice(26)).toLowerCase();
    released[b] ??= [0n, 0n];
    released[b][0] += word(l.data, 0);
    released[b][1] += word(l.data, 1);
  }

  const rows = [];
  for (const b of who) {
    const [sh, l0, l1] = await Promise.all([read('getShares', [POOL_ID, b]), read('getLastCumulatedFees0', [POOL_ID, b]), read('getLastCumulatedFees1', [POOL_ID, b])]);
    const [r0, r1] = released[b] ?? [0n, 0n];
    if (sh === 0n && r0 === 0n && r1 === 0n) continue;
    const un0 = ((cum0 - l0) * sh) / 10n ** 18n + (pend0 * sh) / 10n ** 18n;
    const un1 = ((cum1 - l1) * sh) / 10n ** 18n + (pend1 * sh) / 10n ** 18n;
    rows.push({ b, name: KNOWN[b] ?? '(not ours)', sh, r0, r1, un0, un1 });
  }
  rows.sort((a, z) => (z.sh > a.sh ? 1 : -1));

  const f = (x) => Number(formatUnits(x, 18)).toFixed(6);
  const $ = (x) => '$' + x.toFixed(2);
  console.log(`block ${block}   ETH $${ethUsd.toFixed(2)}   CHIP $${chipUsd.toExponential(3)}`);
  console.log(`pool lifetime fees: collected into distributor ${f(cum0)} WETH + ${f(cum1)} CHIP; still in pool ${f(pend0)} WETH + ${f(pend1)} CHIP`);
  console.log(`  total ${f(cum0 + pend0)} WETH + ${f(cum1 + pend1)} CHIP  = ${$(usd(cum0 + pend0, cum1 + pend1))}`);
  console.log(`events: ${collects.length} Collect, ${releases.length} Release, ${updates.length} UpdateBeneficiary\n`);
  for (const r of rows) {
    console.log(`${r.b}  ${r.name}`);
    console.log(`  shares ${(Number(r.sh) / 1e16).toFixed(4)}%`);
    console.log(`  already received  ${f(r.r0)} WETH + ${f(r.r1)} CHIP  (${$(usd(r.r0, r.r1))})`);
    console.log(`  owed, unclaimed   ${f(r.un0)} WETH + ${f(r.un1)} CHIP  (${$(usd(r.un0, r.un1))})`);
    console.log(`  lifetime          ${$(usd(r.r0 + r.un0, r.r1 + r.un1))}`);
  }
  for (const u of updates) console.log(`UpdateBeneficiary tx ${u.transactionHash}: ${'0x' + u.data.slice(90, 130)} -> ${'0x' + u.data.slice(154, 194)}`);
})().catch((e) => { console.error(e); process.exit(1); });
