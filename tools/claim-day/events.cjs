// Cross-check ledger `acquired` / `weightOf` against event history from both contracts.
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbiItem, getAddress } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync('C:/Users/1136962520/chipworks-contracts/.env', 'utf8');
const RPC = env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim();
const c = createPublicClient({ chain: base, transport: http(RPC) });
const sweep = JSON.parse(fs.readFileSync(path.join(__dirname, 'sweep.out.json'), 'utf8'));

const CLAIMS = '0x9bD35c70a80F132d087719305E37A888204d4c80';
const ROUNDS = '0xa8192D4Ee3526CA8158cBE83b2FC05BdC205bed3';
const EV = {
  StockBought: parseAbiItem('event StockBought(uint256 indexed roundId, address indexed stock, uint256 spent, uint256 received)'),
  HoldbackSent: parseAbiItem('event HoldbackSent(uint256 indexed roundId, address indexed stock, uint256 amount)'),
  StockStranded: parseAbiItem('event StockStranded(uint256 indexed roundId, address indexed stock, uint256 amount)'),
  LedgerRefusedBooking: parseAbiItem('event LedgerRefusedBooking(uint256 indexed roundId, address indexed stock, uint256 amount)'),
  StockUnderdelivered: parseAbiItem('event StockUnderdelivered(uint256 indexed roundId, address indexed stock, uint256 spent, uint256 received)'),
  StockSkipped: parseAbiItem('event StockSkipped(uint256 indexed roundId, address indexed stock, uint256 wouldHaveSpent, bytes reason)'),
  SliceTrimmed: parseAbiItem('event SliceTrimmed(uint256 indexed roundId, address indexed stock, uint256 slice, uint256 spent)'),
  RoundFinalized: parseAbiItem('event RoundFinalized(uint256 roundId, uint256 spent, uint256 returned, uint256 valueUsd)'),
  AcquiredRecorded: parseAbiItem('event AcquiredRecorded(uint256 indexed roundId, address indexed stock, uint256 amount)'),
  WeightCredited: parseAbiItem('event WeightCredited(uint256 indexed roundId, address indexed stock, address indexed owner, uint256 weight)'),
  Claimed: parseAbiItem('event Claimed(uint256 indexed roundId, address indexed stock, address indexed owner, uint256 amount)'),
  Swept: parseAbiItem('event Swept(uint256 indexed roundId, address indexed stock, uint256 amount, bool complete)'),
  ExcessRecovered: parseAbiItem('event ExcessRecovered(address indexed token, address indexed to, uint256 amount)'),
  ClaimScheduleUpdated: parseAbiItem('event ClaimScheduleUpdated(uint32 windowLength, uint32 openDuration, uint64 creditExpiry)'),
};

async function logs(address, event, from, to) {
  let step = BigInt(process.env.STEP || 100000);
  const all = [];
  for (let a = from; a <= to; ) {
    const b = a + step - 1n > to ? to : a + step - 1n;
    try {
      all.push(...(await c.getLogs({ address, event, fromBlock: a, toBlock: b })));
      a = b + 1n;
    } catch (e) {
      if (step <= 10n) throw e;
      step = step / 5n;
    }
  }
  return all;
}

(async () => {
  const to = BigInt(sweep.block);
  const from = BigInt(process.env.FROM || 50600000);
  const r = {};
  for (const [n, ev] of Object.entries(EV)) {
    const addr = ['AcquiredRecorded', 'WeightCredited', 'Claimed', 'Swept', 'ExcessRecovered', 'ClaimScheduleUpdated'].includes(n) ? CLAIMS : ROUNDS;
    r[n] = await logs(addr, ev, from, to);
    console.log(n, r[n].length);
  }
  const key = (a, s) => `${a}|${getAddress(s)}`;
  const acqEv = {}, boughtRecv = {}, holdback = {}, wEv = {};
  for (const l of r.AcquiredRecorded) acqEv[key(l.args.roundId, l.args.stock)] = (acqEv[key(l.args.roundId, l.args.stock)] || 0n) + l.args.amount;
  for (const l of r.StockBought) boughtRecv[key(l.args.roundId, l.args.stock)] = (boughtRecv[key(l.args.roundId, l.args.stock)] || 0n) + l.args.received;
  for (const l of r.HoldbackSent) holdback[key(l.args.roundId, l.args.stock)] = l.args.amount;
  for (const l of r.WeightCredited) { const k = `${l.args.roundId}|${getAddress(l.args.stock)}|${getAddress(l.args.owner)}`; wEv[k] = (wEv[k] || 0n) + l.args.weight; }

  const problems = [];
  for (const rd of sweep.rounds) for (const d of rd.detail) {
    const k = key(rd.id, d.stock);
    const ledger = BigInt(d.acquired);
    if ((acqEv[k] || 0n) !== ledger) problems.push(`R${rd.id} ${d.sym}: AcquiredRecorded sum ${acqEv[k] || 0n} != acquired ${ledger}`);
    if (rd.state === 'Finalized' && (boughtRecv[k] || 0n) !== ledger) problems.push(`R${rd.id} ${d.sym}: StockBought.received ${boughtRecv[k] || 0n} != acquired ${ledger}`);
  }
  const wSum = {};
  for (const [k, w] of Object.entries(wEv)) { const [rid, s] = k.split('|'); wSum[`${rid}|${s}`] = (wSum[`${rid}|${s}`] || 0n) + w; }
  for (const rd of sweep.rounds) for (const d of rd.detail) {
    if ((wSum[key(rd.id, d.stock)] || 0n) !== BigInt(d.totalWeight)) problems.push(`R${rd.id} ${d.sym}: WeightCredited sum != totalWeight`);
  }
  const fmt = (l) => ({ ...l.args, tx: l.transactionHash, block: l.blockNumber });
  const out = {
    problems,
    anomalies: { StockStranded: r.StockStranded.map(fmt), LedgerRefusedBooking: r.LedgerRefusedBooking.map(fmt), StockUnderdelivered: r.StockUnderdelivered.map(fmt),
      Claimed: r.Claimed.map(fmt), Swept: r.Swept.map(fmt), ExcessRecovered: r.ExcessRecovered.map(fmt), ClaimScheduleUpdated: r.ClaimScheduleUpdated.map(fmt) },
    skipped: r.StockSkipped.map((l) => ({ round: l.args.roundId, stock: l.args.stock, wouldHaveSpent: l.args.wouldHaveSpent, reason: Buffer.from(l.args.reason.slice(2), 'hex').toString('latin1').replace(/[^\x20-\x7e]/g, '.') })),
    trimmed: r.SliceTrimmed.map(fmt),
    finalized: r.RoundFinalized.map(fmt),
    holdbacks: Object.keys(holdback).length,
  };
  console.log(JSON.stringify(out, (k, v) => (typeof v === 'bigint' ? v.toString() : v), 2));
})().catch((e) => { console.error(e.shortMessage || e.message); process.exit(1); });
