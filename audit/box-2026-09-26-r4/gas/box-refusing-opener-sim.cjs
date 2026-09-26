// The Box's WORST callback on a real node: an opener that the real B20s and USDC refuse.
//
// Audit round 3 (Grok, mainnet gate 1) asked for the worst case measured on real B20s, not
// estimated from mocks: a refusing recipient, every registered stock listed, the Pyth callback.
// B20 policies block sanctioned addresses, and so does Circle's USDC, so an OFAC-listed address
// as opener makes every stock transfer AND the USDC fallback revert. The walk then does the most
// expensive thing it can: price every stock, try two real refused transfers, try USDC, go OWED.
//
// Nothing is signed or sent: eth_simulateV1, validation off, the opener's ETH is a state override.
// The address is only a recipient that the tokens refuse; no call is made on its behalf beyond
// the simulated open.
//
//   forge build && node tools/box/box-refusing-opener-sim.cjs
const { createRequire } = require('module');
const path = require('path');
const fs = require('fs');
const ROOT = path.join(__dirname, '../..');
// viem from wherever it is installed: this repo has no node_modules of its own.
const req = createRequire(process.env.VIEM_FROM || 'C:/Users/1136962520/chipworks/package.json');
const {
  encodeFunctionData, decodeFunctionResult, decodeErrorResult, encodeDeployData, parseAbi,
  getContractAddress, keccak256, encodeAbiParameters, pad, toHex,
} = req('viem');

const env = fs.readFileSync(path.join(ROOT, '.env'), 'utf8');
const RPC = env.match(/^BASE_RPC_URL=(.*)$/m)[1].trim();
const art = (name) => JSON.parse(fs.readFileSync(path.join(ROOT, `out/${name}.sol/${name}.json`), 'utf8'));
const VAULT_ART = art('PrizeVault');
const CONV_ART = art('ChipConverter');
const BOX_ART = art('Box');

const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const CHIP = '0x75Af968d2e58749FDA1b42C58186B76f5E511bA3';
const WETH = '0x4200000000000000000000000000000000000006';
const ENTROPY = '0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb';
const FEE_SPLITTER = '0xb9b76e1835afE05e5A73065FE01A19B14869F8A3';
const REGISTRY = '0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458';
const UNI_ROUTER = '0x2626664c2603336E57B271c5C0b26F421741e481';
const SLIP_ROUTER_B = '0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F';
const POOL_MANAGER = '0x498581fF718922c3f8e6A244956aF099B2652b2b';
const CHIP_HOOK = '0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544';
const ME = '0x00000000000000000000000000000000b0c50001';
// OFAC SDN (Lazarus Group). A plain B20 transfer to it reverts on Base (30,190 gas vs 59,046 OK).
const REFUSED = '0x098B716B8Aaf21512996dC57EB0615e2383E2f96';
const USDC_BALANCE_SLOT = 9n;

const ERC20 = parseAbi(['function balanceOf(address) view returns (uint256)', 'function approve(address,uint256) returns (bool)', 'function transfer(address,uint256) returns (bool)']);
const ERC721 = parseAbi(['function transferFrom(address,address,uint256)']);
const REG = parseAbi(['function allTokens() view returns (address[])']);
const ENT = parseAbi(['function getDefaultProvider() view returns (address)', 'function getFeeV2(uint32) view returns (uint128)']);
const VAULT_LOGS = parseAbi(['event StockSkipped(address indexed token, bytes32 indexed reason)']);

const hex = (n) => '0x' + BigInt(n).toString(16);
const rpc = async (method, params) => {
  const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(JSON.stringify(j.error));
  return j.result;
};
const read = async (to, abi, functionName, args = []) =>
  decodeFunctionResult({ abi, functionName, data: await rpc('eth_call', [{ to, data: encodeFunctionData({ abi, functionName, args }) }, 'latest']) });
const why = (c) => errName((c.error && c.error.data) || c.returnData);
const errName = (data) => {
  if (!data || data === '0x') return '(no data)';
  for (const abi of [BOX_ART.abi, VAULT_ART.abi]) {
    try { const e = decodeErrorResult({ abi, data }); return `${e.errorName}(${(e.args || []).join(',')})`; } catch {}
  }
  return data.slice(0, 10);
};
const call = (from, to, abi, functionName, args = [], value = 0n) => ({ from, to, data: encodeFunctionData({ abi, functionName, args }), value: hex(value) });
const deploy = (from, a, args) => ({ from, data: encodeDeployData({ abi: a.abi, bytecode: a.bytecode.object, args }) });

async function simulate(calls) {
  const block = BigInt(await rpc('eth_blockNumber', []));
  const usdcSlot = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [ME, USDC_BALANCE_SLOT]));
  const [res] = await rpc('eth_simulateV1', [{
    blockStateCalls: [{
      stateOverrides: {
        [ME]: { balance: hex(10n ** 20n) },
        [REFUSED]: { balance: hex(10n ** 18n) }, // gas money for the simulated open only
        [USDC]: { stateDiff: { [usdcSlot]: pad(toHex(1_000_000n * 10n ** 6n), { size: 32 }) } },
      },
      calls,
    }],
    validation: false,
  }, hex(block)]);
  return { block, calls: res.calls };
}

(async () => {
  const vault = getContractAddress({ from: ME, nonce: 0n });
  const conv = getContractAddress({ from: ME, nonce: 1n });
  const box = getContractAddress({ from: ME, nonce: 2n });
  const stocks = (await read(REGISTRY, REG, 'allTokens')).filter((t) => t.toLowerCase() !== CHIP.toLowerCase());
  const n = BigInt(stocks.length);
  const provider = await read(ENTROPY, ENT, 'getDefaultProvider');
  const fee = await read(ENTROPY, ENT, 'getFeeV2', [1_000_000]);

  const key = { currency0: WETH, currency1: CHIP, fee: 0x800000, tickSpacing: 200, hooks: CHIP_HOOK };
  const setup = [
    deploy(ME, VAULT_ART, [ME, USDC, CHIP, REGISTRY, UNI_ROUTER, SLIP_ROUTER_B, 2_500]),
    deploy(ME, CONV_ART, [ME, CHIP, WETH, USDC, POOL_MANAGER, UNI_ROUTER, 500, key]),
    deploy(ME, BOX_ART, [ME, USDC, CHIP, FEE_SPLITTER, vault, conv, ENTROPY]),
    call(ME, vault, VAULT_ART.abi, 'setBox', [box]),
    call(ME, conv, CONV_ART.abi, 'setBox', [box]),
    ...stocks.map((t) => call(ME, vault, VAULT_ART.abi, 'addStock', [t])),
    call(ME, vault, VAULT_ART.abi, 'setKeeper', [ME]),
    call(ME, vault, VAULT_ART.abi, 'setRestockParams', [5_000n * 10n ** 6n, 50_000n * 10n ** 6n, 500, 2_500]),
    call(ME, USDC, ERC20, 'transfer', [vault, 20_000n * 10n ** 6n]),
  ];
  // Fund EVERY stock we can buy ($400 each through its real venue), so the walk meets real,
  // funded, refusing stocks. Some venues may fail; a stock left empty is a free skip.
  const restocks = stocks.map((t) => call(ME, vault, VAULT_ART.abi, 'restock', [t, 400n * 10n ** 6n]));
  const buyOpen = [
    call(ME, USDC, ERC20, 'approve', [box, 100n * 10n ** 6n]),
    call(ME, box, BOX_ART.abi, 'buyWithUsdc', [1, ME]), // $10
    call(ME, box, ERC721, 'transferFrom', [ME, REFUSED, 1n]), // a gift: the refused address opens it
    call(REFUSED, box, BOX_ART.abi, 'open', [1n], fee),
    call(ME, box, BOX_ART.abi, 'boxInfo', [1n]),
  ];

  const p1 = await simulate([...setup, ...restocks, ...buyOpen]);
  const res = p1.calls;
  res.slice(0, setup.length).forEach((c, i) => { if (c.status !== '0x1') throw new Error(`setup ${i} reverted: ${errName(c.returnData)}`); });
  const funded = [];
  res.slice(setup.length, setup.length + restocks.length).forEach((c, i) => { if (c.status === '0x1') funded.push(i); });
  const bo = res.slice(setup.length + restocks.length);
  bo.forEach((c, i) => { if (c.status !== '0x1') throw new Error(`buy/open ${i} reverted: ${errName(c.returnData)}`); });
  const seq = decodeFunctionResult({ abi: BOX_ART.abi, functionName: 'boxInfo', data: bo[4].returnData }).sequence;
  if (funded.length < 2) throw new Error(`only ${funded.length} stocks could be funded; need 2 refusals`);

  // Tier 2 ($10 on the $10 SKU) roll whose hashed walk starts on the first funded stock.
  const startOf = (r) => BigInt(keccak256(encodeAbiParameters([{ type: 'bytes32' }], [pad(toHex(r), { size: 32 })]))) % n;
  let roll = 7500n;
  while (startOf(roll) !== BigInt(funded[0])) roll += 10_000n;

  const tail = [
    call(ME, USDC, ERC20, 'transfer', [REFUSED, 1n]), // does Circle refuse it too?
    call(ENTROPY, box, BOX_ART.abi, '_entropyCallback', [seq, provider, pad(toHex(roll), { size: 32 })]),
    call(ME, box, BOX_ART.abi, 'boxInfo', [1n]),
    call(ME, box, BOX_ART.abi, 'claimOwed', [1n]), // the uncapped walk: every funded stock, then USDC
    call(ME, box, BOX_ART.abi, 'callbackGasLimit'),
  ];
  const p2 = await simulate([...setup, ...restocks, ...buyOpen, ...tail]);
  const t = p2.calls.slice(-tail.length);
  const cb = t[1];
  const state = decodeFunctionResult({ abi: BOX_ART.abi, functionName: 'boxInfo', data: t[2].returnData }).state;
  const limit = decodeFunctionResult({ abi: BOX_ART.abi, functionName: 'callbackGasLimit', data: t[4].returnData });
  const refusals = (cb.logs || []).filter((l) => l.topics[0] === keccak256(new TextEncoder().encode('StockSkipped(address,bytes32)'))
    && l.topics[2] === pad(toHex(new TextEncoder().encode('transfer')), { size: 32, dir: 'right' })).length;

  console.log(`block ${p2.block}; ${stocks.length} registered stocks listed; ${funded.length} funded by real restocks; opener ${REFUSED}`);
  console.log(`USDC transfer to the opener: ${t[0].status === '0x1' ? 'ACCEPTED' : 'REFUSED'}`);
  console.log(`callback (walk starts on a funded stock): ${cb.status === '0x1' ? 'ok' : 'REVERTED ' + why(cb)}  gas ${BigInt(cb.gasUsed)}  refused transfers ${refusals}  state ${state} (3 = OWED)`);
  console.log(`claimOwed (uncapped walk, ${funded.length} funded refusals + USDC): ${t[3].status === '0x1' ? 'paid' : 'reverted ' + why(t[3])}  gas ${BigInt(t[3].gasUsed)}`);
  console.log(`callbackGasLimit ${limit}; per extra listed stock (committed sim slope) ~33.1k -> at MAX_STOCKS = 16: ~${BigInt(cb.gasUsed) + BigInt(16 - stocks.length) * 33_100n}`);
  const problems = [];
  if (cb.status !== '0x1') problems.push('callback reverted');
  if (BigInt(cb.gasUsed) >= 900_000n) problems.push('callback gas >= the 900k floor');
  if (BigInt(cb.gasUsed) + BigInt(16 - stocks.length) * 33_100n >= 900_000n) problems.push('16-stock extrapolation >= 900k');
  if (problems.length) { console.log('\nPROBLEMS:\n  ' + problems.join('\n  ')); process.exit(1); }
  console.log('\nOK: the refusing-opener worst case fits under the 900k floor on real B20s.');
})().catch((e) => { console.error(e); process.exit(1); });
