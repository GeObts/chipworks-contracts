// Claim day, simulated on the LIVE Base node via eth_simulateV1 (B20 precompiles execute for real).
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { encodeFunctionData, decodeFunctionResult, decodeErrorResult, parseAbi, getAddress, formatUnits, keccak256, toHex } = req('viem');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync('C:/Users/1136962520/chipworks-contracts/.env', 'utf8');
const RPC = env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim();
const rd = (f) => JSON.parse(fs.readFileSync(path.join(__dirname, f), 'utf8').replace(/^\uFEFF/, ''));
const CLAIMS_ABI = rd('claims.abi.json');
const S = rd('sweep.out.json');

const CLAIMS = '0x9bD35c70a80F132d087719305E37A888204d4c80';
const ROUTER = '0x5B7bee0D82e1E722014Dc06dEc2B6fD8a6adE833';
const MC3 = '0xcA11bde05977b3631167028862bE2a173976CA11';
const STRANGER = '0x000000000000000000000000000000000000bEEF';
const ERC20 = parseAbi(['function balanceOf(address) view returns (uint256)']);
const MC = parseAbi(['struct Call3 { address target; bool allowFailure; bytes callData; }', 'struct Result { bool success; bytes returnData; }',
  'function aggregate3(Call3[] calls) view returns (Result[] returnData)']);
const ROUTER_ABI = parseAbi(['struct ChipClaim { uint256 roundId; address stock; }', 'function claimEverything(ChipClaim[] claims_) returns (uint256 succeeded)']);
const GAS = '0x1c9c380'; // 30M

const rpc = async (method, params) => {
  const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(JSON.stringify(j.error));
  return j.result;
};
const hex = (n) => '0x' + BigInt(n).toString(16);
const cdata = (fn, args) => encodeFunctionData({ abi: CLAIMS_ABI, functionName: fn, args });
const call = (from, to, data) => ({ from, to, data, gas: GAS });
const revData = (c) => (c.error && c.error.data) || c.returnData;
const decErr = (data) => {
  if (!data || data === '0x') return 'revert (no data)';
  try { const e = decodeErrorResult({ abi: CLAIMS_ABI, data }); return `${e.errorName}(${(e.args || []).map(String).join(',')})`; } catch { return `raw ${data.slice(0, 10)}`; }
};
const multiread = (reads) => call(STRANGER, MC3, encodeFunctionData({ abi: MC, functionName: 'aggregate3', args: [reads.map((r) => ({ target: r.target, allowFailure: true, callData: r.data }))] }));
const parseMulti = (res, reads) => {
  if (res.status !== '0x1') throw new Error(`multiread reverted: ${JSON.stringify(res).slice(0, 300)}`);
  const out = decodeFunctionResult({ abi: MC, functionName: 'aggregate3', data: res.returnData });
  return out.map((o, i) => (o.success ? reads[i].decode(o.returnData) : `ERR`));
};
const simulate = async (blocks) => rpc('eth_simulateV1', [{ blockStateCalls: blocks, validation: false, traceTransfers: false }, S.block === undefined ? 'latest' : hex(S.block)]);

const opensAt = S.schedule.opensAt, closesAt = S.schedule.closesAt;
const W = 7 * 86400;
const positions = S.positions.map((p) => ({ ...p, amount: BigInt(p.amount) }));
const byOwner = {};
for (const p of positions) (byOwner[p.owner] ||= []).push(p);
const owners = Object.keys(byOwner);
const dec = Object.fromEntries(positions.map((p) => [p.stock, p.dec]));
const sym = Object.fromEntries(positions.map((p) => [p.stock, p.sym]));
const tokens = [...new Set(Object.keys(S.solvency).map((k) => getAddress(k.split(' ')[1])))];

// read helpers
const balRead = (token, who) => ({ target: token, data: encodeFunctionData({ abi: ERC20, functionName: 'balanceOf', args: [who] }), decode: (d) => decodeFunctionResult({ abi: ERC20, functionName: 'balanceOf', data: d }) });
const clRead = (fn, args) => ({ target: CLAIMS, data: cdata(fn, args), decode: (d) => decodeFunctionResult({ abi: CLAIMS_ABI, functionName: fn, data: d }) });

function holderBalanceReads(who) {
  const toks = [...new Set(byOwner[who].map((p) => p.stock))];
  return toks.map((t) => ({ ...balRead(t, who), token: t, who }));
}
const allHolderReads = owners.flatMap(holderBalanceReads);
const strangerReads = tokens.map((t) => ({ ...balRead(t, STRANGER), token: t, who: STRANGER }));
const ledgerReads = tokens.flatMap((t) => [{ ...balRead(t, CLAIMS), token: t, kind: 'bal' }, { ...clRead('totalOwed', [t]), token: t, kind: 'owed' }]);

const problems = [];
const report = {};

function checkClaimRun(label, pre, post, preStr, postStr, ledgerPost, claimResults) {
  // per holder, per token: delta must equal sum owed
  const exp = {};
  for (const p of positions) exp[`${p.owner}|${p.stock}`] = (exp[`${p.owner}|${p.stock}`] || 0n) + p.amount;
  let checked = 0, total = {};
  allHolderReads.forEach((r, i) => {
    const k = `${r.who}|${r.token}`;
    if (pre[i] === 'ERR' || post[i] === 'ERR') { problems.push(`${label}: balance read failed ${k}`); return; }
    const d = post[i] - pre[i];
    if (d !== exp[k]) problems.push(`${label}: ${sym[r.token]} ${r.who} got ${d} expected ${exp[k]}`);
    total[r.token] = (total[r.token] || 0n) + d;
    checked++;
  });
  strangerReads.forEach((r, i) => { if (preStr[i] !== postStr[i]) problems.push(`${label}: STRANGER balance moved in ${r.token}`); });
  const ledger = {};
  ledgerReads.forEach((r, i) => { (ledger[r.token] ||= {})[r.kind] = ledgerPost[i]; });
  const ledgerOut = {};
  for (const t of tokens) {
    const L = ledger[t];
    const s = Object.entries(S.solvency).find(([k]) => getAddress(k.split(' ')[1]) === t)[1];
    const paid = total[t] || 0n;
    const preBal = BigInt(s.rawBalance);
    if (L.bal + paid !== preBal) problems.push(`${label}: ${t} ledger balance ${L.bal} + paid ${paid} != pre ${preBal}`);
    if (L.bal < L.owed) problems.push(`${label}: ${t} INSOLVENT after run: bal ${L.bal} < owed ${L.owed}`);
    if (L.bal !== L.owed) problems.push(`${label}: ${t} bal ${L.bal} != owed ${L.owed} after run`);
    const d = dec[t] ?? 6;
    ledgerOut[t] = { paid: formatUnits(paid, d), leftBal: L.bal.toString(), leftOwed: L.owed.toString() };
  }
  report[label] = { holderTokenDeltasChecked: checked, ledgerAfter: ledgerOut, ...claimResults };
}

(async () => {
  // ================= SIM A: the site path, every holder claimMany at opensAt =================
  {
    const sample = owners.slice(0, 3);
    const B0 = { blockOverrides: { time: hex(opensAt - 1) }, calls: [
      multiread(allHolderReads), multiread(strangerReads),
      ...sample.map((h) => call(h, CLAIMS, cdata('claimMany', [byOwner[h].map((p) => BigInt(p.round)), byOwner[h].map((p) => p.stock)]))),
      ...sample.map((h) => call(h, CLAIMS, cdata('claim', [BigInt(byOwner[h][0].round), byOwner[h][0].stock]))),
      ...sample.map((h) => call(STRANGER, CLAIMS, cdata('claimFor', [h, BigInt(byOwner[h][0].round), byOwner[h][0].stock]))),
      multiread(owners.map((h) => clRead('autoCompound', [h]))),
    ] };
    // attacker first, inside the open window, before any holder
    const allPairs = [];
    for (const r of S.rounds.filter((r) => r.ledgerFinalized)) for (const d of r.detail) allPairs.push({ round: BigInt(r.id), stock: d.stock });
    const B1 = { blockOverrides: { time: hex(opensAt) }, calls: [
      call(STRANGER, CLAIMS, cdata('claimMany', [allPairs.map((p) => p.round), allPairs.map((p) => p.stock)])),
      ...allPairs.map((p) => call(STRANGER, CLAIMS, cdata('claim', [p.round, p.stock]))),
      ...owners.map((h) => call(h, CLAIMS, cdata('claimMany', [byOwner[h].map((p) => BigInt(p.round)), byOwner[h].map((p) => p.stock)]))),
    ] };
    const B2 = { blockOverrides: { time: hex(opensAt + 1) }, calls: [
      multiread(allHolderReads), multiread(strangerReads), multiread(ledgerReads),
      multiread(positions.map((p) => clRead('hasClaimed', [BigInt(p.round), p.stock, p.owner]))),
      multiread(positions.map((p) => clRead('claimable', [BigInt(p.round), p.stock, p.owner]))),
      ...owners.map((h) => call(h, CLAIMS, cdata('claimMany', [byOwner[h].map((p) => BigInt(p.round)), byOwner[h].map((p) => p.stock)]))),
    ] };
    const B3 = { blockOverrides: { time: hex(opensAt + 2) }, calls: [
      ...positions.map((p) => call(p.owner, CLAIMS, cdata('claim', [BigInt(p.round), p.stock]))),
      ...positions.map((p) => call(STRANGER, CLAIMS, cdata('claimFor', [p.owner, BigInt(p.round), p.stock]))),
    ] };
    const res = await simulate([B0, B1, B2, B3]);
    const [b0, b1, b2, b3] = res.map((b) => b.calls);
    const pre = parseMulti(b0[0], allHolderReads), preStr = parseMulti(b0[1], strangerReads);
    let i = 2;
    const closed = [];
    for (let k = 0; k < sample.length * 3; k++, i++) {
      const c = b0[i];
      const e = decErr(revData(c));
      closed.push(e);
      if (c.status !== '0x0' || !e.startsWith(`ClaimsClosed(${opensAt - 1},${opensAt})`)) problems.push(`A/B0 pre-open call ${k} did not revert ClaimsClosed: ${c.status} ${e}`);
    }
    const ac = parseMulti(b0[i], owners.map((h) => clRead('autoCompound', [h])));
    const autoOn = owners.filter((h, j) => ac[j] === true);

    const atk = b1.slice(0, 1 + allPairs.length);
    atk.forEach((c, k) => { const e = decErr(revData(c)); if (c.status !== '0x0' || e !== 'NothingToClaim()') problems.push(`A/B1 attacker call ${k} not NothingToClaim: ${c.status} ${e}`); });
    const hc = b1.slice(1 + allPairs.length);
    let maxGas = 0, maxGasOwner = null, failed = [];
    hc.forEach((c, k) => {
      const g = Number(c.gasUsed);
      if (g > maxGas) { maxGas = g; maxGasOwner = `${owners[k]} (${byOwner[owners[k]].length} positions)`; }
      if (c.status !== '0x1') failed.push(`${owners[k]}: ${decErr(revData(c))}`);
    });
    failed.forEach((f) => problems.push(`A/B1 holder claimMany FAILED ${f}`));

    const post = parseMulti(b2[0], allHolderReads), postStr = parseMulti(b2[1], strangerReads), ledgerPost = parseMulti(b2[2], ledgerReads);
    const hcAfter = parseMulti(b2[3], positions.map((p) => clRead('hasClaimed', [BigInt(p.round), p.stock, p.owner])));
    const clAfter = parseMulti(b2[4], positions.map((p) => clRead('claimable', [BigInt(p.round), p.stock, p.owner])));
    hcAfter.forEach((v, k) => { if (v !== true) problems.push(`A: hasClaimed not set for ${JSON.stringify(positions[k], (a, b) => (typeof b === 'bigint' ? b.toString() : b))}`); });
    clAfter.forEach((v, k) => { if (v !== 0n) problems.push(`A: claimable not zero after claim, position ${k}`); });
    const rep = b2.slice(5);
    rep.forEach((c, k) => { const e = decErr(revData(c)); if (c.status !== '0x0' || e !== 'NothingToClaim()') problems.push(`A/B2 repeat claimMany ${owners[k]} not NothingToClaim: ${c.status} ${e}`); });
    b3.forEach((c, k) => { const e = decErr(revData(c)); if (c.status !== '0x0' || !e.startsWith('AlreadyClaimed(')) problems.push(`A/B3 repeat single ${k} not AlreadyClaimed: ${c.status} ${e}`); });

    checkClaimRun('A_siteClaimMany', pre, post, preStr, postStr, ledgerPost, {
      preOpenRevertsSeen: [...new Set(closed)], autoCompoundOn: autoOn, attackerCallsReverted: atk.length, holdersClaimed: hc.length - failed.length,
      holdersFailed: failed.length, maxClaimManyGas: maxGas, maxGasOwner, repeatClaimManyReverted: rep.length, repeatSingleAndClaimForReverted: b3.length,
    });
  }

  // ================= SIM B: other entry points - claim(), claimFor by stranger, ClaimRouter =================
  {
    const t = opensAt + 3600;
    const B0 = { blockOverrides: { time: hex(t) }, calls: [multiread(allHolderReads), multiread(strangerReads)] };
    const calls = [], kinds = [];
    owners.forEach((h, k) => {
      const mode = k % 3;
      if (mode === 0) byOwner[h].forEach((p) => { calls.push(call(h, CLAIMS, cdata('claim', [BigInt(p.round), p.stock]))); kinds.push(['claim', h, p]); });
      if (mode === 1) byOwner[h].forEach((p) => { calls.push(call(STRANGER, CLAIMS, cdata('claimFor', [h, BigInt(p.round), p.stock]))); kinds.push(['claimFor', h, p]); });
      if (mode === 2) { calls.push(call(h, ROUTER, encodeFunctionData({ abi: ROUTER_ABI, functionName: 'claimEverything', args: [byOwner[h].map((p) => ({ roundId: BigInt(p.round), stock: p.stock }))] }))); kinds.push(['router', h, byOwner[h]]); }
    });
    const B1 = { blockOverrides: { time: hex(t + 1) }, calls };
    const B2 = { blockOverrides: { time: hex(t + 2) }, calls: [multiread(allHolderReads), multiread(strangerReads), multiread(ledgerReads),
      multiread([balRead(tokens[0], ROUTER), ...tokens.slice(1).map((x) => balRead(x, ROUTER))])] };
    const res = await simulate([B0, B1, B2]);
    const [b0, b1, b2] = res.map((b) => b.calls);
    const byKind = { claim: 0, claimFor: 0, router: 0 };
    b1.forEach((c, k) => {
      const [kind, h, p] = kinds[k];
      if (c.status !== '0x1') { problems.push(`B ${kind} ${h} FAILED ${decErr(revData(c))}`); return; }
      if (kind !== 'router') {
        const amt = decodeFunctionResult({ abi: CLAIMS_ABI, functionName: kind, data: c.returnData });
        if (amt !== p.amount) problems.push(`B ${kind} ${h} R${p.round} ${p.sym} returned ${amt} expected ${p.amount}`);
      } else {
        const n = decodeFunctionResult({ abi: ROUTER_ABI, functionName: 'claimEverything', data: c.returnData });
        if (Number(n) !== p.length) problems.push(`B router ${h} succeeded ${n} of ${p.length}`);
      }
      byKind[kind]++;
    });
    const routerBals = parseMulti(b2[3], tokens.map((x) => balRead(x, ROUTER)));
    routerBals.forEach((v, k) => { if (v !== 0n) problems.push(`B router holds ${v} of ${tokens[k]} after claims`); });
    checkClaimRun('B_otherEntryPoints', parseMulti(b0[0], allHolderReads), parseMulti(b2[0], allHolderReads), parseMulti(b0[1], strangerReads),
      parseMulti(b2[1], strangerReads), parseMulti(b2[2], ledgerReads), { successfulCalls: byKind });
  }

  // ================= SIM C: window edges, next window, expiry =================
  {
    const usdc = getAddress(S.wiring.quote);
    const pick = (round) => positions.filter((p) => p.round === round && p.stock === usdc);
    const r1 = pick(1), r3 = pick(3);
    const r1exp = S.rounds[0].schedule.expiresAt, r3exp = S.rounds[2].schedule.expiresAt;
    // the last window opening at or before each expiry
    const lastOpenBefore = (exp) => { let o = opensAt; while (o + W <= exp) o += W; return o; };
    const steps = [
      ['closesAt-1: still open, claim R1 USDC succeeds', closesAt - 1, r1[0], 'ok'],
      ['closesAt: shut', closesAt, r1[1], `ClaimsClosed(${closesAt},${opensAt + W})`],
      ['opensAt+7d-1: shut', opensAt + W - 1, r1[1], `ClaimsClosed(${opensAt + W - 1},${opensAt + W})`],
      ['opensAt+7d: second window open', opensAt + W, r1[1], 'ok'],
      [`R1 last window (${new Date(lastOpenBefore(r1exp) * 1000).toISOString()}) open`, lastOpenBefore(r1exp) + 60, r1[2], 'ok'],
      ['R1 expiresAt: window shut anyway', r1exp, r1[3], 'ClaimsClosed('],
      ['next window after R1 expiry: R1 expired', lastOpenBefore(r1exp) + W, r1[4], `CreditsExpired(1,${r1exp})`],
      ['same moment: R3 still claimable', lastOpenBefore(r1exp) + W + 1, r3[0], lastOpenBefore(r1exp) + W <= r3exp ? 'ok' : 'CreditsExpired('],
    ];
    const blocks = steps.map(([, ts, p]) => ({ blockOverrides: { time: hex(ts) }, calls: [call(p.owner, CLAIMS, cdata('claim', [BigInt(p.round), p.stock])), call(STRANGER, CLAIMS, cdata('isClaimOpen', []))] }));
    const res = await simulate(blocks);
    report.C_windowAndExpiry = steps.map(([label, ts, p, want], k) => {
      const c = res[k].calls[0];
      const got = c.status === '0x1' ? 'ok' : decErr(revData(c));
      const pass = want === 'ok' ? got === 'ok' : got.startsWith(want);
      if (!pass) problems.push(`C ${label}: got ${got} want ${want}`);
      return { label, at: new Date(ts * 1000).toISOString(), round: p.round, got, pass, isClaimOpen: decodeFunctionResult({ abi: CLAIMS_ABI, functionName: 'isClaimOpen', data: res[k].calls[1].returnData }) };
    });
  }

  report.problems = problems;
  const s = JSON.stringify(report, (k, v) => (typeof v === 'bigint' ? v.toString() : v), 2);
  fs.writeFileSync(path.join(__dirname, 'sim.out.json'), s);
  console.log(s);
})().catch((e) => { console.error(String(e.message || e).slice(0, 2000)); process.exit(1); });
