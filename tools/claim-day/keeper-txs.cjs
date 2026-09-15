// What the keeper actually sent (last N hours), what funds the Pot, and whether the LP fee stream is reaching it.
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, parseAbi, formatUnits, formatEther, getAddress, keccak256, toHex, pad } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs');
const path = require('path');
const env = fs.readFileSync(path.join(__dirname, '../../.env'), 'utf8');
const RPC = env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim();
const c = createPublicClient({ chain: base, transport: http(RPC, { batch: { batchSize: 25 } }) });
const HOURS = Number(process.env.HOURS || 48);

const KEEPER = '0x6571E3412553Fada40C3D96e61E7Cfd20A0695B9';
const POT = '0x3918a9B479Ce9B58238584c645079AB3bB49855B';
const SPLITTER = '0xb9b76e1835afE05e5A73065FE01A19B14869F8A3';
const SAFE = '0xe1096B727499a3f70FaD8bc0267F5e69d01373C7';
const DISTRIBUTOR = '0x9982538F41f2ae29ddb9d3D9307010052984FDbB';
const POOL_ID = '0xbcdd8383e38069f626846b94e93ee4d2c00cadfcce4b9457b0b8b04289030345';
const NAMES = {
  [POT]: 'Pot', [SPLITTER]: 'FeeSplitter', '0xa8192D4Ee3526CA8158cBE83b2FC05BdC205bed3': 'ChipRounds', [DISTRIBUTOR]: 'BankrDistributor',
  '0x7Bc1C03e843C37845d89B54667382b4577Ead5C0': 'ChipBurner', '0x9bD35c70a80F132d087719305E37A888204d4c80': 'ChipClaims',
  '0x123Bc476594A80B0d99Ca6510e87E249b1C5EC5f': 'NounLoans', [SAFE]: 'Safe', [KEEPER]: 'KEEPER', '0x83FF88220D3C9f63cB23FfAc6C3D726ED36f7173': 'POLTreasury',
  '0x762984092Cb9404982835551970C73b5838d5411': 'ChipActivationV2', '0x93Ac0B6C249c1497429Bc4863C697475DF0Acd4c': 'Anvil', '0x411a505b81546beA83305298c14EF5F8c9b10bA5': 'Furnace',
};
const nm = (a) => (a ? NAMES[getAddress(a)] || a : '?');
const SIGS = ['collectFees(bytes32)', 'convert()', 'convert(uint256)', 'convert(address)', 'convert(address,uint256)', 'distributeETH()', 'distributeAll(address[])',
  'distributeTokens(address[])', 'distributeToken(address)', 'openRound()', 'contributeWeights(uint256,address,uint256[])', 'closeAccumulation(uint256)',
  'settleStock(uint256,address)', 'finalizeRound(uint256)', 'burn()', 'burnAll()', 'burn(uint256)', 'sweepExpired(uint256,address,uint256)', 'sweepExpired(uint256,address)',
  'withdrawEth(address)', 'claimFor(address,uint256,address)'];
const SEL = Object.fromEntries(SIGS.map((s) => [keccak256(toHex(s)).slice(0, 10), s]));

const rpc = async (method, params) => {
  const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(`${method}: ${j.error.message}`);
  return j.result;
};
async function transfers(q) {
  const out = [];
  let pageKey;
  do {
    const r = await rpc('alchemy_getAssetTransfers', [{ ...q, withMetadata: true, excludeZeroValue: false, maxCount: '0x3e8', ...(pageKey ? { pageKey } : {}) }]);
    out.push(...r.transfers);
    pageKey = r.pageKey;
  } while (pageKey && out.length < 5000);
  return out;
}

(async () => {
  const latest = await c.getBlock();
  const now = Number(latest.timestamp);
  const fromBlock = '0x' + (latest.number - BigInt(HOURS * 1800)).toString(16);
  const ago = (iso) => `${((now - Date.parse(iso) / 1000) / 3600).toFixed(1)}h`;

  // ---- keeper's outgoing transactions
  const out = await transfers({ fromAddress: KEEPER, fromBlock, category: ['external'] });
  const uniq = [...new Map(out.map((t) => [t.hash, t])).values()];
  const rows = [];
  for (const t of uniq) {
    const [tx, rcpt] = await Promise.all([c.getTransaction({ hash: t.hash }), c.getTransactionReceipt({ hash: t.hash })]);
    rows.push({ ago: ago(t.metadata.blockTimestamp), nonce: tx.nonce, call: SEL[tx.input.slice(0, 10)] || tx.input.slice(0, 10), to: nm(tx.to), status: rcpt.status,
      gasEth: Number(formatEther(rcpt.gasUsed * rcpt.effectiveGasPrice)) });
  }
  rows.sort((a, b) => b.nonce - a.nonce);
  const agg = {};
  for (const r of rows) { const k = `${r.call} -> ${r.to}`; agg[k] ||= { ok: 0, reverted: 0, lastAgoH: r.ago }; agg[k][r.status === 'success' ? 'ok' : 'reverted']++; }
  console.log(`\n[keeper txs in last ${HOURS}h: ${rows.length}, gas ${rows.reduce((a, r) => a + r.gasEth, 0).toFixed(6)} ETH]`);
  console.table(Object.entries(agg).map(([k, v]) => ({ call: k, ...v })));
  console.log('[most recent 10]'); console.table(rows.slice(0, 10));

  // ---- what flows INTO the Pot and the FeeSplitter, and from whom (7 days)
  const wk = '0x' + (latest.number - BigInt(7 * 86400 * 2)).toString(16);
  for (const [label, addr] of [['Pot', POT], ['FeeSplitter', SPLITTER]]) {
    const inn = await transfers({ toAddress: addr, fromBlock: wk, category: ['external', 'internal', 'erc20'] });
    const g = {};
    for (const t of inn) {
      if (!t.value) continue;
      const k = `${t.asset || t.rawContract?.address} from ${nm(t.from)}`;
      g[k] ||= { n: 0, total: 0, lastAgoH: ago(t.metadata.blockTimestamp) };
      g[k].n++; g[k].total += Number(t.value); g[k].lastAgoH = ago(t.metadata.blockTimestamp);
    }
    console.log(`\n[INTO ${label}, last 7d]`);
    console.table(Object.entries(g).map(([k, v]) => ({ flow: k, count: v.n, total: v.total.toFixed(6), lastAgoH: v.lastAgoH })));
  }

  // ---- LP fee stream: what is accrued, and who holds shares
  const DIST = parseAbi(['function collectFees(bytes32) returns (uint256, uint256)', 'function getShares(bytes32, address) view returns (uint256)']);
  try {
    const { result } = await c.simulateContract({ address: DISTRIBUTOR, abi: DIST, functionName: 'collectFees', args: [POOL_ID], account: KEEPER });
    console.log(`\n[Bankr collectFees simulated return] fees0(WETH) ${formatEther(result[0])}  fees1(CHIP) ${formatEther(result[1])}`);
  } catch (e) { console.log('collectFees sim:', e.shortMessage); }
  for (const who of [SPLITTER, SAFE, KEEPER, POT]) {
    const s = await c.readContract({ address: DISTRIBUTOR, abi: DIST, functionName: 'getShares', args: [POOL_ID, who] }).catch((e) => `ERR ${e.shortMessage}`);
    console.log(`  getShares(${nm(who)}) = ${typeof s === 'bigint' ? `${s} (${(Number(s) / 1e16).toFixed(2)}%)` : s}`);
  }
  const wethDist = await c.readContract({ address: '0x4200000000000000000000000000000000000006', abi: parseAbi(['function balanceOf(address) view returns (uint256)']), functionName: 'balanceOf', args: [DISTRIBUTOR] });
  console.log(`  WETH held by distributor ${formatEther(wethDist)}`);
})().catch((e) => { console.error(String(e.shortMessage || e.message).replace(/https:\/\/\S+/g, '<url>')); process.exit(1); });
