// Claim-day solvency + amounts sweep against LIVE Base, pinned to one block.
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, formatUnits, getAddress } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');

const env = fs.readFileSync('C:/Users/1136962520/chipworks-contracts/.env', 'utf8');
const RPC = env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim();
const rd = (f) => JSON.parse(fs.readFileSync(path.join(__dirname, f), 'utf8').replace(/^\uFEFF/, ''));
const CLAIMS_ABI = rd('claims.abi.json');
const ROUNDS_ABI = rd('rounds.abi.json');
const ERC20 = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function decimals() view returns (uint8)',
  'function symbol() view returns (string)',
]);
const REG = parseAbi(['function allTokens() view returns (address[])', 'function isEnabled(address) view returns (bool)']);

const CLAIMS = '0x9bD35c70a80F132d087719305E37A888204d4c80';
const ROUNDS = '0xa8192D4Ee3526CA8158cBE83b2FC05BdC205bed3';
const REGISTRY = '0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458';

const c = createPublicClient({ chain: base, transport: http(RPC, { batch: { batchSize: 50 } }) });

(async () => {
  const blk = await c.getBlock();
  const blockNumber = blk.number;
  const at = { blockNumber };
  const rc = (address, abi, functionName, args = []) => c.readContract({ address, abi, functionName, args, ...at });
  const cl = (fn, args) => rc(CLAIMS, CLAIMS_ABI, fn, args);
  const ro = (fn, args) => rc(ROUNDS, ROUNDS_ABI, fn, args);

  const out = { block: blockNumber.toString(), blockTime: Number(blk.timestamp), blockTimeIso: new Date(Number(blk.timestamp) * 1000).toISOString() };

  // ---- wiring + schedule
  const [roundsAddr, pol, owner, anchor, wl, wod, expiry, ws, isOpen, nextOpen, pendR, pendP, quote] = await Promise.all([
    cl('rounds'), cl('polTreasury'), cl('owner'), cl('windowAnchor'), cl('windowLength'), cl('windowOpenDuration'),
    cl('creditExpiry'), cl('claimWindowState'), cl('isClaimOpen'), cl('nextWindowOpensAt'), cl('pendingRounds'),
    cl('pendingPolTreasury'), cl('quoteToken'),
  ]);
  const roundsClaims = await ro('claims');
  const iso = (t) => new Date(Number(t) * 1000).toISOString();
  out.wiring = { claimsRounds: roundsAddr, roundsClaims, rounds_points_to_claims: getAddress(roundsClaims) === getAddress(CLAIMS),
    claims_points_to_rounds: getAddress(roundsAddr) === getAddress(ROUNDS), polTreasury: pol, owner, quote, pendingRounds: pendR, pendingPol: pendP };
  out.schedule = { windowAnchor: Number(anchor), anchorIso: iso(anchor), windowLength_h: wl / 3600, openDuration_h: wod / 3600,
    creditExpiry_d: Number(expiry) / 86400, open: ws[0], opensAt: Number(ws[1]), opensAtIso: iso(ws[1]), closesAt: Number(ws[2]),
    closesAtIso: iso(ws[2]), isClaimOpen: isOpen, nextWindowOpensAt: Number(nextOpen) };

  // ---- rounds
  const roundCount = Number(await ro('roundCount'));
  const rounds = [];
  const stockSet = new Set([getAddress(quote)]);
  for (let i = 1; i <= roundCount; i++) {
    const [r, stocks, sch, fin, gw, wr, openFor] = await Promise.all([
      ro('getRound', [BigInt(i)]), ro('roundStocks', [BigInt(i)]), cl('scheduleOf', [BigInt(i)]), cl('isFinalized', [BigInt(i)]),
      cl('guaranteedWindows', [BigInt(i)]), cl('windowsRemaining', [BigInt(i)]), cl('isClaimOpenFor', [BigInt(i)]),
    ]);
    stocks.forEach((s) => stockSet.add(getAddress(s)));
    rounds.push({ id: i, state: ['None', 'Accumulating', 'Buying', 'Finalized'][r.state], openedAt: iso(r.openedAt),
      finalizedAt: r.finalizedAt ? iso(r.finalizedAt) : null, budget: r.budget, spent: r.spent, totalWeight: r.totalWeight, stocks,
      schedule: { finalizedAt: Number(sch.finalizedAt), expiresAt: Number(sch.expiresAt), expiresIso: sch.expiresAt ? iso(sch.expiresAt) : null,
        windowLengthAt: sch.windowLengthAt, openDurationAt: sch.openDurationAt }, ledgerFinalized: fin, guaranteedWindows: Number(gw),
      windowsRemaining: Number(wr), isClaimOpenFor: openFor });
  }
  try { (await rc(REGISTRY, REG, 'allTokens')).forEach((s) => stockSet.add(getAddress(s))); } catch (e) { out.registryErr = e.shortMessage; }

  // ---- token meta + balances
  const tokens = {};
  for (const s of stockSet) {
    let sym = '?', dec = 18, bal = null, err = null;
    try { sym = await rc(s, ERC20, 'symbol'); } catch {}
    try { dec = await rc(s, ERC20, 'decimals'); } catch {}
    try { bal = await rc(s, ERC20, 'balanceOf', [CLAIMS]); } catch (e) { err = e.shortMessage; }
    const owed = await cl('totalOwed', [s]);
    tokens[s] = { sym, dec, balance: bal, totalOwed: owed, balErr: err, sumAcqNet: 0n, sumClaimableFinal: 0n, sumClaimableOpen: 0n };
  }

  // ---- per (round, stock), per holder
  const problems = [];
  const holdersAll = new Set();
  const positions = []; // finalized & claimable > 0
  for (const r of rounds) {
    r.detail = [];
    for (const sRaw of r.stocks) {
      const s = getAddress(sRaw);
      const t = tokens[s];
      const [tw, acq, ct, st, swept, hs] = await Promise.all([
        cl('totalWeight', [BigInt(r.id), s]), cl('acquired', [BigInt(r.id), s]), cl('claimedTotal', [BigInt(r.id), s]),
        cl('sweptTotal', [BigInt(r.id), s]), cl('stockSwept', [BigInt(r.id), s]), cl('holders', [BigInt(r.id), s]),
      ]);
      let sumW = 0n, sumC = 0n, sumCalc = 0n, nClaimed = 0;
      const hrows = await Promise.all(hs.map(async (h) => {
        const [w, cla, hc] = await Promise.all([cl('weightOf', [BigInt(r.id), s, h]), cl('claimable', [BigInt(r.id), s, h]), cl('hasClaimed', [BigInt(r.id), s, h])]);
        return { h, w, cla, hc };
      }));
      const seen = new Set();
      for (const { h, w, cla, hc } of hrows) {
        if (seen.has(h)) problems.push(`R${r.id} ${t.sym}: duplicate holder ${h}`);
        seen.add(h);
        holdersAll.add(getAddress(h));
        sumW += w;
        const expect = hc || tw === 0n || acq === 0n ? 0n : (acq * w) / tw;
        if (expect !== cla) problems.push(`R${r.id} ${t.sym} ${h}: claimable ${cla} != formula ${expect}`);
        sumC += cla;
        if (!hc) sumCalc += tw === 0n ? 0n : (acq * w) / tw;
        if (hc) nClaimed++;
        if (r.ledgerFinalized && cla > 0n) positions.push({ round: r.id, stock: s, sym: t.sym, owner: getAddress(h), amount: cla, dec: t.dec });
      }
      if (sumW !== tw) problems.push(`R${r.id} ${t.sym}: sum(weightOf)=${sumW} != totalWeight=${tw}`);
      const net = acq - ct - st;
      if (sumC > net) problems.push(`R${r.id} ${t.sym}: sum claimable ${sumC} > acquired-claimed-swept ${net}`);
      t.sumAcqNet += net;
      if (r.ledgerFinalized) t.sumClaimableFinal += sumC; else t.sumClaimableOpen += sumC;
      r.detail.push({ stock: s, sym: t.sym, holders: hs.length, claimedCount: nClaimed, totalWeight: tw, acquired: acq,
        acquiredFmt: formatUnits(acq, t.dec), claimedTotal: ct, sweptTotal: st, stockSwept: swept, sumClaimable: sumC,
        sumClaimableFmt: formatUnits(sumC, t.dec), roundingDust: net - sumC });
    }
  }

  // ---- per-token solvency
  out.solvency = {};
  for (const [s, t] of Object.entries(tokens)) {
    const checks = {
      totalOwed_equals_ledgerNet: t.totalOwed === t.sumAcqNet,
      balance_ge_totalOwed: t.balance !== null && t.balance >= t.totalOwed,
      balance_ge_sumClaimableAll: t.balance !== null && t.balance >= t.sumClaimableFinal + t.sumClaimableOpen,
    };
    for (const [k, v] of Object.entries(checks)) if (!v) problems.push(`${t.sym} ${s}: ${k} FAILED`);
    out.solvency[t.sym + ' ' + s] = { decimals: t.dec, balance: t.balance === null ? `ERR ${t.balErr}` : formatUnits(t.balance, t.dec),
      totalOwed: formatUnits(t.totalOwed, t.dec), sumLedgerNet: formatUnits(t.sumAcqNet, t.dec),
      claimableFinalizedRounds: formatUnits(t.sumClaimableFinal, t.dec), claimableUnfinalizedRounds: formatUnits(t.sumClaimableOpen, t.dec),
      excess: t.balance === null ? null : formatUnits(t.balance - t.totalOwed, t.dec), rawBalance: t.balance, rawOwed: t.totalOwed, checks };
  }

  out.rounds = rounds;
  out.holderCount = holdersAll.size;
  out.holders = [...holdersAll];
  out.positions = positions;
  out.problems = problems;
  fs.writeFileSync(path.join(__dirname, 'sweep.out.json'), JSON.stringify(out, (k, v) => (typeof v === 'bigint' ? v.toString() : v), 2));
  console.log(JSON.stringify({ block: out.block, blockTimeIso: out.blockTimeIso, schedule: out.schedule, wiring: out.wiring, roundCount,
    holderCount: out.holderCount, finalizedPositions: positions.length, problems }, (k, v) => (typeof v === 'bigint' ? v.toString() : v), 2));
})().catch((e) => { console.error(e); process.exit(1); });
