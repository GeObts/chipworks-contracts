# Manifest

SHA-256 over the exact file bytes (UTF-8, LF, trailing newline included). Line count = number of newline-terminated lines.

| file | lines | sha256 | last non-empty line |
|---|---|---|---|
| AUDIT_BRIEF.md | 256 | ae90b0287c95543935482d3dc9bf971ff8ffd0914ec460a24d83037d8e5d328d | `(needs `BASE_RPC_URL`, sends nothing).` |
| contracts/Box.sol | 925 | ebf54b447cb6699b060fb2138a383a58048dabf9f19d0a655556f5b9aa648bcf | `}` |
| contracts/PrizeVault.sol | 707 | a0a1da11e93ce9bdbeb5350d6e12ce8531028a0661686cb1f884ca578bb634d0 | `}` |
| contracts/ChipConverter.sol | 242 | 38b803aed62190f7d986ff5764f251a0c5d6759c7e6489dc634befe49e34ccc1 | `}` |
| contracts/interfaces/IBox.sol | 93 | 89b440f2bc0699a614b9f8f2b8970d790d0366f0ec8523552dd573bab2c2990e | `}` |
| contracts/interfaces/IPrizeVault.sol | 33 | 99c6b766fabfd31294d80c26588894a4de8220a71f189a6fec5514f616a14638 | `}` |
| contracts/interfaces/IChipConverter.sol | 19 | 35a6547d6e9908ba88a7418c8ad73ed5d33cc2881a509c8e646ed666ed2a743e | `}` |
| contracts/interfaces/IEntropyV2.sol | 45 | 6a61847358772c396240380de1845e2a7c2b44994df1317b408e576eb25a3e23 | `}` |
| contracts/interfaces/IStockRegistry.sol | 47 | 9c2d0a8c6b8b519d3c2378a3895f6aa7275351a86d20e41bab93f71907c4b804 | `}` |
| contracts/interfaces/ISwapRouters.sol | 34 | a64912c36e4c12fa01ccd7c9d3f26c5fe08e787a264fa72edd9b9732ba535aeb | `}` |
| contracts/interfaces/IUniswapV4.sol | 85 | f03af6e50dceff1b2028a43ba88d71f14223084927752cb9e1ab87c929bb2849 | `}` |
| contracts/interfaces/IAggregatorV3.sol | 15 | d5c01ffff91b207babead0500c3406b0aed14faa56224182636c07388ad2f15d | `}` |
| TRIAGE-ROUND1.md | 41 | ca69af5f20c1418e11381ab6dbb767b989159e6b71e908e4593f9f4d639e66ca | `  what the fix targets.` |
| tests/BoxAuditRound1.t.sol | 118 | 5826dd4516e682c77befb65eca88e65c3e87ad57e292a8de2f3639abcb26d58b | `}` |
| tests/BoxRebuild.t.sol | 499 | 9fd0dcc68f01e236ef6f66b8018335f30ae9c6a38cea31e60320b1343d84505a | `}` |
| tests/BoxAuditPoC.t.sol | 691 | c7519140d92bfc5f83fe6a09bcca9f82c5649575402fa4528cdbe2f8f8446bea | `}` |
| tests/BoxFork.t.sol | 271 | 27d5d61f0438d06ac06c0ec4a7c71cd172e62b261f2299a368dcd6997c583d1f | `}` |
| gas/box-callback-sim.cjs | 181 | aa9c4a87451f36c3b3cfb99cb35fec0fcc979b6cd615004b9a88ccc8e55a92ca | `})().catch((e) => { console.error(e); process.exit(1); });` |
| gas/box-callback-sim.out.txt | 21 | 8cc9ae747828d9b2127823690cf4bd86c68b50471353772c4ed3929dd98cb6f5 | `OK: real B20 transfers inside the callback fit the gas limit on both paths.` |
| tests/BoxVault.t.sol | 491 | 87cd2d612c31226c187e3a67586213493e536e5129455c4463dd3108c64e9fe0 | `}` |
| tests/Box.t.sol | 783 | 950bc8741d587b732c05d29392fbdbce7736d89ce40145af96aa54b0bd00f58a | `}` |
| tests/BoxTestBase.sol | 242 | 298fc2b3c50c4affd871a269a5728585d12984126f2d2e53830f0f7f0f8f14c8 | `}` |
| tests/mocks/MockEntropyV2.sol | 106 | 2c8f388ea8255be43a38397c42613a59f4e7c17373051f6da492f26bb1c0a3ab | `}` |
| tests/mocks/MockPoolManager.sol | 84 | f78c2da57864e4332a947803cf6033ac99f2b21e53293081dcf559c9fa69968f | `}` |
| tests/mocks/MockStockRegistry.sol | 65 | ce31d67d2e7dc99c12d164f61799ff8f87c8bd8bba5f3aef7c2e2c0915db1176 | `}` |
| tests/mocks/MockSwapRouter.sol | 96 | cfc877ea6391da9c6e939bf916f4f2f5cc2191f4628d38b718d224f6111da731 | `}` |
| reference/ChipLottery.sol | 464 | b14cb92496fdcec8c885e567d26feeae82d692634b2e61f40288c02ac36b5d76 | `}` |
| reference/pyth-entropy__revealWithCallback.excerpt.sol | 165 | 964b3ac2ed758fa79efd6884f6ad41f7e430b3fd3838bd5ceeec6af8cc2f1212 | `    }` |
| reference/pyth-entropy__EntropyStructsV2.sol | 71 | 2d2399b9d54569f2ce4a883a2d6de4ece3525723bda84a9609c19ad53e419764 | `}` |
| reference/pyth-entropy__EntropyStatusConstants.sol | 13 | 9bbc07fd388cfba214aa28eb844d9ae679fcf60fc4341a43cd59ca04f1f654e9 | `}` |
