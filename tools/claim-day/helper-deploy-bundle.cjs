// The Safe bundle that DEPLOYS ChipBorrowHelper and LISTS the four stock markets, in one atomic
// Safe transaction - simulated from the Safe on the live node, then used by a real stock holder.
//
// Why the Safe deploys it (through the standard CREATE2 deployer 0x4e59...956C) rather than a key:
//   - no hot deployer key ever exists, and nothing needs an ownership transfer afterwards;
//   - the address is fixed before signing, so deploy + setListed x4 are one bundle;
//   - owner and fee recipient are constructor arguments, set to the Safe from block one.
//
// It also freezes what gets deployed. The init code is taken from forge's artifact, and the script
// refuses to write a bundle unless a standalone solc 0.8.24 build of the SAVED standard-JSON input
// (verify-json/ChipBorrowHelper.json) reproduces that init code byte for byte - so Basescan
// verification later cannot fail on line endings or a stray rebuild.
//
//   forge build && node helper-deploy-bundle.cjs
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { encodeFunctionData, decodeFunctionResult, encodeAbiParameters, parseAbi, getAddress, getContractAddress, concat, stringToHex, keccak256, formatUnits } = req('viem');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const ROOT = path.join(__dirname, '../..');
const env = fs.readFileSync(path.join(ROOT, '.env'), 'utf8');
const RPC = env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim();

const CREATE2_DEPLOYER = '0x4e59b44847b379578588920cA78FbF26c0B4956C';
const MORPHO = '0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb';
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const SAFE = '0xe1096B727499a3f70FaD8bc0267F5e69d01373C7';
const IRM = '0x46415998764C29aB2a25CbeA6254146D50D22687';
const SALT = stringToHex('chipworks-borrow-helper-1', { size: 32 });
const SOLC = path.join(process.env.APPDATA || '', 'svm/0.8.24/solc-0.8.24');
const MARKETS = [
  { sym: 'AAPLc', collateralToken: '0xb200000000000000000000C2e324d24d7eEcd1fb', oracle: '0xEcC5c9bf18CB2CfC94C2f7EFf8BDd5837A60AB0e', lltv: 625000000000000000n },
  { sym: 'GOOGLc', collateralToken: '0xb2000000000000000000002D0BA3164cc74f58B7', oracle: '0x24DC11055aa5b2C5692E4B77d7285c4f0fd9Cf99', lltv: 770000000000000000n },
  { sym: 'NVDAc', collateralToken: '0xb20000000000000000000078ee7ce2fE4908108C', oracle: '0x4F698C04d01d9CebCDd9494c189aBdD6C5453f84', lltv: 625000000000000000n },
  { sym: 'METAc', collateralToken: '0xb2000000000000000000008bC8786B856E61707C', oracle: '0x4752B27dFc1931eb9a5DFEFC7FBC9d0af9020dC7', lltv: 625000000000000000n },
].map((m) => ({ ...m, params: { loanToken: USDC, collateralToken: m.collateralToken, oracle: m.oracle, irm: IRM, lltv: m.lltv } }));

const hex = (n) => '0x' + BigInt(n).toString(16);
const rpc = async (method, params) => {
  const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(JSON.stringify(j.error));
  return j.result;
};
const sha256 = (buf) => require('crypto').createHash('sha256').update(buf).digest('hex');

(async () => {
  const problems = [];

  // ---- 1. freeze the bytecode, and prove the verification input reproduces it ----------------
  const art = JSON.parse(fs.readFileSync(path.join(ROOT, 'out/ChipBorrowHelper.sol/ChipBorrowHelper.json'), 'utf8'));
  const H = art.abi;
  const creation = art.bytecode.object;
  const stdInput = execFileSync('forge', ['verify-contract', '0x0000000000000000000000000000000000000001', 'src/morpho/ChipBorrowHelper.sol:ChipBorrowHelper', '--chain', '8453', '--show-standard-json-input'], { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  const solcOut = JSON.parse(execFileSync(SOLC, ['--standard-json'], { cwd: ROOT, input: stdInput, encoding: 'utf8', maxBuffer: 64e6 }));
  const errs = (solcOut.errors || []).filter((e) => e.severity === 'error');
  if (errs.length) throw new Error('solc: ' + errs.map((e) => e.formattedMessage).join('\n'));
  const solcCreation = '0x' + solcOut.contracts['src/morpho/ChipBorrowHelper.sol'].ChipBorrowHelper.evm.bytecode.object;
  const reproduces = solcCreation.toLowerCase() === creation.toLowerCase();
  if (!reproduces) problems.push('standalone solc build of the standard-JSON input does NOT reproduce the forge artifact');
  const srcSha = sha256(Buffer.from(JSON.parse(stdInput).sources['src/morpho/ChipBorrowHelper.sol'].content, 'utf8'));

  const args = encodeAbiParameters([{ type: 'address' }, { type: 'address' }, { type: 'address' }, { type: 'address' }], [MORPHO, USDC, SAFE, SAFE]);
  const initCode = concat([creation, args]);
  const helper = getContractAddress({ opcode: 'CREATE2', from: CREATE2_DEPLOYER, salt: SALT, bytecode: initCode });

  const block = BigInt(await rpc('eth_blockNumber', []));
  const now = BigInt((await rpc('eth_getBlockByNumber', [hex(block), false])).timestamp);
  if ((await rpc('eth_getCode', [helper, hex(block)])) !== '0x') problems.push(`${helper} already has code`);

  // ---- 2. the bundle -----------------------------------------------------------------------
  const txs = [
    { label: `CREATE2 deployer: ChipBorrowHelper(morpho=Morpho, loanToken=USDC, feeRecipient=Safe, owner=Safe), salt "chipworks-borrow-helper-1" -> ${helper}`, to: CREATE2_DEPLOYER, data: concat([SALT, initCode]) },
    ...MARKETS.map((m) => ({ label: `helper.setListed(${m.sym} @ ${Number(m.lltv) / 1e16}% LLTV, true)`, to: helper, data: encodeFunctionData({ abi: H, functionName: 'setListed', args: [m.params, true] }) })),
  ];

  const r = (fn, args = []) => ({ from: SAFE, to: helper, data: encodeFunctionData({ abi: H, functionName: fn, args }), fn });
  const reads = [r('owner'), r('pendingOwner'), r('MORPHO'), r('LOAN_TOKEN'), r('FEE_RECIPIENT'), r('FEE_BPS'), r('MAX_LLTV_USE'),
    ...MARKETS.map((m) => ({ ...r('isListed', [keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'address' }, { type: 'address' }, { type: 'address' }, { type: 'uint256' }], [USDC, m.collateralToken, m.oracle, IRM, m.lltv]))]), m }))];
  // a stranger cannot list
  const strangerList = { from: '0x000000000000000000000000000000000000bEEF', to: helper, data: txs[1].data, gas: hex(300000) };

  // ---- 3. and a real AAPL holder uses the helper the bundle deployed --------------------------
  const HOLDER = '0xcd2f7B2272f860A7a60e25ff6cdd0BdD0A9FCEFa';
  const aapl = MARKETS[0];
  const ERC20 = parseAbi(['function balanceOf(address) view returns (uint256)', 'function approve(address,uint256) returns (bool)', 'function transfer(address,uint256) returns (bool)']);
  const MB = parseAbi(['function setAuthorization(address,bool)', 'function isAuthorized(address,address) view returns (bool)', 'function position(bytes32,address) view returns (uint256,uint128,uint128)']);
  const bal = decodeFunctionResult({ abi: ERC20, functionName: 'balanceOf', data: await rpc('eth_call', [{ to: aapl.collateralToken, data: encodeFunctionData({ abi: ERC20, functionName: 'balanceOf', args: [HOLDER] }) }, hex(block)]) });
  const limit = decodeFunctionResult({ abi: H, functionName: 'borrowLimit', data: await rpc('eth_simulateV1', [{ blockStateCalls: [{ calls: [txs[0] && { from: SAFE, to: txs[0].to, data: txs[0].data, gas: hex(6_000_000) }, { from: SAFE, to: helper, data: encodeFunctionData({ abi: H, functionName: 'borrowLimit', args: [aapl.params, bal] }) }] }], validation: false }, hex(block)]).then((x) => x[0].calls[1].returnData) });
  const borrow = limit / 2n;
  const aappId = reads[7].data.slice(10, 74);
  const already = decodeFunctionResult({ abi: MB, functionName: 'isAuthorized', data: await rpc('eth_call', [{ to: MORPHO, data: encodeFunctionData({ abi: MB, functionName: 'isAuthorized', args: [HOLDER, helper] }) }, hex(block)]) });

  const res = await rpc('eth_simulateV1', [{ blockStateCalls: [
    { calls: [...txs.map((t, i) => ({ from: SAFE, to: t.to, data: t.data, gas: hex(i === 0 ? 6_000_000 : 300_000) })), ...reads.map(({ from, to, data }) => ({ from, to, data })), strangerList,
      { from: helper, to: helper, data: '0x' }, // placeholder keeps indexes simple
    ] },
    { calls: [
      ...(already ? [] : [{ from: HOLDER, to: MORPHO, data: encodeFunctionData({ abi: MB, functionName: 'setAuthorization', args: [helper, true] }), gas: hex(200000) }]),
      { from: HOLDER, to: aapl.collateralToken, data: encodeFunctionData({ abi: ERC20, functionName: 'approve', args: [helper, bal] }), gas: hex(200000) },
      { from: SAFE, to: USDC, data: encodeFunctionData({ abi: ERC20, functionName: 'balanceOf', args: [SAFE] }) },
      { from: HOLDER, to: helper, data: encodeFunctionData({ abi: H, functionName: 'supplyCollateralAndBorrow', args: [aapl.params, bal, borrow] }), gas: hex(1_000_000) },
      { from: SAFE, to: USDC, data: encodeFunctionData({ abi: ERC20, functionName: 'balanceOf', args: [SAFE] }) },
    ] },
    { blockOverrides: { time: hex(now + 3n * 86400n) }, calls: [
      { from: MORPHO, to: USDC, data: encodeFunctionData({ abi: ERC20, functionName: 'transfer', args: [HOLDER, borrow + 1_000_000n] }), gas: hex(200000) },
      { from: HOLDER, to: USDC, data: encodeFunctionData({ abi: ERC20, functionName: 'approve', args: [helper, 2n ** 256n - 1n] }), gas: hex(200000) },
      { from: HOLDER, to: helper, data: encodeFunctionData({ abi: H, functionName: 'repayAndWithdraw', args: [aapl.params, 2n ** 256n - 1n, 2n ** 256n - 1n] }), gas: hex(1_000_000) },
      { from: HOLDER, to: aapl.collateralToken, data: encodeFunctionData({ abi: ERC20, functionName: 'balanceOf', args: [HOLDER] }) },
    ] },
  ], validation: false }, hex(block)]);

  const c1 = res[0].calls;
  console.log(`block ${block}\nhelper will deploy at ${helper}\n`);
  console.log(`BYTECODE: forge artifact, ${(creation.length - 2) / 2} bytes of creation code`);
  console.log(`  source sha256 ${srcSha} (LF-independent check below)`);
  console.log(`  standalone solc 0.8.24 build of verify-json/ChipBorrowHelper.json reproduces it byte for byte: ${reproduces}\n`);
  console.log(`THE BUNDLE (${txs.length} calls, all from the Safe), simulated:`);
  txs.forEach((t, i) => { const ok = c1[i].status === '0x1'; if (!ok) problems.push(`call ${i + 1} reverted: ${t.label}`); console.log(`  ${i + 1}. ${ok ? 'OK  ' : 'FAIL'} ${t.label}`); });
  if (c1[0].status === '0x1' && getAddress('0x' + c1[0].returnData.slice(-40)) !== helper) problems.push('deployer returned a different address');

  const got = {};
  reads.forEach((rd, i) => { const c = c1[txs.length + i]; got[rd.m ? `isListed ${rd.m.sym}` : rd.fn] = c.status === '0x1' && c.returnData !== '0x' ? decodeFunctionResult({ abi: H, functionName: rd.fn, data: c.returnData }) : 'REVERT/EMPTY'; });
  const expect = (k, want) => { const ok = String(got[k]).toLowerCase() === String(want).toLowerCase(); if (!ok) problems.push(`${k} = ${got[k]}, expected ${want}`); console.log(`  ${ok ? 'ok ' : 'BAD'} ${k.padEnd(16)} ${got[k]}`); };
  console.log('\nSTATE AFTER THE BUNDLE:');
  expect('owner', SAFE); expect('pendingOwner', '0x0000000000000000000000000000000000000000'); expect('MORPHO', MORPHO); expect('LOAN_TOKEN', USDC);
  expect('FEE_RECIPIENT', SAFE); expect('FEE_BPS', 100n); expect('MAX_LLTV_USE', 900000000000000000n);
  for (const m of MARKETS) expect(`isListed ${m.sym}`, true);
  const sl = c1[txs.length + reads.length];
  if (sl.status === '0x1') problems.push('a stranger could call setListed');
  console.log(`  ${sl.status === '0x1' ? 'BAD' : 'ok '} stranger setListed reverts`);

  const c2 = res[1].calls, o = already ? 0 : 1;
  const borrowOk = c2[o + 2].status === '0x1';
  const safeGot = decodeFunctionResult({ abi: ERC20, functionName: 'balanceOf', data: c2[o + 3].returnData }) - decodeFunctionResult({ abi: ERC20, functionName: 'balanceOf', data: c2[o + 1].returnData });
  if (!borrowOk) problems.push('holder borrow through the deployed helper reverted');
  if (safeGot !== borrow / 100n) problems.push(`Safe got ${safeGot}, expected ${borrow / 100n}`);
  const c3 = res[2].calls;
  const back = decodeFunctionResult({ abi: ERC20, functionName: 'balanceOf', data: c3[3].returnData });
  if (c3[2].status !== '0x1' || back !== bal) problems.push('repay-all / withdraw-all did not return every AAPL unit');
  console.log(`\nA REAL AAPL HOLDER THROUGH THE BUNDLE-DEPLOYED HELPER:\n  borrow ${formatUnits(borrow, 6)} USDC: ${borrowOk ? 'ok' : 'REVERTED'}, Safe +${formatUnits(safeGot, 6)} (1%)\n  3 days later repay all + withdraw all: ${c3[2].status === '0x1' ? 'ok' : 'REVERTED'}, AAPL back ${back} of ${bal}`);

  if (!problems.length) {
    fs.writeFileSync(path.join(ROOT, 'verify-json/ChipBorrowHelper.json'), stdInput);
    const bundle = {
      version: '1.0', chainId: '8453', createdAt: Date.now(),
      meta: { name: 'deploy-chipworks-borrow-helper', description: `Deploy ChipBorrowHelper at ${helper} via CREATE2 (owner + fee recipient = Safe, loan token USDC) and list AAPL, GOOGL, NVDA, META`, txBuilderVersion: '1.16.5', createdFromSafeAddress: SAFE, createdFromOwnerAddress: '' },
      transactions: txs.map((t) => ({ to: t.to, value: '0', data: t.data, contractMethod: null, contractInputsValues: null })),
    };
    fs.writeFileSync(path.join(ROOT, 'safecalls-borrow-helper.json'), JSON.stringify(bundle, null, 2) + '\n');
    console.log(`\nwritten: safecalls-borrow-helper.json, verify-json/ChipBorrowHelper.json`);
    console.log(`constructor args (for verification): ${args.slice(2)}`);
  }
  console.log('\nproblems:', problems);
  if (problems.length) process.exit(1);
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
