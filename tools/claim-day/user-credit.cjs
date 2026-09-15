// One wallet's credit, straight from ChipClaims, at the latest block and at earlier ones.
// Usage: OWNER=0x... [HOURS=0,3,6,12,24] node user-credit.cjs
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, formatUnits, getAddress } = req('viem');
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
const REG = parseAbi(['function allTokens() view returns (address[])', 'function priceUsd(address) view returns (uint256, uint256)']);
const ERC20 = parseAbi(['function decimals() view returns (uint8)', 'function symbol() view returns (string)']);
const OWNER = getAddress(process.env.OWNER);
const HOURS = (process.env.HOURS || '0,3,6,12,24').split(',').map(Number);

const c = createPublicClient({ chain: base, transport: http(RPC, { batch: { batchSize: 50 } }) });

(async () => {
  const latest = await c.getBlock();
  const USDC = getAddress(await c.readContract({ address: CLAIMS, abi: CLAIMS_ABI, functionName: 'quoteToken' }));
  const meta = {};
  for (const h of HOURS) {
    const blockNumber = latest.number - BigInt(h * 1800);
    const at = { blockNumber };
    const blk = await c.getBlock(at);
    const rc = (address, abi, functionName, args = []) => c.readContract({ address, abi, functionName, args, ...at });
    const roundCount = Number(await rc(ROUNDS, ROUNDS_ABI, 'roundCount'));
    const tokens = new Set([USDC]);
    (await rc(REGISTRY, REG, 'allTokens')).forEach((t) => tokens.add(getAddress(t)));
    let totalUsd = 0;
    const rows = [];
    for (let r = 1; r <= roundCount; r++) {
      const [round, fin] = await Promise.all([rc(ROUNDS, ROUNDS_ABI, 'getRound', [BigInt(r)]), rc(CLAIMS, CLAIMS_ABI, 'isFinalized', [BigInt(r)])]);
      for (const t of tokens) {
        const [cla, w, hc, tw, acq] = await Promise.all([
          rc(CLAIMS, CLAIMS_ABI, 'claimable', [BigInt(r), t, OWNER]), rc(CLAIMS, CLAIMS_ABI, 'weightOf', [BigInt(r), t, OWNER]),
          rc(CLAIMS, CLAIMS_ABI, 'hasClaimed', [BigInt(r), t, OWNER]), rc(CLAIMS, CLAIMS_ABI, 'totalWeight', [BigInt(r), t]),
          rc(CLAIMS, CLAIMS_ABI, 'acquired', [BigInt(r), t]),
        ]);
        if (w === 0n && cla === 0n && !hc) continue;
        if (!meta[t]) {
          meta[t] = { sym: await c.readContract({ address: t, abi: ERC20, functionName: 'symbol' }).catch(() => '?'),
            dec: await c.readContract({ address: t, abi: ERC20, functionName: 'decimals' }).catch(() => null) };
        }
        let price = null, updatedAt = null, perr = null;
        if (t === USDC) price = 1;
        else {
          try { const [p, u] = await rc(REGISTRY, REG, 'priceUsd', [t]); price = Number(p) / 1e18; updatedAt = Number(u); } catch (e) { perr = e.shortMessage || e.message; }
        }
        const amt = meta[t].dec == null ? null : Number(formatUnits(cla, meta[t].dec));
        const usd = amt != null && price != null ? amt * price : 0;
        totalUsd += usd;
        rows.push({ round: r, state: ['None', 'Accum', 'Buying', 'Final'][round.state], ledgerFinal: fin, sym: meta[t].sym, dec: meta[t].dec,
          weight: w.toString(), shareOfStock: tw ? (Number(w) / Number(tw)).toFixed(4) : '-', acquired: acq.toString(), claimable: cla.toString(),
          amount: amt, price, priceAgeH: updatedAt ? ((Number(blk.timestamp) - updatedAt) / 3600).toFixed(1) : null, perr, usd: usd.toFixed(2), hasClaimed: hc });
      }
    }
    console.log(`\n=== ${h}h ago: block ${blockNumber} ${new Date(Number(blk.timestamp) * 1000).toISOString()}  rounds=${roundCount}  TOTAL claimable USD = $${totalUsd.toFixed(2)}`);
    console.table(rows);
  }
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<rpc>')); process.exit(1); });
