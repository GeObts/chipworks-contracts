// For one wallet, per round: share of the round's weight x budget (what they "should" get)
// versus the market value of what the ledger actually credits them, and where the gap went.
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, parseAbiItem, formatUnits, getAddress } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const RPC = env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim();
const rd = (f) => JSON.parse(fs.readFileSync(path.join(__dirname, f), 'utf8').replace(/^\uFEFF/, ''));
const CLAIMS_ABI = rd('claims.abi.json');
const ROUNDS_ABI = rd('rounds.abi.json');
const CLAIMS = '0x9bD35c70a80F132d087719305E37A888204d4c80';
const ROUNDS = '0xa8192D4Ee3526CA8158cBE83b2FC05BdC205bed3';
const REGISTRY = '0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458';
const REG = parseAbi(['function priceUsd(address) view returns (uint256, uint256)']);
const ERC20 = parseAbi(['function decimals() view returns (uint8)', 'function symbol() view returns (string)']);
const OWNER = getAddress(process.env.OWNER);
const c = createPublicClient({ chain: base, transport: http(RPC, { batch: { batchSize: 50 } }) });
const rc = (address, abi, functionName, args = []) => c.readContract({ address, abi, functionName, args });

(async () => {
  const USDC = getAddress(await rc(CLAIMS, CLAIMS_ABI, 'quoteToken'));
  const holdbackBps = await rc(ROUNDS, ROUNDS_ABI, 'holdbackBps');
  const n = Number(await rc(ROUNDS, ROUNDS_ABI, 'roundCount'));
  const bought = await c.getLogs({ address: ROUNDS, event: parseAbiItem('event StockBought(uint256 indexed roundId, address indexed stock, uint256 spent, uint256 received)'), fromBlock: 50208000n, toBlock: 'latest' })
    .catch(async () => { const out = []; const latest = await c.getBlockNumber(); for (let a = 50208000n; a <= latest; a += 100000n) out.push(...await c.getLogs({ address: ROUNDS, event: parseAbiItem('event StockBought(uint256 indexed roundId, address indexed stock, uint256 spent, uint256 received)'), fromBlock: a, toBlock: a + 99999n })); return out; });
  const meta = {};
  const info = async (t) => (meta[t] ||= { sym: await rc(t, ERC20, 'symbol'), dec: Number(await rc(t, ERC20, 'decimals')), px: t === USDC ? 1 : Number((await rc(REGISTRY, REG, 'priceUsd', [t]))[0]) / 1e18 });
  console.log(`holdbackBps ${holdbackBps}`);
  let tShare = 0, tVal = 0;
  for (let r = 1; r <= n; r++) {
    const R = await rc(ROUNDS, ROUNDS_ABI, 'getRound', [BigInt(r)]);
    const stocks = await rc(ROUNDS, ROUNDS_ABI, 'roundStocks', [BigInt(r)]);
    let myW = 0n, val = 0, roundVal = 0, roundSpent = 0;
    const lines = [];
    for (const sRaw of stocks) {
      const s = getAddress(sRaw);
      const m = await info(s);
      const [w, tw, acq, cla] = await Promise.all([rc(CLAIMS, CLAIMS_ABI, 'weightOf', [BigInt(r), s, OWNER]), rc(CLAIMS, CLAIMS_ABI, 'totalWeight', [BigInt(r), s]), rc(CLAIMS, CLAIMS_ABI, 'acquired', [BigInt(r), s]), rc(CLAIMS, CLAIMS_ABI, 'claimable', [BigInt(r), s, OWNER])]);
      myW += w;
      const ev = bought.filter((l) => l.args.roundId === BigInt(r) && getAddress(l.args.stock) === s);
      const spent = ev.reduce((a, l) => a + Number(formatUnits(l.args.spent, 6)), 0);
      const acqUsd = Number(formatUnits(acq, m.dec)) * m.px;
      roundVal += acqUsd; roundSpent += spent;
      val += Number(formatUnits(cla, m.dec)) * m.px;
      if (w > 0n) {
        const slice = (Number(R.budget) / 1e6) * Number(w) / Number(R.totalWeight);
        lines.push(`   ${m.sym.padEnd(6)} myWeight ${String(w).padStart(6)}  budget-share $${slice.toFixed(2).padStart(7)}  credited $${(Number(formatUnits(cla, m.dec)) * m.px).toFixed(2).padStart(7)}  | stock: spent $${spent.toFixed(2)} -> ledger holds $${acqUsd.toFixed(2)} (${spent ? ((acqUsd / spent) * 100).toFixed(1) : '-'}%)`);
      }
    }
    const share = Number(myW) / Number(R.totalWeight);
    const shareUsd = share * Number(R.budget) / 1e6;
    if (R.state === 3) { tShare += shareUsd; tVal += val; }
    console.log(`\nR${r} ${['None', 'Accum', 'Buying', 'Final'][R.state]}  budget $${(Number(R.budget) / 1e6).toFixed(2)} spent $${(Number(R.spent) / 1e6).toFixed(2)}  my weight ${myW}/${R.totalWeight} = ${(share * 100).toFixed(3)}%  => budget share $${shareUsd.toFixed(2)}  credited now $${val.toFixed(2)}  | round: spent $${roundSpent.toFixed(2)} ledger value $${roundVal.toFixed(2)}`);
    lines.forEach((l) => console.log(l));
  }
  console.log(`\nFINALIZED rounds: budget share $${tShare.toFixed(2)} vs credited $${tVal.toFixed(2)}`);
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<rpc>')); process.exit(1); });
