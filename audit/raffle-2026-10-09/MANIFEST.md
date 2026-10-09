# Manifest

SHA-256 over the exact file bytes (UTF-8, LF). Source commit `7b81f9c19c2ae8974f052685413fd95c8a302c7c`.

Repo-path mapping for copies: `contracts/Raffle.sol` = `src/raffle/Raffle.sol`; `contracts/interfaces/IEntropyV2.sol` = `src/interfaces/IEntropyV2.sol`; `contracts/interfaces/IStockRegistry.sol` = `src/interfaces/IStockRegistry.sol`; `script/DeployRaffle.s.sol` = `script/raffle/DeployRaffle.s.sol`; `SPEC.md` = `specs/raffle/SPEC.md`; `tools/mutation.py` = `tools/raffle/mutation.py`; `tools/raffle-live-sim.cjs` = `tools/raffle/raffle-live-sim.cjs`; `tests/*` = `test/raffle/*`, `tests/fork/*` = `test/fork/*`, `tests/mocks/*` = `test/mocks/*`.

| file | lines | sha256 | last non-empty line |
|---|---|---|---|
| .gitattributes | 1 | 705fd4d6451a31d36b3df7de96f83f30ac976c9b4a6d1e51671d8e2f33e2d0da | `* -text` |
| AUDIT_BRIEF.md | 96 | 382fec38225f99cb795dfd9796cb0ad6a6976c8541902a0357cfb9f49627eb3e | `Internal only: unit, fuzz, invariant, fork, live-node simulation and m` |
| contracts/interfaces/IEntropyV2.sol | 45 | cf8a572edab4c0e68297bbe0dbad62aa3038ecdac345085268e83e5fd1332944 | `}` |
| contracts/interfaces/IStockRegistry.sol | 47 | e940cf4508f11c6338ce0ec8667657ede4099903bfdb240f74f43db1ff96213a | `}` |
| contracts/Raffle.sol | 702 | d81757d1db57376325fe2164b1d9b39394974565529b8325b2a44e987a4821b4 | `}` |
| KEEPER.md | 29 | 529effe1f67fd8a018501abd9d572abec42f390e87f23f3d9098588c4b5d60b5 | `The same Revealed-event fallback was ported to the live Box keeper on ` |
| logs/01-unit.log | 50 | 5a130d22177870955c0c5c2f39ad3a07e5fb85462e9b79d535cc3ba92ab196eb | `Ran 1 test suite in 827.23ms (799.40ms CPU time): 37 tests passed, 0 f` |
| logs/02-invariant.log | 128 | b7cf21f85ae658b396f4422ba7315ee6b3d8cf6548b4b72f052978b53c9b2e42 | `Ran 1 test suite in 21.36s (21.35s CPU time): 5 tests passed, 0 failed` |
| logs/03-fork-and-launch-config.log | 19 | 61f139ef1189e1108b20c8ae8e4b11842d839b58f517b094a72a0742a6f48c1c | `Ran 2 test suites in 7.85s (10.64s CPU time): 4 tests passed, 0 failed` |
| logs/04-live-node-sim.log | 7 | 6109fe0fa650d055a881a525e97d90f2b496c7d620cf8817e3b5f6c2e815c06b | `ok   raffle holds no NVDAc and no USDC afterwards` |
| logs/05-gas-report.log | 279 | a3c44c672f1e8885a3ec5d4452f7b795a3c1b6db7d6cd88c681c12259cf1106f | `Ran 1 test suite in 1.95s (1.30s CPU time): 36 tests passed, 0 failed,` |
| logs/06-mutation-1-8.log | 11 | a0d302ea9f03fa8e899c007e399cf9e653c5333609856a8827a0686214f8beda | `RESULT: 7/7 mutants killed` |
| logs/06-mutation-17-23.log | 9 | dfedb8fb6b22a722c6cb6bb9541666282dd60dc1bdaa4c52d1dae45cf5052b5f | `RESULT: 7/7 mutants killed` |
| logs/06-mutation-9-16.log | 10 | d23be21cc9f0b0a0b2e6ea97b99a5ac9a27403d886dfc3b93beca34d2d39a398 | `RESULT: 8/8 mutants killed` |
| README.md | 39 | 02abff7a48a60fcd18ae5cdbbe7277ea75b380cf9c0421d4f7b5d28403896edd | `The copies under 'contracts/', 'tests/', 'script/' and 'tools/' are by` |
| script/DeployRaffle.s.sol | 72 | 1b88b26ff8ea962ceb0d8ecbe8a4b60da5466b50e79c4b40f188da92093f7889 | `}` |
| SPEC.md | 294 | 4a2c8ec2c734174fe605e6949e45de504837f2aad4222254b66b05b9e0494c43 | `6. Explicit sign-off on R1 (no refunds ever) and R10 (legal).` |
| TEST-REPORT.md | 136 | 8b0c77729f915a35c317d63150bf51ef7ee8a7f79454caf715a32c9ece92ace3 | `- **ERC-721 with a real collection.** Only 'MockNoun' is used. NFT pri` |
| tests/fork/RaffleFork.t.sol | 142 | 61f4d71cc5e164e90a304f152893dbedac3b6aa9142c72f139c2bbfa9584bdd4 | `}` |
| tests/fork/RaffleLaunchConfig.t.sol | 34 | 8e13cf2ff10047a15e9d56de18fb03c447ee090cdac0d72a6332039963d577c6 | `}` |
| tests/mocks/EtchableERC20.sol | 91 | 10f782a79d599919eb5ec83a91463a66d4e13fd6e20d646ec693778a73983dc4 | `}` |
| tests/mocks/HostileTokens.sol | 112 | 72fea99ab48e96bcfb3d8d9b654ee3392ff51f4656fd34435778a07b33372c82 | `}` |
| tests/mocks/MockEntropyV2.sol | 106 | 8c435743bf41b4365b721f6f4ae0609739cd398051a39038cd807f8a741ce293 | `}` |
| tests/mocks/MockERC20.sol | 20 | cdb0326575a2ff098e59686c0d46f88f37880767112fc5f6b9e2c44957b6a58f | `}` |
| tests/mocks/MockNoun.sol | 27 | f522fc6950cd618a73d562ffe27c98994e1c478b1906b5539abf1c6feb4f64f3 | `}` |
| tests/mocks/MockStockRegistry.sol | 65 | 0f4dd0fdb3f8539a414c73a607a773c34f25ffdcac7be7d1f061f376a17af36a | `}` |
| tests/Raffle.invariant.t.sol | 276 | 21fcbaee856773b2d62dd919d4afef8a9a4c49133d0eeed4b9648ffd9128cce0 | `}` |
| tests/Raffle.t.sol | 608 | cdfc893f2043c111acb6542638f46fba7f6aea475e69559780f8a04d61511838 | `}` |
| tests/RaffleTestBase.sol | 81 | b0d16c762f17762ff8280bfb9afbe628af5ed5e7bb280ce64b4ab7b056b93b8d | `}` |
| THREAT-MODEL.md | 88 | 6fe05ea55a69b8b194cd59105a40c0775b2aac070760b3088bd34a8e6a21c4dc | `5. 'sold ≤ N'. Any state at or past 'SoldOut' has 'sold == N'. When dr` |
| tools/mutation.py | 133 | e926089af37ba20503b741b3282b8ffcfb872243924b1c7fdecf1f37a3caab2e | `main()` |
| tools/raffle-live-sim.cjs | 79 | 6a8af82674b25d0b290b16c938c8272587918241a2ffb1d79d7bf3bcfd393d7b | `})().catch((e) => { console.error(e.message ?? e); process.exit(1); })` |
