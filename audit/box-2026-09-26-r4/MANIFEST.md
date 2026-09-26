# Manifest

SHA-256 over the exact file bytes (UTF-8, LF, trailing newline included). Line count = number of newline-terminated lines.

| file | lines | sha256 | last non-empty line |
|---|---|---|---|
| AUDIT_BRIEF.md | 286 | 1842eb9164e621c71d6a167a02489b2ddbfe63de66f2a5fd99ec2ed222b7765a | `(needs `BASE_RPC_URL`, sends nothing).` |
| contracts/Box.sol | 935 | dd9e47b289c0a1e4e924a77849480683204c2511631b65e6de4c08893d609378 | `}` |
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
| TRIAGE-ROUND3.md | 27 | 9861251b372a504af8cded104e3408f8ce0758a6948bf2524a89f778a4f3f545 | `- Live node: `box-callback-sim` 467,147 / 465,018 at 10 stocks and 566,543 / 574,176 at 13; `box-refusing-opener-sim` 580,918 (worst case, OWED).` |
| tests/BoxAuditRound3.t.sol | 180 | f7894b29b1192eab8e677fe8aba952921077f3e434d02f1c7ff7a8f8f8190cf6 | `}` |
| TRIAGE-ROUND2.md | 86 | 106e96932088946cb42af36a711b2551698743f304610205a1fc75c721fb0414 | `- Live-node callback sim (real B20s): 466,863 / 464,734 at 10 stocks, 566,259 / 573,892 at 13. See `gas/box-callback-sim.out.txt`.` |
| tests/BoxAuditRound2.t.sol | 244 | d0e732914c0879399b55767a07bc03507e09d06354b6154ac3d0c41997be1541 | `}` |
| TRIAGE-ROUND1.md | 41 | ca69af5f20c1418e11381ab6dbb767b989159e6b71e908e4593f9f4d639e66ca | `  what the fix targets.` |
| tests/BoxAuditRound1.t.sol | 118 | 5826dd4516e682c77befb65eca88e65c3e87ad57e292a8de2f3639abcb26d58b | `}` |
| tests/BoxAuditPoC.t.sol | 691 | b7d7415de2d9b54a38c9216350fe2ee2596668d01d75ef1c639c4a006d7502bf | `}` |
| tests/BoxFork.t.sol | 271 | 27d5d61f0438d06ac06c0ec4a7c71cd172e62b261f2299a368dcd6997c583d1f | `}` |
| gas/box-callback-sim.cjs | 182 | 991165336a08374646235867e44b7beea66d314bd9d73c4ed69287e5a4fc44a4 | `})().catch((e) => { console.error(e); process.exit(1); });` |
| gas/box-callback-sim.out.txt | 24 | cb84ece140a9d6ff8c720cf7383f637b7b653733386bff3fcea3262fe382c6a8 | `# tools/box/box-refusing-opener-sim.cjs; its output is tools/box/box-refusing-opener-sim.out.txt.` |
| gas/box-refusing-opener-sim.cjs | 163 | 295ad3c27a4e9aba9be6e65e4ae8c3af04f7c4718ffca6bebe4ae8f313824d7f | `})().catch((e) => { console.error(e); process.exit(1); });` |
| gas/box-refusing-opener-sim.out.txt | 8 | d4937ac9a1d31b44449829160878f05ba0af8af2ec204dbbe94289877b56766f | `OK: the refusing-opener worst case fits under the 900k floor on real B20s.` |
| tests/BoxRebuild.t.sol | 530 | 90cb9349d40ac071ec0ced6205b42e897065138ab9fc7194472f6b80c22758b2 | `}` |
| tests/BoxVault.t.sol | 502 | f786864dc69595f39f7daaa0d39a36ede97c5b6db5439c7c05e230feca78ea2a | `}` |
| tests/BoxTestBase.sol | 247 | 99db2b7de21f626cd9c9c7a4c001dbfaadf3f958364f43e7a4fd823932c50912 | `}` |
| tests/Box.t.sol | 794 | d594c73053efc40088517d3957dbdb0f3272802d0865d6e6a72abfab5039be9b | `}` |
| tests/mocks/MockEntropyV2.sol | 106 | 2c8f388ea8255be43a38397c42613a59f4e7c17373051f6da492f26bb1c0a3ab | `}` |
| tests/mocks/MockPoolManager.sol | 98 | be1dbbfba1332569a5d7499f3e1389d1a19108103d684d50c5f80f372f9de5b9 | `}` |
| tests/mocks/MockStockRegistry.sol | 65 | ce31d67d2e7dc99c12d164f61799ff8f87c8bd8bba5f3aef7c2e2c0915db1176 | `}` |
| tests/mocks/MockSwapRouter.sol | 105 | 3a59ba4141f4dc52cec8f3586bec7c01b4949e38c677b0a43e019d554061e750 | `}` |
| reference/ChipLottery.sol | 464 | b14cb92496fdcec8c885e567d26feeae82d692634b2e61f40288c02ac36b5d76 | `}` |
| reference/pyth-entropy__revealWithCallback.excerpt.sol | 165 | 964b3ac2ed758fa79efd6884f6ad41f7e430b3fd3838bd5ceeec6af8cc2f1212 | `    }` |
| reference/pyth-entropy__EntropyStructsV2.sol | 71 | 2d2399b9d54569f2ce4a883a2d6de4ece3525723bda84a9609c19ad53e419764 | `}` |
| reference/pyth-entropy__EntropyStatusConstants.sol | 13 | 9bbc07fd388cfba214aa28eb844d9ae679fcf60fc4341a43cd59ca04f1f654e9 | `}` |
