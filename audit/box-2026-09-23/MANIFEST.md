# Manifest

SHA-256 over the exact file bytes (UTF-8, LF, trailing newline included). Line count = number of newline-terminated lines.

| file | lines | sha256 | last non-empty line |
|---|---|---|---|
| AUDIT_BRIEF.md | 228 | 607838e0dd02e33bd60ee332c1d33f21adf2dad03c457911923e834cffa9bb8a | `(needs `BASE_RPC_URL`, sends nothing).` |
| contracts/Box.sol | 890 | 671fbd315d220b6df8b23f4337c8e27c4d23736fda0b27c7f0a7793493997567 | `}` |
| contracts/PrizeVault.sol | 706 | acb0b4e2fedc2de6715719e1c8f3b183ccc4e0729e0d5a5f962cbb811b23a067 | `}` |
| contracts/ChipConverter.sol | 362 | 269b6e04e437183e90ad788d3039e76089dd9b628c5098fd557a5f3f07f45911 | `}` |
| contracts/interfaces/IBox.sol | 82 | c92229fbd4aea1b876492bd5042e11e1f0d6ae03662f9b9b062972639fa40b30 | `}` |
| contracts/interfaces/IPrizeVault.sol | 33 | 99c6b766fabfd31294d80c26588894a4de8220a71f189a6fec5514f616a14638 | `}` |
| contracts/interfaces/IChipConverter.sol | 12 | 083fdd7ca1e421d823c4c7a91b7b1fc321f84708fc84e1c9c864c4c3facd828f | `}` |
| contracts/interfaces/IEntropyV2.sol | 45 | 6a61847358772c396240380de1845e2a7c2b44994df1317b408e576eb25a3e23 | `}` |
| contracts/interfaces/IStockRegistry.sol | 47 | 9c2d0a8c6b8b519d3c2378a3895f6aa7275351a86d20e41bab93f71907c4b804 | `}` |
| contracts/interfaces/ISwapRouters.sol | 34 | a64912c36e4c12fa01ccd7c9d3f26c5fe08e787a264fa72edd9b9732ba535aeb | `}` |
| contracts/interfaces/IUniswapV4.sol | 85 | f03af6e50dceff1b2028a43ba88d71f14223084927752cb9e1ab87c929bb2849 | `}` |
| contracts/interfaces/IAggregatorV3.sol | 15 | d5c01ffff91b207babead0500c3406b0aed14faa56224182636c07388ad2f15d | `}` |
| tests/BoxRebuild.t.sol | 528 | 6c49e1f750a6a1bfec37e5e1497df150fb8e034838e1be94d731e0e66ee696f2 | `}` |
| tests/BoxAuditPoC.t.sol | 677 | 9ea3c417f0930b7fe33d07edd54e545dcb3fe6d3257dd9b55c87b298b26ff28f | `}` |
| tests/BoxFork.t.sol | 256 | efa3ed963bc3a4669af5effb9c287fafd2357d41f24e70c93b3556077ba29960 | `}` |
| gas/box-callback-sim.cjs | 182 | 413c390502fbe73e00aae10055419cfb28852dd27e2618bc406ed469a056deeb | `})().catch((e) => { console.error(e); process.exit(1); });` |
| gas/box-callback-sim.out.txt | 21 | 180a88651f65ece0d4b428bf4faeaec6f346d8e0f507fe938fccd7bcf9608225 | `OK: real B20 transfers inside the callback fit the gas limit on both paths.` |
| tests/BoxVault.t.sol | 489 | e78c274e2613646a3b16df76852130d4d0a1b6ff3819fa4ebadef448bd0ca5d4 | `}` |
| tests/Box.t.sol | 622 | a01f23f1e4aac55c9b577088a76ea794b8ee4f3a130d8396ba92fe8ed7d35a3e | `}` |
| tests/BoxTestBase.sol | 222 | f359eab5cacafe5853ac5c5610c9dc1c1209136b5114110f0adef5c9630300ef | `}` |
| tests/mocks/MockEntropyV2.sol | 90 | a431b11480e80393b2b48d540861a0d5850e26cd891cf308d39ad5d84c6f6c8d | `}` |
| tests/mocks/MockPoolManager.sol | 75 | 590c7c497d91bca0a301c56fd5742088415b01a1129b70b6e857550bb4e0677d | `}` |
| tests/mocks/MockStockRegistry.sol | 65 | ce31d67d2e7dc99c12d164f61799ff8f87c8bd8bba5f3aef7c2e2c0915db1176 | `}` |
| tests/mocks/MockSwapRouter.sol | 77 | e9aabc62466291c7c3e1196dace2e5693d48476377539133148ca679e5edd600 | `}` |
| reference/ChipLottery.sol | 464 | b14cb92496fdcec8c885e567d26feeae82d692634b2e61f40288c02ac36b5d76 | `}` |
| reference/pyth-entropy__revealWithCallback.excerpt.sol | 165 | 964b3ac2ed758fa79efd6884f6ad41f7e430b3fd3838bd5ceeec6af8cc2f1212 | `    }` |
| reference/pyth-entropy__EntropyStructsV2.sol | 71 | 2d2399b9d54569f2ce4a883a2d6de4ece3525723bda84a9609c19ad53e419764 | `}` |
| reference/pyth-entropy__EntropyStatusConstants.sol | 13 | 9bbc07fd388cfba214aa28eb844d9ae679fcf60fc4341a43cd59ca04f1f654e9 | `}` |
