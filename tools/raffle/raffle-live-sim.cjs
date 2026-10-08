// Real-B20 proof for the Raffle, on the LIVE Base node via eth_simulateV1 (nothing is sent).
// Forge forks cannot execute B20 stocks, so this is where real NVDAc moves:
//   block 1: deploy Raffle (owner = ChipWorks' Box PrizeVault, which holds real NVDAc),
//            vault approves + createRaffle with a REAL NVDAc prize and the real Entropy reserve,
//            two buyers (USDC via state override) buy out the raffle -> REAL Entropy requestV2
//   block 2: the reveal delivered AS Entropy, settle, then balances read back
// Run after `forge build`:  node tools/raffle/raffle-live-sim.cjs
const { createRequire } = require('module');
const req = createRequire('C:/Users/1136962520/chipworks/package.json');
const { createPublicClient, http, encodeFunctionData, encodeDeployData, decodeFunctionResult, getContractAddress, keccak256, encodeAbiParameters, pad, toHex, parseAbi, formatUnits } = req('viem');
const { base } = req('viem/chains');
const fs = require('fs'), path = require('path');
const ROOT = path.resolve(__dirname, '../..');
const RPC = fs.readFileSync(path.join(ROOT, '.env'), 'utf8').match(/^BASE_RPC_URL=(.*)$/m)[1].trim();
const art = JSON.parse(fs.readFileSync(path.join(ROOT, 'out/Raffle.sol/Raffle.json'), 'utf8'));
const c = createPublicClient({ chain: base, transport: http(RPC) });

const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', ENTROPY = '0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb';
const REGISTRY = '0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458', POT = '0x3918a9B479Ce9B58238584c645079AB3bB49855B';
const NVDA = '0xb20000000000000000000078ee7ce2fE4908108C', VAULT = '0x4e4Ca928b973d13434f315611edC6ea250d3f070';
const DEPLOYER = '0x00000000000000000000000000000000dEb10Ae1', B1 = '0x00000000000000000000000000000000000B0001', B2 = '0x00000000000000000000000000000000000B0002';
const RAFFLE = getContractAddress({ from: DEPLOYER, nonce: 0n });
const E20 = parseAbi(['function approve(address,uint256) returns (bool)', 'function balanceOf(address) view returns (uint256)']);
const usdcSlot = (who) => keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [who, 9n]));

(async () => {
  const blockNumber = await c.getBlockNumber(); // pin both passes to one block
  const vaultNvda = await c.readContract({ address: NVDA, abi: E20, functionName: 'balanceOf', args: [VAULT], blockNumber });
  const prize = vaultNvda / 4n;
  if (prize === 0n) throw new Error('the vault holds no NVDAc to use as a prize');
  const call = (from, to, fn, args, value) => ({ from, to, data: encodeFunctionData({ abi: to === RAFFLE ? art.abi : E20, functionName: fn, args }), ...(value ? { value: toHex(value) } : {}) });
  const view = (to, fn, args, abi) => ({ from: DEPLOYER, to, data: encodeFunctionData({ abi: abi ?? (to === RAFFLE ? art.abi : E20), functionName: fn, args }) });
  const deploy = { from: DEPLOYER, data: encodeDeployData({ abi: art.abi, bytecode: art.bytecode.object, args: [VAULT, USDC, ENTROPY, REGISTRY, POT, 3600n] }) };
  const overrides = {
    [DEPLOYER]: { balance: toHex(10n ** 18n), nonce: '0x0' },
    [VAULT]: { balance: toHex(10n ** 18n) },
    [USDC]: { stateDiff: { [usdcSlot(B1)]: pad(toHex(1_000n * 10n ** 6n)), [usdcSlot(B2)]: pad(toHex(1_000n * 10n ** 6n)) } }, // map, not array
  };
  const block1 = (reserve) => ({ stateOverrides: overrides, calls: [
    deploy,
    call(VAULT, NVDA, 'approve', [RAFFLE, prize]),
    call(VAULT, RAFFLE, 'createRaffle', [{ kind: 0, token: NVDA, amountOrId: prize }, 100n, VAULT], reserve),
    call(B1, USDC, 'approve', [RAFFLE, 10n ** 12n]),
    call(B2, USDC, 'approve', [RAFFLE, 10n ** 12n]),
    call(B1, RAFFLE, 'buy', [1n, 50n]),
    call(B2, RAFFLE, 'buy', [1n, 60n]), // ticket 110 of 110 -> real Entropy request
    view(RAFFLE, 'getRaffle', [1n]),
  ] });
  const sim = async (blocks) => (await c.request({ method: 'eth_simulateV1', params: [{ blockStateCalls: blocks, validation: false }, toHex(blockNumber)] }));

  // Pass 1: learn the live reserve requirement and the sequence Entropy assigns.
  const q = await sim([{ stateOverrides: overrides, calls: [deploy, view(RAFFLE, 'requiredReserve', [])] }]);
  const reserve = decodeFunctionResult({ abi: art.abi, functionName: 'requiredReserve', data: q[0].calls[1].returnData });
  const p1 = await sim([block1(reserve)]);
  p1[0].calls.forEach((x, i) => { if (x.status !== '0x1') throw new Error(`block1 call ${i} reverted: ${x.error?.message ?? x.returnData}`); });
  const r1 = decodeFunctionResult({ abi: art.abi, functionName: 'getRaffle', data: p1[0].calls[7].returnData });
  console.log(`block ${blockNumber} | Raffle at ${RAFFLE} | prize ${formatUnits(prize, 8)} REAL NVDAc from the Box vault | reserve ${reserve} wei`);
  console.log(`buy-out OK -> state ${r1.state} (3 = Drawing) | REAL Entropy sequence ${r1.sequence} from provider ${r1.provider} | reserve left ${r1.ethReserve}`);

  // Pass 2: same block 1, then the reveal (as Entropy), settle, and the balances.
  const rnd = BigInt(110 * 1_000_003 + 77); // lands on ticket 77 -> B2 (tickets 50..109)
  const p2 = await sim([block1(reserve), { calls: [
    view(NVDA, 'balanceOf', [B2]), view(USDC, 'balanceOf', [POT]), view(USDC, 'balanceOf', [VAULT]),
    { from: ENTROPY, to: RAFFLE, data: encodeFunctionData({ abi: art.abi, functionName: '_entropyCallback', args: [r1.sequence, r1.provider, pad(toHex(rnd))] }) },
    call(B1, RAFFLE, 'settle', [1n]),
    view(NVDA, 'balanceOf', [B2]), view(USDC, 'balanceOf', [POT]), view(USDC, 'balanceOf', [VAULT]),
    view(NVDA, 'balanceOf', [RAFFLE]), view(USDC, 'balanceOf', [RAFFLE]), view(RAFFLE, 'getRaffle', [1n]),
  ] }]);
  const b2 = p2[1].calls;
  b2.forEach((x, i) => { if (x.status !== '0x1') throw new Error(`block2 call ${i} reverted: ${x.error?.message ?? x.returnData}`); });
  const n = (i) => decodeFunctionResult({ abi: E20, functionName: 'balanceOf', data: b2[i].returnData });
  const r2 = decodeFunctionResult({ abi: art.abi, functionName: 'getRaffle', data: b2[10].returnData });
  const ok = (cond, msg) => { console.log(`${cond ? 'ok  ' : 'FAIL'} ${msg}`); if (!cond) process.exitCode = 1; };
  ok(r2.state === 5 && r2.winner.toLowerCase() === B2.toLowerCase() && r2.winningTicket === 77n, `settled: winning ticket ${r2.winningTicket}, winner ${r2.winner}`);
  ok(n(5) - n(0) === prize, `winner received ${formatUnits(n(5) - n(0), 8)} REAL NVDAc (B20 transfer out of the raffle)`);
  ok(n(6) - n(1) === 10n * 10n ** 6n, `Pot received ${formatUnits(n(6) - n(1), 6)} USDC (fee tickets)`);
  ok(n(7) - n(2) === 100n * 10n ** 6n, `payee received ${formatUnits(n(7) - n(2), 6)} USDC (base)`);
  ok(n(8) === 0n && n(9) === 0n, 'raffle holds no NVDAc and no USDC afterwards');
})().catch((e) => { console.error(e.message ?? e); process.exit(1); });
