// The Box against REAL B20 stocks, via eth_simulateV1 on the live Base node.
//
// test/fork/BoxFork.t.sol proves the Box on live Base, but B20 stocks are node precompiles
// that cannot execute in a forge fork, so NVDA is etched there and the Pyth callback's gas is
// measured with an ordinary ERC-20 transfer inside it. This closes that gap on a real node:
//
//   deploy PrizeVault / ChipConverter / Box  ->  wire, list every enabled registry stock
//   -> the keeper restocks NVDA from vault USDC through the real Slipstream pool (real B20 in)
//   -> a buyer buys a $10 box with USDC and opens it through the real Pyth Entropy
//   -> the reveal is delivered as Entropy, twice over (two boxes):
//        best case:  the stock walk starts on NVDA and pays at once
//        worst case: the walk starts on an EMPTY stock and skips every other one first
//   and each callback's gasUsed is checked against Box.callbackGasLimit.
//
// Nothing is signed or sent. Run `forge build` first: bytecode is read from out/.
//
//   node tools/box/box-callback-sim.cjs
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const {
  encodeFunctionData, decodeFunctionResult, decodeErrorResult, encodeDeployData, parseAbi,
  getContractAddress, keccak256, encodeAbiParameters, pad, toHex,
} = req('viem');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '../..');
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
const NVDA = '0xb20000000000000000000078ee7ce2fE4908108C';
// A fresh address: owner, keeper and buyer at once. Nothing is ever signed for it.
const ME = '0x00000000000000000000000000000000B0c50001';
const USDC_BALANCE_SLOT = 9n; // FiatToken balanceAndBlacklistStates

const ERC20 = parseAbi(['function balanceOf(address) view returns (uint256)', 'function approve(address,uint256) returns (bool)', 'function transfer(address,uint256) returns (bool)']);
const REG = parseAbi(['function enabledTokens() view returns (address[])', 'function allTokens() view returns (address[])']);
const ENT = parseAbi(['function getDefaultProvider() view returns (address)', 'function getFeeV2(uint32) view returns (uint128)']);

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
  if (!data || data === '0x') return '(no data)';
  for (const abi of [BOX_ART.abi, VAULT_ART.abi, CONV_ART.abi]) {
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
  // STOCKS=all lists every REGISTERED stock (the vault accepts registered, not only enabled),
  // to measure the callback with as many real B20s as exist.
  const which = process.env.STOCKS === 'all' ? 'allTokens' : 'enabledTokens';
  const stocks = (await read(REGISTRY, REG, which)).filter((t) => t.toLowerCase() !== CHIP.toLowerCase());
  const provider = await read(ENTROPY, ENT, 'getDefaultProvider');
  const fee = await read(ENTROPY, ENT, 'getFeeV2', [1_000_000]); // Box.callbackGasLimit
  const nvdaIdx = stocks.findIndex((t) => t.toLowerCase() === NVDA.toLowerCase());
  if (nvdaIdx < 0) throw new Error('NVDA is not enabled in the registry');
  const n = BigInt(stocks.length);

  // Rolls 7500..8999 are all Uncommon ($10). Step through them until `roll % n` lands where we
  // want the stock walk to start (n <= 16, so this is reached within 16 steps).
  const rollStartingAt = (idx) => {
    for (let r = 7500n; r < 9000n; r++) if (r % n === BigInt(idx)) return r;
    throw new Error('no Uncommon roll starts the walk at ' + idx);
  };
  const best = rollStartingAt(nvdaIdx);
  const worst = rollStartingAt((nvdaIdx + 1) % stocks.length); // walks every other stock before NVDA

  const key = { currency0: WETH, currency1: CHIP, fee: 0x800000, tickSpacing: 200, hooks: CHIP_HOOK };
  const pre = [
    deploy(ME, VAULT_ART, [ME, USDC, CHIP, REGISTRY, UNI_ROUTER, SLIP_ROUTER_B, 2_500]),
    deploy(ME, CONV_ART, [ME, CHIP, WETH, USDC, POOL_MANAGER, UNI_ROUTER, 500, key]),
    deploy(ME, BOX_ART, [ME, USDC, CHIP, FEE_SPLITTER, vault, conv, ENTROPY]),
    call(ME, vault, VAULT_ART.abi, 'setBox', [box]),
    call(ME, conv, CONV_ART.abi, 'setBox', [box]),
    ...stocks.map((t) => call(ME, vault, VAULT_ART.abi, 'addStock', [t])),
    call(ME, vault, VAULT_ART.abi, 'setKeeper', [ME]),
    call(ME, vault, VAULT_ART.abi, 'setRestockParams', [5_000n * 10n ** 6n, 50_000n * 10n ** 6n, 200, 3_000]),
    call(ME, USDC, ERC20, 'transfer', [vault, 5_000n * 10n ** 6n]),
    call(ME, vault, VAULT_ART.abi, 'restock', [NVDA, 1_000n * 10n ** 6n]),
    call(ME, USDC, ERC20, 'approve', [box, 100n * 10n ** 6n]),
    call(ME, box, BOX_ART.abi, 'buyWithUsdc', [1, ME]),
    call(ME, box, BOX_ART.abi, 'buyWithUsdc', [1, ME]),
    call(ME, box, BOX_ART.abi, 'open', [1n], fee),
    call(ME, box, BOX_ART.abi, 'open', [2n], fee),
    call(ME, box, BOX_ART.abi, 'boxInfo', [1n]),
    call(ME, box, BOX_ART.abi, 'boxInfo', [2n]),
  ];

  // Pass 1: everything up to the opens, to learn the sequences Entropy assigns.
  const p1 = await simulate(pre);
  p1.calls.forEach((c, i) => { if (c.status !== '0x1') throw new Error(`setup call ${i} reverted: ${errName(c.returnData)}`); });
  const seqOf = (c) => decodeFunctionResult({ abi: BOX_ART.abi, functionName: 'boxInfo', data: c.returnData }).sequence;
  const seq1 = seqOf(p1.calls[pre.length - 2]);
  const seq2 = seqOf(p1.calls[pre.length - 1]);

  // Pass 2: the same, plus both reveals delivered as Entropy, plus the balances after.
  const tail = [
    call(ME, NVDA, ERC20, 'balanceOf', [ME]),
    call(ENTROPY, box, BOX_ART.abi, '_entropyCallback', [seq1, provider, pad(toHex(best), { size: 32 })]),
    call(ME, NVDA, ERC20, 'balanceOf', [ME]),
    call(ENTROPY, box, BOX_ART.abi, '_entropyCallback', [seq2, provider, pad(toHex(worst), { size: 32 })]),
    call(ME, NVDA, ERC20, 'balanceOf', [ME]),
    call(ME, box, BOX_ART.abi, 'outstandingLiabilityUsd'),
    call(ME, box, BOX_ART.abi, 'callbackGasLimit'),
    call(ME, vault, VAULT_ART.abi, 'inventoryUsd'),
    // Gas breakdown: what one stock costs to look at, and what the whole-pool read costs.
    call(ME, NVDA, ERC20, 'balanceOf', [vault]),
    call(ME, REGISTRY, parseAbi(['function priceUsd(address) view returns (uint256,uint256)']), 'priceUsd', [NVDA]),
    call(ME, vault, VAULT_ART.abi, 'prizeCapUsd'),
  ];
  const p2 = await simulate([...pre, ...tail]);
  const r = p2.calls.slice(pre.length);
  const restock = p2.calls[pre.length - 8];
  const u = (c, abi, fn) => decodeFunctionResult({ abi, functionName: fn, data: c.returnData });
  const bal = (c) => u(c, ERC20, 'balanceOf');

  console.log(`block ${p2.block}; ${stocks.length} ${which === 'allTokens' ? 'registered' : 'enabled'} registry stocks listed; NVDA is #${nvdaIdx}`);
  console.log(`restock $1,000 -> NVDA: ${restock.status === '0x1' ? 'ok' : 'REVERTED ' + errName(restock.returnData)}, gas ${BigInt(restock.gasUsed)}`);
  const limit = u(r[6], BOX_ART.abi, 'callbackGasLimit');
  const problems = [];
  for (const [label, cb, before, after] of [['best  (NVDA first)', r[1], r[0], r[2]], ['worst (skip all)  ', r[3], r[2], r[4]]]) {
    const gas = BigInt(cb.gasUsed);
    const won = bal(after) - bal(before);
    console.log(`callback ${label}: ${cb.status === '0x1' ? 'ok' : 'REVERTED ' + errName(cb.returnData)}  gas ${gas}  NVDA won ${won} (8dp)`);
    if (cb.status !== '0x1') problems.push(`${label} callback reverted`);
    if (won === 0n) problems.push(`${label}: no NVDA paid`);
    if (gas >= BigInt(limit)) problems.push(`${label}: gas ${gas} >= callbackGasLimit ${limit}`);
  }
  const g = (c) => BigInt(c.gasUsed) - 21_000n; // less the intrinsic cost of a top-level tx
  console.log(`breakdown (execution gas, 21k intrinsic removed): B20 balanceOf ${g(r[8])}, registry.priceUsd ${g(r[9])}, vault.inventoryUsd ${g(r[7])}, vault.prizeCapUsd ${g(r[10])}`);
  const buy = p2.calls[pre.length - 6];
  const open = p2.calls[pre.length - 4];
  console.log(`buyWithUsdc gas ${BigInt(buy.gasUsed)} (includes the sell-gate read), open gas ${BigInt(open.gasUsed)}`);
  console.log(`callbackGasLimit ${limit}; liability after ${u(r[5], BOX_ART.abi, 'outstandingLiabilityUsd')}; vault inventory $${u(r[7], VAULT_ART.abi, 'inventoryUsd') / 10n ** 6n}`);
  if (problems.length) { console.log('\nPROBLEMS:\n  ' + problems.join('\n  ')); process.exit(1); }
  console.log('\nOK: real B20 transfers inside the callback fit the gas limit on both paths.');
})().catch((e) => { console.error(e); process.exit(1); });
