# Manifest

SHA-256 over the exact file bytes. Source commit `7e9923973cbbae0ecad2d04cd2fcbea823b70e79` (Raffle v2).

Repo-path mapping for copies: `contracts/Raffle.sol` = `src/raffle/Raffle.sol`; `contracts/interfaces/*` = `src/interfaces/*`; `script/DeployRaffle.s.sol` = `script/raffle/DeployRaffle.s.sol`; `SPEC-v2.md` = `specs/raffle/SPEC-v2.md`; `tools/*` = `tools/raffle/*`; `tests/*` = `test/raffle/*`; `tests/fork/*` = `test/fork/*`; `tests/mocks/*` = `test/mocks/*`.

| file | lines | sha256 | last non-empty line |
|---|---|---|---|
| .gitattributes | 1 | 705fd4d6451a31d36b3df7de96f83f30ac976c9b4a6d1e51671d8e2f33e2d0da | `* -text` |
| AUDIT_BRIEF.md | 125 | cedfed8e6e605fe4b5793220a62cb6286c226c90559cf7dba3000e8861b014c6 | `- **v2:** internal suites only (TEST-REPORT.md). **This is v2's first ` |
| contracts/interfaces/IEntropyV2.sol | 45 | cf8a572edab4c0e68297bbe0dbad62aa3038ecdac345085268e83e5fd1332944 | `}` |
| contracts/interfaces/ISlipstreamPool.sol | 41 | db4f7d316d1721baa88fa4868d108ed76b3be840f9e6274e36c7a29ec1cb372f | `}` |
| contracts/interfaces/IStockRegistry.sol | 47 | e940cf4508f11c6338ce0ec8667657ede4099903bfdb240f74f43db1ff96213a | `}` |
| contracts/interfaces/ISwapRouters.sol | 34 | a2b18986182080c627fba59162aaee05f231ea4d3857e9b19073fadfe8cc915e | `}` |
| contracts/Raffle.sol | 1067 | 4135d5b8eb763dd4b704048519ec3f070e002bef8bc0a66860f1199815285a4b | `}` |
| KEEPER.md | 25 | fe027a429d339c1599263201648dbb7e2abcd42895e65c14ef62d5135ae3134f | `- **Raffle 2:** its pool is pushed off its TWAP. The job's buy is refu` |
| logs/01-unit.log | 70 | 09f424e84b3a380b2d1c06ce3e4af861869d9d4739e0af4206e47ac90771b7ce | `Ran 1 test suite in 632.42ms (615.22ms CPU time): 57 tests passed, 0 f` |
| logs/02-invariant.log | 176 | ad5e0cbcc5f01bba4ca4f5e0ce8eb544991a4a27b911702b54aaa0449fd022f2 | `Ran 1 test suite in 21.89s (21.89s CPU time): 6 tests passed, 0 failed` |
| logs/03-fork-and-launch-config.log | 57 | f4172e0367224826d54bdbc7b5389ec5b1552c2912439cce1256ce7fef0ea1cb | `Ran 3 test suites in 41.33s (45.32s CPU time): 6 tests passed, 0 faile` |
| logs/04-live-node-sim.log | 17 | 5f1b9218f30a913666558d88e820f5d1145ec35c49d843a5898976644e3138f8 | `ok   nothing moved: still SoldOut, all 110 USDC still held` |
| logs/05-gas-report.log | 381 | 19a62fbf0c5b0954bd1698907b02d8a1116e566b340ee60508a853fb8d8ae565 | `Ran 1 test suite in 1.63s (787.00ms CPU time): 56 tests passed, 0 fail` |
| logs/06-mutation-01-05.log | 7 | f1b17b093e19f1093d11671b19c9f0f80f4e1f78a2ce782698b80c216a414fcb | `RESULT: 5/5 mutants killed` |
| logs/06-mutation-06-11.log | 9 | b63447ff5ad6a75ca3a595d83952cbec7bf23edee82eafbd52b2c260d51df44f | `RESULT: 5/5 mutants killed` |
| logs/06-mutation-12-17.log | 8 | e512b0c966d0df243d8fd31ebf4c248983b3ccc49ef39cffd1d72a0815be428a | `RESULT: 6/6 mutants killed` |
| logs/06-mutation-18-23.log | 8 | 37e96458155d84396c3c3f9e02cb107d6f6a2cfd321f62c40d125e5571ba0686 | `RESULT: 6/6 mutants killed` |
| logs/06-mutation-24-29.log | 8 | e51ccd41661b4b4eeff8bd1ff1a41db3f1cdd24ec472951e1124b48b926b2692 | `RESULT: 6/6 mutants killed` |
| logs/06-mutation-30-35.log | 9 | df44714d8ba3b674567e5a80e8557bb3f3d17f121b4c2f86c81cad79b623d1cc | `RESULT: 5/5 mutants killed` |
| logs/06-mutation-36-41.log | 8 | 21e51d2cf41542441ec954270df2a9c7e0cbf09157eefb91bb878c6be7b194bf | `RESULT: 6/6 mutants killed` |
| logs/06-mutation-42-47.log | 8 | f7a530cc6eccd8f694d9c56c4049c5ec406fb9c6af9974df2281d5e547733932 | `RESULT: 6/6 mutants killed` |
| logs/06-mutation-48-53.log | 8 | 967b8d35749cd8440ee4fabd79f46dcd82937c0b6eadcd33701494b97e2d12cb | `RESULT: 6/6 mutants killed` |
| logs/06-mutation-54-59.log | 9 | 50e7b5b4e7d91cef89c7af02cd9a5d8055c3f628852f8bee6440a2dabcb78f4e | `NOT KILLED: swap: approval not reset: SURVIVED` |
| logs/06-mutation-60-66.log | 9 | 1ecf71b71dd26be7c377a8b65b045464821d2fc0bb5160d3b63f8d1e245405c0 | `RESULT: 7/7 mutants killed` |
| logs/07-keeper-e2e.log | 22 | e29568679ba70af5a7e63fa555b236a7abd6709b9805717960ddcd923ae01edc | `all passed` |
| README.md | 46 | 617ba28ee671e599571735ac27ff3967aea4fe377108b4a3b114e7718603c546 | `Note on 'tools/raffle-live-sim.cjs': it resolves 'viem' from a hard-co` |
| script/DeployRaffle.s.sol | 94 | d09f38af4fa8789755331693becb2536fadf678f1b542c78d1dedf240a59ea1b | `}` |
| SPEC-v2.md | 290 | 9017c4cc0f37140ba1f75230fdf855b2c3cc2c2b3e1e6fbc3ae93a33dcea99a5 | `6. **Pre-deploy items (§2.5)** gate the mainnet deploy, not the build:` |
| TEST-REPORT.md | 134 | 09e0dbfc831fd00d1b424fd1dbf9c39433e05aa6ed80d276dc7ce0a66297e40d | `- **The keeper's '*/5' cron dispatch inside Cloudflare.** The job logi` |
| tests/fork/RaffleFork.t.sol | 262 | 18a1d58e15d421097536a972ba761b5f5ea480afea3de639d1144dd9482df2a0 | `}` |
| tests/fork/RaffleLaunchConfig.t.sol | 47 | b101786171b4009eb1bc03eb3ccaf19ee7b03cae1936a2a62cf99b1f58213e84 | `}` |
| tests/mocks/HostileTokens.sol | 112 | 72fea99ab48e96bcfb3d8d9b654ee3392ff51f4656fd34435778a07b33372c82 | `}` |
| tests/mocks/MockEntropyV2.sol | 125 | d35989864bcc2cfd33d13a3c12099174a45c224eaf127ba98f1b04e6b0eb6e1f | `}` |
| tests/mocks/MockERC20.sol | 20 | cdb0326575a2ff098e59686c0d46f88f37880767112fc5f6b9e2c44957b6a58f | `}` |
| tests/mocks/MockSlipstream.sol | 131 | 9f1599c452347ae044ddb4cd705430bf4771bdc5990f1dce9a4fff422c63ca0c | `}` |
| tests/mocks/MockStockRegistry.sol | 79 | 3e6fbf5323e1a27cf73974c7232c11229eb26747465e700abc29ce6eb4e2e6a3 | `}` |
| tests/mocks/ReturnShapeToken.sol | 47 | e84631439fe4ca64a2a216bcabdc3a54fd05b52a029b768db3dce04764739358 | `}` |
| tests/Raffle.invariant.t.sol | 366 | 754fcabf481a4468ba0672000fb7bece2d4d3fa9712c3a1e8d95d24e8f0a4671 | `}` |
| tests/Raffle.t.sol | 1183 | df42a4cd12a7e30720d8c016871bae934dc280d38440f4bee8fc12d2445cd3c2 | `}` |
| tests/RaffleTestBase.sol | 126 | fe5a3b700adb45d3e64f837c20351acb4e56d2787867bae4c34b13585fa37fe7 | `}` |
| THREAT-MODEL.md | 91 | 6fa2c4330dd8095f838b09b4ad8b80d8c309f2e8b5cfe80c36fc07d5473576cc | `6. 'sold ≤ N'; once 'SoldOut', 'sold == N'; 'winningTicket == rnd % N'` |
| tools/mutation.py | 272 | 138ef7b8ab0897aff689aec9fbabdfa62105df53d19335068b969303d0fd15cc | `main()` |
| tools/raffle-live-sim.cjs | 141 | 1c98ecfda0c9f63a482921055f915bc37fe0e5aa6e22d3887b55a0c282ee8335 | `})().catch((e) => { console.error(e.message ?? e); process.exit(1); })` |
