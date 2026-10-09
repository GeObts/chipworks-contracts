# Manifest

SHA-256 over the exact file bytes (UTF-8, LF). Source commit `5e575e5785dbe1ae6bef536a75d6ed52489b5e82` (v1.2).

Repo-path mapping for copies: `contracts/Raffle.sol` = `src/raffle/Raffle.sol`; `contracts/interfaces/IEntropyV2.sol` = `src/interfaces/IEntropyV2.sol`; `contracts/interfaces/IStockRegistry.sol` = `src/interfaces/IStockRegistry.sol`; `script/DeployRaffle.s.sol` = `script/raffle/DeployRaffle.s.sol`; `SPEC.md` = `specs/raffle/SPEC.md`; `tools/mutation.py` = `tools/raffle/mutation.py`; `tools/raffle-live-sim.cjs` = `tools/raffle/raffle-live-sim.cjs`; `tests/*` = `test/raffle/*`, `tests/fork/*` = `test/fork/*`, `tests/mocks/*` = `test/mocks/*`.

| file | lines | sha256 | last non-empty line |
|---|---|---|---|
| .gitattributes | 1 | 705fd4d6451a31d36b3df7de96f83f30ac976c9b4a6d1e51671d8e2f33e2d0da | `* -text` |
| AUDIT_BRIEF.md | 100 | c1cc069dd9ae6aa00509f4c2a3dc30fdaac82895934d0cb01e670fee28c7ed96 | `- The owner's standing rule for custody contracts is two independent e` |
| contracts/interfaces/IEntropyV2.sol | 45 | cf8a572edab4c0e68297bbe0dbad62aa3038ecdac345085268e83e5fd1332944 | `}` |
| contracts/interfaces/IStockRegistry.sol | 47 | e940cf4508f11c6338ce0ec8667657ede4099903bfdb240f74f43db1ff96213a | `}` |
| contracts/Raffle.sol | 769 | 6268b18727eef36d9fa5bbfde65436ae9b494b4f82bf80bb51479756fec3b344 | `}` |
| KEEPER.md | 31 | dc08affa620d0a472fc52300e8ab4cc608e4f9b6016708ad03a802309cac6f9a | `The same Revealed-event fallback was ported to the live Box keeper on ` |
| logs/01-unit.log | 54 | 5aeb70bf2c8d5bf1f9cc013e2b8f4220be791a47f8412d4cf9c28c5235b1d8f5 | `Ran 1 test suite in 1.82s (1.79s CPU time): 43 tests passed, 0 failed,` |
| logs/02-invariant.log | 128 | ee355c896608498c10afac045d57177735cd1045ec6ecc4584f4850bb0573de6 | `Ran 1 test suite in 45.78s (45.77s CPU time): 5 tests passed, 0 failed` |
| logs/03-fork-and-launch-config.log | 28 | 105b33551162a38b501201004d8e3af9625362d738a4b5ceb45c2d0b52f2ffbd | `Ran 3 test suites in 8.39s (12.06s CPU time): 5 tests passed, 0 failed` |
| logs/04-live-node-sim.log | 7 | 4aabdcf5e6d8779be5331f3a8df3a075d92b097ac08ba2a836fbb401485f6f04 | `ok   raffle holds no NVDAc and no USDC afterwards` |
| logs/05-gas-report.log | 315 | 261ce44df4a09d745f0490841ea2daf67ef495e7c1976dc50332ace955385e91 | `Ran 1 test suite in 2.65s (1.74s CPU time): 42 tests passed, 0 failed,` |
| logs/06-mutation-01-08.log | 8 | c58b838dc39a24d38b443fdd48887d19fa2c3c555f3de1a311f2813c2abc1ce3 | `[8/36] KILLED    retryDraw: allowed after a FAILED callback (re-roll) ` |
| logs/06-mutation-09-13.log | 7 | 07ed9963b91428c1054721b481730f4dbcbaebe45f4a98da1fc47abf50acdd18 | `RESULT: 5/5 mutants killed` |
| logs/06-mutation-14-18.log | 7 | ebc4a4d8a9511ca833b935fbaac81ce3ea346880df93211d3b4f5d939c31c9d6 | `RESULT: 5/5 mutants killed` |
| logs/06-mutation-19-22.log | 6 | e048ef3c30593e4e7b5a142c3faec2d2c52c0cbbeb4d24c9cf9564af4f6c5b6f | `RESULT: 4/4 mutants killed` |
| logs/06-mutation-23-26.log | 6 | 163b07a80803663a0cf74a2ed7ac931d82a4848bdb4c0fab1f544b1404e97c67 | `RESULT: 4/4 mutants killed` |
| logs/06-mutation-27-30.log | 6 | 7f9c78796c650a526a5b472744927ed0894802749fa90b86b2000304a8808759 | `RESULT: 4/4 mutants killed` |
| logs/06-mutation-31-33.log | 5 | 3eaacdf814f956aecd818b5cc1508d6fe7438d23cfc07fd27cfe94b795df3c14 | `RESULT: 3/3 mutants killed` |
| logs/06-mutation-34-36.log | 6 | 3bfa8e945ff91eae9649bf2de1b3c27691b12fd4afa9f7338bad407eee8bbd41 | `RESULT: 2/2 mutants killed` |
| README.md | 40 | c03fb9b871d47e9cec52eaff775a2d932b22327bcc17b484c8194386512c1731 | `The copies under 'contracts/', 'tests/', 'script/' and 'tools/' are by` |
| REVIEW-1-RESPONSE.md | 79 | f0a2cc68305d923525655ad58996fa3e8aa032822e3809ae88ef2e8031bc7af1 | `- **Gas.** The last buy (including the Entropy request) is 226,965 gas` |
| script/DeployRaffle.s.sol | 77 | 6f7b8aa10210221288b63892e054ce56de9aa72c5099e4ce1158d4e61fa2aabf | `}` |
| SPEC.md | 300 | 23e4d0293ae6ca47ded00006162141352e4baa57fc1634501bebbd6b62484a62 | `6. Explicit sign-off on R1 (no refunds ever) and R10 (legal).` |
| TEST-REPORT.md | 154 | cdc0acaabcd7ee9bfa15ba54aef6ea7832a052deece9fa7cddf0a06d3c4e5297 | `- **ERC-721 with a real collection.** Only 'MockNoun' is used. NFT pri` |
| tests/fork/RaffleFork.t.sol | 267 | 529de78aca26e326f2fba36c65d6d3b900c2bdb5b1822a869f61f2834da78283 | `}` |
| tests/fork/RaffleLaunchConfig.t.sol | 37 | a3248faf61044591e79ff1277f240204520bfaa11ee672d006f429fd8dc4d6ca | `}` |
| tests/mocks/EtchableERC20.sol | 91 | 10f782a79d599919eb5ec83a91463a66d4e13fd6e20d646ec693778a73983dc4 | `}` |
| tests/mocks/HostileTokens.sol | 112 | 72fea99ab48e96bcfb3d8d9b654ee3392ff51f4656fd34435778a07b33372c82 | `}` |
| tests/mocks/MockEntropyV2.sol | 125 | d35989864bcc2cfd33d13a3c12099174a45c224eaf127ba98f1b04e6b0eb6e1f | `}` |
| tests/mocks/MockERC20.sol | 20 | cdb0326575a2ff098e59686c0d46f88f37880767112fc5f6b9e2c44957b6a58f | `}` |
| tests/mocks/MockNoun.sol | 27 | f522fc6950cd618a73d562ffe27c98994e1c478b1906b5539abf1c6feb4f64f3 | `}` |
| tests/mocks/MockStockRegistry.sol | 65 | 0f4dd0fdb3f8539a414c73a607a773c34f25ffdcac7be7d1f061f376a17af36a | `}` |
| tests/mocks/ReturnShapeToken.sol | 47 | e84631439fe4ca64a2a216bcabdc3a54fd05b52a029b768db3dce04764739358 | `}` |
| tests/Raffle.invariant.t.sol | 277 | 357c6a2cfecf2ae3e60ec1047fe13780c9eb320a04e9594c88c1fb2fa1c4d351 | `}` |
| tests/Raffle.t.sol | 796 | 2696d7908598bacde4642e55750ffeb0410e575798a83630755360d619fbe140 | `}` |
| tests/RaffleTestBase.sol | 81 | b0d16c762f17762ff8280bfb9afbe628af5ed5e7bb280ce64b4ab7b056b93b8d | `}` |
| THREAT-MODEL.md | 92 | 1bc085c3d8d85d0c3ed39e7aaec93b709e2fbfd9bc00a523d94cdad00d4fa3df | `5. 'sold ≤ N'. Any state at or past 'SoldOut' has 'sold == N'. When dr` |
| tools/mutation.py | 175 | d3e39f4c27b1fcfc938899b13d0f62c5e3b13d0aa7bb48d53881343cdfdecac7 | `main()` |
| tools/raffle-live-sim.cjs | 79 | 6a8af82674b25d0b290b16c938c8272587918241a2ffb1d79d7bf3bcfd393d7b | `})().catch((e) => { console.error(e.message ?? e); process.exit(1); })` |
