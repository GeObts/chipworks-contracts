// ChipBorrowHelper against the REAL stock markets, via eth_simulateV1 on the live Base node.
//
// The forge suite (test/fork/ChipBorrowHelper.t.sol) proves every rule on cbBTC, because B20
// stocks are node precompiles that cannot execute in a forge fork. This proves the part only a
// real node can: that a real holder of each whitelisted stock can post it through the helper
// (i.e. the B20 transfer policy lets the helper hold it for one call), borrow against the
// market's live oracle, pay the Safe 1%, and after a week repay and get every unit back.
//
// Nothing is signed or sent. Run `forge build` first: bytecode is read from out/.
//
//   node borrow-helper-sim.cjs
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { encodeFunctionData, decodeFunctionResult, decodeErrorResult, encodeDeployData, parseAbi, getAddress, getContractAddress, formatUnits, keccak256, encodeAbiParameters } = req('viem');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const RPC = env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim();
const art = JSON.parse(fs.readFileSync(path.join(__dirname, '../../out/ChipBorrowHelper.sol/ChipBorrowHelper.json'), 'utf8'));
const H = art.abi;
const S = JSON.parse(fs.readFileSync(path.join(__dirname, 'sweep.out.json'), 'utf8').replace(/^\uFEFF/, ''));
const W = JSON.parse(fs.readFileSync(path.join(__dirname, 'vault-whitelist.json'), 'utf8'));

const MORPHO = '0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb';
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const SAFE = '0xe1096B727499a3f70FaD8bc0267F5e69d01373C7';
const CLAIMS = '0x9bD35c70a80F132d087719305E37A888204d4c80';
const DEPLOYER = '0x00000000000000000000000000000000C41b0001';
const STOCK_IDS = { // the four whitelisted stock markets (the vault's), by id
  AAPLc: '0xae1a30486234bf7e7ac166c7c03d9bc5f2cd8a39be2c48e73c665ac7148c3c28',
  GOOGLc: '0xa3913d896b7e9c0e0a84f1be27d376cf2065616101cb7c44674af8a154e684cc',
  NVDAc: '0xb4b42dd66cef25614b94510a910d54b2c148e7621d22b4271566724beda63d13',
  METAc: '0x44b343b5087c0bd34207cb5c199f12030777bf6b8c0a128438246f1212f37ca5',
};
const ERC20 = parseAbi(['function balanceOf(address) view returns (uint256)', 'function approve(address,uint256) returns (bool)', 'function transfer(address,uint256) returns (bool)']);
const MB = parseAbi([
  'function setAuthorization(address,bool)',
  'function position(bytes32,address) view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral)',
  'function market(bytes32) view returns (uint128,uint128,uint128,uint128,uint128,uint128)',
]);
const ORACLE = parseAbi(['function price() view returns (uint256)']);
const MAX = 2n ** 256n - 1n;
const GAS = '0x1c9c380';
const hex = (n) => '0x' + BigInt(n).toString(16);

const rpc = async (method, params) => {
  const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(JSON.stringify(j.error));
  return j.result;
};
const read = async (to, abi, functionName, args = []) =>
  decodeFunctionResult({ abi, functionName, data: await rpc('eth_call', [{ to, data: encodeFunctionData({ abi, functionName, args }) }, 'latest']) });
const errName = (data) => {
  if (!data || data === '0x') return 'revert (no data)';
  try { const e = decodeErrorResult({ abi: H, data }); return `${e.errorName}(${(e.args || []).map(String).join(',')})`; } catch { return `raw ${data.slice(0, 74)}`; }
};

(async () => {
  const block = BigInt(await rpc('eth_blockNumber', []));
  const now = BigInt((await rpc('eth_getBlockByNumber', [hex(block), false])).timestamp);
  const helper = getContractAddress({ from: DEPLOYER, nonce: 0n });
  const deployData = encodeDeployData({ abi: H, bytecode: art.bytecode.object, args: [MORPHO, USDC, SAFE, SAFE] });
  const owners = [...new Set(S.positions.map((p) => getAddress(p.owner)))];
  const problems = [];

  const plans = [];
  for (const [sym, id] of Object.entries(STOCK_IDS)) {
    const w = W.find((x) => x.id === id);
    const mp = { ...w.marketParams, lltv: BigInt(w.marketParams.lltv) };
    const stock = getAddress(mp.collateralToken);
    // Largest EOA holder among everyone the claims ledger has paid; ChipClaims itself as a fallback.
    let best = null;
    for (const o of owners) {
      const bal = await read(stock, ERC20, 'balanceOf', [o]).catch(() => 0n);
      if (bal > 0n && (!best || bal > best.bal) && (await rpc('eth_getCode', [o, 'latest'])) === '0x') best = { who: o, bal };
    }
    if (!best) best = { who: CLAIMS, bal: await read(stock, ERC20, 'balanceOf', [CLAIMS]) };
    if (best.bal === 0n) { problems.push(`${sym}: no holder found`); continue; }
    const price = await read(mp.oracle, ORACLE, 'price');
    const m = await read(MORPHO, MB, 'market', [id]);
    const free = m[0] - m[2];
    const limit = (((best.bal * price) / 10n ** 36n) * mp.lltv / 10n ** 18n) * 9n / 10n;
    let borrow = limit / 2n < free / 2n ? limit / 2n : free / 2n;
    plans.push({ sym, id, mp, stock, holder: best.who, bal: best.bal, limit, free, borrow });
  }

  // Block 1 (now): deploy, list, then per stock: authorize, approve, borrow.
  // Block 2 (+7 days): per stock: fund interest, approve USDC, repay all + withdraw all.
  const b1 = [{ from: DEPLOYER, data: deployData, gas: GAS }];
  for (const pl of plans) b1.push({ from: SAFE, to: helper, data: encodeFunctionData({ abi: H, functionName: 'setListed', args: [pl.mp, true] }), gas: GAS });
  const idx = {};
  const authorized = new Set(); // Morpho reverts "already set" on a repeat, and one wallet can hold two stocks
  for (const pl of plans) {
    idx[pl.sym] = { safeBefore: b1.length };
    b1.push({ from: SAFE, to: USDC, data: encodeFunctionData({ abi: ERC20, functionName: 'balanceOf', args: [SAFE] }) });
    b1.push({ from: pl.holder, to: USDC, data: encodeFunctionData({ abi: ERC20, functionName: 'balanceOf', args: [pl.holder] }) });
    // a wallet already authorized earlier in this block re-reads isAuthorized instead (same slot count)
    b1.push(authorized.has(pl.holder)
      ? { from: pl.holder, to: MORPHO, data: encodeFunctionData({ abi: parseAbi(['function isAuthorized(address,address) view returns (bool)']), functionName: 'isAuthorized', args: [pl.holder, helper] }) }
      : { from: pl.holder, to: MORPHO, data: encodeFunctionData({ abi: MB, functionName: 'setAuthorization', args: [helper, true] }), gas: GAS });
    authorized.add(pl.holder);
    b1.push({ from: pl.holder, to: pl.stock, data: encodeFunctionData({ abi: ERC20, functionName: 'approve', args: [helper, pl.bal] }), gas: GAS });
    idx[pl.sym].borrow = b1.length;
    b1.push({ from: pl.holder, to: helper, data: encodeFunctionData({ abi: H, functionName: 'supplyCollateralAndBorrow', args: [pl.mp, pl.bal, pl.borrow] }), gas: GAS });
    idx[pl.sym].after = b1.length;
    b1.push({ from: SAFE, to: USDC, data: encodeFunctionData({ abi: ERC20, functionName: 'balanceOf', args: [SAFE] }) });
    b1.push({ from: pl.holder, to: USDC, data: encodeFunctionData({ abi: ERC20, functionName: 'balanceOf', args: [pl.holder] }) });
    b1.push({ from: pl.holder, to: MORPHO, data: encodeFunctionData({ abi: MB, functionName: 'position', args: [pl.id, pl.holder] }) });
    b1.push({ from: pl.holder, to: pl.stock, data: encodeFunctionData({ abi: ERC20, functionName: 'balanceOf', args: [pl.holder] }) });
    b1.push({ from: pl.holder, to: pl.stock, data: encodeFunctionData({ abi: ERC20, functionName: 'balanceOf', args: [helper] }) });
  }
  const b2 = [];
  for (const pl of plans) {
    idx[pl.sym].b2 = b2.length;
    b2.push({ from: MORPHO, to: USDC, data: encodeFunctionData({ abi: ERC20, functionName: 'transfer', args: [pl.holder, pl.borrow + 10n ** 6n] }), gas: GAS });
    b2.push({ from: pl.holder, to: USDC, data: encodeFunctionData({ abi: ERC20, functionName: 'approve', args: [helper, MAX] }), gas: GAS });
    b2.push({ from: pl.holder, to: helper, data: encodeFunctionData({ abi: H, functionName: 'repayAndWithdraw', args: [pl.mp, MAX, MAX] }), gas: GAS });
    b2.push({ from: pl.holder, to: MORPHO, data: encodeFunctionData({ abi: MB, functionName: 'position', args: [pl.id, pl.holder] }) });
    b2.push({ from: pl.holder, to: pl.stock, data: encodeFunctionData({ abi: ERC20, functionName: 'balanceOf', args: [pl.holder] }) });
    b2.push({ from: pl.holder, to: USDC, data: encodeFunctionData({ abi: ERC20, functionName: 'balanceOf', args: [helper] }) });
    b2.push({ from: pl.holder, to: pl.stock, data: encodeFunctionData({ abi: ERC20, functionName: 'balanceOf', args: [helper] }) });
  }

  const res = await rpc('eth_simulateV1', [{ blockStateCalls: [{ calls: b1 }, { blockOverrides: { time: hex(now + 7n * 86400n) }, calls: b2 }], validation: false }, hex(block)]);
  const [r1, r2] = res.map((b) => b.calls);
  const ok = (c) => c.status === '0x1';
  const u = (c, abi = ERC20, fn = 'balanceOf') => decodeFunctionResult({ abi, functionName: fn, data: c.returnData });

  console.log(`block ${block}, helper would deploy at ${helper}`);
  if (!ok(r1[0])) { console.log('DEPLOY FAILED', errName(r1[0].returnData)); process.exit(1); }
  for (let i = 1; i <= plans.length; i++) if (!ok(r1[i])) problems.push(`setListed ${plans[i - 1].sym} failed: ${errName(r1[i].returnData)}`);

  for (const pl of plans) {
    const x = idx[pl.sym];
    const dec = pl.sym === 'USDC' ? 6 : 18;
    console.log(`\n${pl.sym}  holder ${pl.holder}`);
    console.log(`  collateral ${pl.bal} raw   market free liquidity ${formatUnits(pl.free, 6)}   helper limit ${formatUnits(pl.limit, 6)}   borrowing ${formatUnits(pl.borrow, 6)} USDC`);
    for (const k of [2, 3]) if (!ok(r1[x.safeBefore + k])) problems.push(`${pl.sym}: ${k === 2 ? 'setAuthorization' : 'stock approve'} failed ${errName(r1[x.safeBefore + k].returnData)}`);
    const bc = r1[x.borrow];
    if (!ok(bc)) { problems.push(`${pl.sym}: BORROW REVERTED ${errName(bc.returnData || bc.error?.data)}`); console.log(`  borrow REVERTED: ${errName(bc.returnData || bc.error?.data)}`); continue; }
    const received = decodeFunctionResult({ abi: H, functionName: 'supplyCollateralAndBorrow', data: bc.returnData });
    const safeGot = u(r1[x.after]) - u(r1[x.safeBefore]);
    const userGot = u(r1[x.after + 1]) - u(r1[x.safeBefore + 1]);
    const pos = u(r1[x.after + 2], MB, 'position');
    const fee = pl.borrow / 100n;
    console.log(`  borrow ok, gas ${BigInt(bc.gasUsed)}: user +${formatUnits(userGot, 6)}  Safe +${formatUnits(safeGot, 6)}  position collateral ${pos[2]} borrowShares ${pos[1]}`);
    if (safeGot !== fee) problems.push(`${pl.sym}: Safe got ${safeGot}, expected ${fee}`);
    if (userGot !== pl.borrow - fee || received !== userGot) problems.push(`${pl.sym}: user got ${userGot}, expected ${pl.borrow - fee}`);
    if (pos[2] !== pl.bal) problems.push(`${pl.sym}: position collateral ${pos[2]} != ${pl.bal}`);
    if (u(r1[x.after + 3]) !== 0n) problems.push(`${pl.sym}: holder still has stock after posting all of it`);
    if (u(r1[x.after + 4]) !== 0n) problems.push(`${pl.sym}: helper kept stock`);

    const y = x.b2;
    if (!ok(r2[y])) problems.push(`${pl.sym}: interest top-up transfer failed (sim harness, not the helper)`);
    const rc = r2[y + 2];
    if (!ok(rc)) { problems.push(`${pl.sym}: REPAY/WITHDRAW REVERTED ${errName(rc.returnData || rc.error?.data)}`); continue; }
    const [repaid, withdrawn] = decodeFunctionResult({ abi: H, functionName: 'repayAndWithdraw', data: rc.returnData });
    const pos2 = u(r2[y + 3], MB, 'position');
    console.log(`  +7d repay-all ok, gas ${BigInt(rc.gasUsed)}: repaid ${formatUnits(repaid, 6)} USDC, collateral back ${withdrawn} raw, position now [${pos2.join(', ')}]`);
    if (pos2[0] + pos2[1] + pos2[2] !== 0n) problems.push(`${pl.sym}: position not closed: ${pos2}`);
    if (withdrawn !== pl.bal || u(r2[y + 4]) !== pl.bal) problems.push(`${pl.sym}: holder did not get all stock back`);
    if (repaid < pl.borrow) problems.push(`${pl.sym}: repaid less than borrowed after a week`);
    if (u(r2[y + 5]) !== 0n || u(r2[y + 6]) !== 0n) problems.push(`${pl.sym}: helper left holding a balance`);
  }
  console.log('\nproblems:', problems);
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
