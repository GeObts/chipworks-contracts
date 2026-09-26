# Manifest

SHA-256 over the exact file bytes (UTF-8, LF, trailing newline included). Line count = number of newline-terminated lines.

| file | lines | sha256 | last non-empty line |
|---|---|---|---|
| AUDIT_BRIEF.md | 345 | a2600fa2ee18df5c3251d94f6fbc9745fe7675e5f3951e4a6a06fcbf0e1c077d | `(needs `BASE_RPC_URL`, sends nothing).` |
| contracts/Box.sol | 945 | 048d4b42c056933bb13796d7065c206d40409882cdbccdc7a4aafadf3be23ae8 | `}` |
| contracts/PrizeVault.sol | 738 | 095a4e9d8a1aaf9f74c4007ed643b1d91fc5e7b8744458b5f8f42d4ed1eab1ad | `}` |
| contracts/ChipConverter.sol | 242 | 38b803aed62190f7d986ff5764f251a0c5d6759c7e6489dc634befe49e34ccc1 | `}` |
| contracts/interfaces/IBox.sol | 93 | 89b440f2bc0699a614b9f8f2b8970d790d0366f0ec8523552dd573bab2c2990e | `}` |
| contracts/interfaces/IPrizeVault.sol | 36 | ef6b98dbfd28c96b43e26a80646db14acac653c92347e27019422231208f45ad | `}` |
| contracts/interfaces/IChipConverter.sol | 19 | 35a6547d6e9908ba88a7418c8ad73ed5d33cc2881a509c8e646ed666ed2a743e | `}` |
| contracts/interfaces/IEntropyV2.sol | 45 | 6a61847358772c396240380de1845e2a7c2b44994df1317b408e576eb25a3e23 | `}` |
| contracts/interfaces/IStockRegistry.sol | 47 | 9c2d0a8c6b8b519d3c2378a3895f6aa7275351a86d20e41bab93f71907c4b804 | `}` |
| contracts/interfaces/ISwapRouters.sol | 34 | a64912c36e4c12fa01ccd7c9d3f26c5fe08e787a264fa72edd9b9732ba535aeb | `}` |
| contracts/interfaces/IUniswapV4.sol | 85 | 06dd33a40155dc202f20ad4e00fd8a9f75be79a60a64f0408a8049e674f110fd | `}` |
| contracts/interfaces/IAggregatorV3.sol | 15 | d5c01ffff91b207babead0500c3406b0aed14faa56224182636c07388ad2f15d | `}` |
| TRIAGE-ROUND4.md | 68 | 39e56802f764d0a1ce5ccda7e54970257c1e480594b9e41d5624d39a68b00cc1 | `  - All are unchanged, because the stock walk did not change.` |
| tests/BoxLaunchConfig.t.sol | 108 | f36c1252b1f48ef770f18b465dafa4ae2976f3fff8c0549aa963c53149c25dab | `}` |
| TRIAGE-ROUND3.md | 27 | 9861251b372a504af8cded104e3408f8ce0758a6948bf2524a89f778a4f3f545 | `- Live node: `box-callback-sim` 467,147 / 465,018 at 10 stocks and 566,543 / 574,176 at 13; `box-refusing-opener-sim` 580,918 (worst case, OWED).` |
| tests/BoxAuditRound3.t.sol | 185 | e8b36789d3f4a43e5b76450ac639ffe16674ab753af55b1b28e2f442f4fccaf3 | `}` |
| TRIAGE-ROUND2.md | 86 | 106e96932088946cb42af36a711b2551698743f304610205a1fc75c721fb0414 | `- Live-node callback sim (real B20s): 466,863 / 464,734 at 10 stocks, 566,259 / 573,892 at 13. See `gas/box-callback-sim.out.txt`.` |
| tests/BoxAuditRound2.t.sol | 244 | e99e119c48d68a7555d1a38b60134cb854db03aefefde042876f349c00baaef2 | `}` |
| TRIAGE-ROUND1.md | 41 | ca69af5f20c1418e11381ab6dbb767b989159e6b71e908e4593f9f4d639e66ca | `  what the fix targets.` |
| tests/BoxAuditRound1.t.sol | 118 | 5826dd4516e682c77befb65eca88e65c3e87ad57e292a8de2f3639abcb26d58b | `}` |
| tests/BoxAuditPoC.t.sol | 691 | c10a67dd3cf472fb206400db939123244ca20b7e505c65c4ba9f7fe97853ed47 | `}` |
| tests/BoxFork.t.sol | 271 | 27d5d61f0438d06ac06c0ec4a7c71cd172e62b261f2299a368dcd6997c583d1f | `}` |
| gas/box-callback-sim.cjs | 182 | a327bf195289b269dbac50575573d49828dd64a92b10192b2d8eec232a8ea677 | `})().catch((e) => { console.error(e); process.exit(1); });` |
| gas/box-callback-sim.out.txt | 23 | 0788dfe0a560bdf74f4762ba019a3c8635a98375d2009fe349194c3192219c56 | `# The refusing-opener worst case is tools/box/box-refusing-opener-sim.cjs (output: box-refusing-opener-sim.out.txt).` |
| gas/box-refusing-opener-sim.cjs | 163 | 70c65aebe7e13d9017455d7f770b57b6e58b6ff738133604197d7292aa28f90d | `})().catch((e) => { console.error(e); process.exit(1); });` |
| gas/box-refusing-opener-sim.out.txt | 8 | 8ebe5743bd705751efb3b5362739d135d2ba68d6b9d06c8cbb1eb78391ce3c6e | `OK: the refusing-opener worst case fits under the 900k floor on real B20s.` |
| tests/BoxRebuild.t.sol | 530 | f57b520d403faf13d227a8d695d9bd326158893915520ab850d1530b57698f08 | `}` |
| tests/BoxVault.t.sol | 511 | 909e53869e91863e31a31662e9c42362662a0c16334eba54eb4b44fc32dfd368 | `}` |
| tests/BoxTestBase.sol | 247 | 99db2b7de21f626cd9c9c7a4c001dbfaadf3f958364f43e7a4fd823932c50912 | `}` |
| tests/Box.t.sol | 817 | fac42a12da0eccb0a8809a770258b1680813149299d13459b15f69869b8d4302 | `}` |
| tests/mocks/MockEntropyV2.sol | 106 | 2c8f388ea8255be43a38397c42613a59f4e7c17373051f6da492f26bb1c0a3ab | `}` |
| tests/mocks/MockPoolManager.sol | 98 | be1dbbfba1332569a5d7499f3e1389d1a19108103d684d50c5f80f372f9de5b9 | `}` |
| tests/mocks/MockStockRegistry.sol | 65 | ce31d67d2e7dc99c12d164f61799ff8f87c8bd8bba5f3aef7c2e2c0915db1176 | `}` |
| tests/mocks/MockSwapRouter.sol | 105 | 3a59ba4141f4dc52cec8f3586bec7c01b4949e38c677b0a43e019d554061e750 | `}` |
| reference/ChipLottery.sol | 464 | b14cb92496fdcec8c885e567d26feeae82d692634b2e61f40288c02ac36b5d76 | `}` |
| reference/pyth-entropy__revealWithCallback.excerpt.sol | 165 | 964b3ac2ed758fa79efd6884f6ad41f7e430b3fd3838bd5ceeec6af8cc2f1212 | `    }` |
| reference/pyth-entropy__EntropyStructsV2.sol | 71 | 2d2399b9d54569f2ce4a883a2d6de4ece3525723bda84a9609c19ad53e419764 | `}` |
| reference/pyth-entropy__EntropyStatusConstants.sol | 13 | 9bbc07fd388cfba214aa28eb844d9ae679fcf60fc4341a43cd59ca04f1f654e9 | `}` |
