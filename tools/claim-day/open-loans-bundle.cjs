// The Safe bundle that opens NounLoans, priced at the live $CHIP price and simulated
// end to end from the Safe before it is handed over.
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, encodeFunctionData, decodeFunctionResult, formatUnits } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const c = createPublicClient({ chain: base, transport: http(env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim()) });

const LOANS = '0x123Bc476594A80B0d99Ca6510e87E249b1C5EC5f';
const SAFE = '0xe1096B727499a3f70FaD8bc0267F5e69d01373C7';
const BASED = '0xBf57D0535E10E7033447174404b9bEd3D9eF4C88';
const LIL = '0xe3c5Ef27B80481518a2363406e354a9361415556';
const DARK = '0xd45E54B1A5e77d6E9469a4174d34f27D5D16270C';
const STATEVIEW = '0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71';
const POOL_ID = '0xbcdd8383e38069f626846b94e93ee4d2c00cadfcce4b9457b0b8b04289030345';
const ETH_USD = '0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70';
const BASED_FLOOR_USD = Number(process.env.BASED_FLOOR || 38);
const LTV = Number(process.env.LTV || 0.6);

const L = parseAbi([
  'function setMaxPrincipal(address collection, uint256 amount)',
  'function setFeeSplitter(address v)',
  'function setBorrowingPaused(bool paused)',
  'function maxPrincipal(address) view returns (uint256)',
  'function borrowingPaused() view returns (bool)',
  'function feeSplitter() view returns (address)',
]);
const SV = parseAbi(['function getSlot0(bytes32) view returns (uint160,int24,uint24,uint24)']);
const FEED = parseAbi(['function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)', 'function decimals() view returns (uint8)']);
const hex = (n) => '0x' + BigInt(n).toString(16);

(async () => {
  const [slot0, feed, fdec] = await Promise.all([
    c.readContract({ address: STATEVIEW, abi: SV, functionName: 'getSlot0', args: [POOL_ID] }),
    c.readContract({ address: ETH_USD, abi: FEED, functionName: 'latestRoundData' }),
    c.readContract({ address: ETH_USD, abi: FEED, functionName: 'decimals' }),
  ]);
  const ethUsd = Number(feed[1]) / 10 ** Number(fdec);
  const sq = Number(slot0[0]) / 2 ** 96;
  const chipUsd = ethUsd / (sq * sq);
  const capChip = Math.floor((BASED_FLOOR_USD * LTV) / chipUsd);
  const cap = BigInt(capChip) * 10n ** 18n;
  console.log(`$CHIP $${chipUsd.toExponential(4)}   Based floor $${BASED_FLOOR_USD} x ${LTV * 100}% = $${(BASED_FLOOR_USD * LTV).toFixed(2)}`);
  console.log(`cap: ${capChip.toLocaleString('en-US')} CHIP  (${cap})`);

  const txs = [
    { label: `setMaxPrincipal(Based, ${capChip.toLocaleString('en-US')} CHIP)`, to: LOANS, data: encodeFunctionData({ abi: L, functionName: 'setMaxPrincipal', args: [BASED, cap] }), method: 'setMaxPrincipal', inputs: { collection: BASED, amount: cap.toString() } },
    { label: 'setMaxPrincipal(Lil, 0) - Lil is lendable today and must not be', to: LOANS, data: encodeFunctionData({ abi: L, functionName: 'setMaxPrincipal', args: [LIL, 0n] }), method: 'setMaxPrincipal', inputs: { collection: LIL, amount: '0' } },
    /*
      DARK IS ZEROED TOO, AND THIS IS NOT TIDYING.

      Its cap is 35,000,000 CHIP, set when $CHIP was cheaper. At today's price that
      is $91 against an $80 floor - 114% LTV - and the only thing stopping anyone
      taking it is the ERC-721C validator that currently refuses the transfer. The
      day that collection's owner relaxes the policy, a loan worth more than its
      collateral becomes available with nobody deciding anything. Zero it now; set
      it deliberately if Dark is ever enabled.
    */
    { label: 'setMaxPrincipal(Dark, 0) - stale 114% LTV cap, live the moment its validator relaxes', to: LOANS, data: encodeFunctionData({ abi: L, functionName: 'setMaxPrincipal', args: [DARK, 0n] }), method: 'setMaxPrincipal', inputs: { collection: DARK, amount: '0' } },
    { label: 'setFeeSplitter(Safe) - loan fees straight to the multisig', to: LOANS, data: encodeFunctionData({ abi: L, functionName: 'setFeeSplitter', args: [SAFE] }), method: 'setFeeSplitter', inputs: { v: SAFE } },
    { label: 'setBorrowingPaused(false) - OPEN', to: LOANS, data: encodeFunctionData({ abi: L, functionName: 'setBorrowingPaused', args: [false] }), method: 'setBorrowingPaused', inputs: { paused: 'false' } },
  ];

  // Simulate the four, in order, AS THE SAFE, then read the result back in the same block.
  const reads = [
    { name: 'maxPrincipal(Based)', data: encodeFunctionData({ abi: L, functionName: 'maxPrincipal', args: [BASED] }) },
    { name: 'maxPrincipal(Lil)', data: encodeFunctionData({ abi: L, functionName: 'maxPrincipal', args: [LIL] }) },
    { name: 'maxPrincipal(Dark)', data: encodeFunctionData({ abi: L, functionName: 'maxPrincipal', args: [DARK] }) },
    { name: 'borrowingPaused()', data: encodeFunctionData({ abi: L, functionName: 'borrowingPaused' }) },
    { name: 'feeSplitter()', data: encodeFunctionData({ abi: L, functionName: 'feeSplitter' }) },
  ];
  const res = await c.request({ method: 'eth_simulateV1', params: [{ blockStateCalls: [{ calls: [
    ...txs.map((t) => ({ from: SAFE, to: t.to, data: t.data, gas: hex(500000) })),
    ...reads.map((r) => ({ from: SAFE, to: LOANS, data: r.data })),
  ] }], validation: false }, 'latest'] });
  const calls = res[0].calls;
  console.log('\nsimulated from the Safe:');
  txs.forEach((t, i) => console.log(`  ${calls[i].status === '0x1' ? 'OK  ' : 'FAIL'} ${t.label}`));
  const after = calls.slice(txs.length);
  const dec = (i, fn) => decodeFunctionResult({ abi: L, functionName: fn, data: after[i].returnData });
  console.log('\nstate afterwards:');
  console.log(`  maxPrincipal(Based) ${Number(formatUnits(dec(0, 'maxPrincipal'), 18)).toLocaleString('en-US')} CHIP`);
  console.log(`  maxPrincipal(Lil)   ${dec(1, 'maxPrincipal')}  (must be 0)`);
  console.log(`  maxPrincipal(Dark)  ${dec(2, 'maxPrincipal')}  (must be 0)`);
  console.log(`  borrowingPaused     ${dec(3, 'borrowingPaused')}  (must be false)`);
  console.log(`  feeSplitter         ${dec(4, 'feeSplitter')}`);
  const ok = txs.every((_, i) => calls[i].status === '0x1') && dec(1, 'maxPrincipal') === 0n && dec(2, 'maxPrincipal') === 0n && dec(3, 'borrowingPaused') === false && dec(4, 'feeSplitter').toLowerCase() === SAFE.toLowerCase();
  console.log(`\nALL FOUR SIMULATE AND LEAVE THE RIGHT STATE: ${ok}`);

  const out = path.join(__dirname, 'open-nounloans.safe.json');
  fs.writeFileSync(out, JSON.stringify({
    version: '1.0', chainId: '8453', createdAt: Date.now(),
    meta: { name: 'Open NounLoans (Based only)', description: `Based cap ${capChip.toLocaleString('en-US')} CHIP = 60% of a $${BASED_FLOOR_USD} floor at $CHIP $${chipUsd.toExponential(4)}; Lil zeroed; fees to the Safe; unpause` },
    transactions: txs.map((t) => ({ to: t.to, value: '0', data: t.data, contractMethod: null, contractInputsValues: null })),
  }, null, 2));
  console.log(`Safe Transaction Builder file: ${out}`);
  console.log('\nraw calldata, in order:');
  txs.forEach((t, i) => console.log(`  ${i + 1}. ${t.label}\n     to ${t.to}\n     data ${t.data}`));
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
