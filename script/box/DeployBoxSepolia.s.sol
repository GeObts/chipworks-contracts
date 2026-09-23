// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Box} from "../../src/box/Box.sol";
import {PrizeVault} from "../../src/box/PrizeVault.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";
import {MockAggregatorV3} from "../../test/mocks/MockAggregatorV3.sol";

/// @title DeployBoxSepolia
/// @notice Base SEPOLIA rehearsal of the Box: mock CHIP (18 dp), mock USDC (6 dp), two
///         mock B20 stocks with mock feeds, the real Pyth Entropy v2 on Sepolia.
///
/// @dev UNAUDITED. Testnet only: `run` reverts on any chain but 84532, so this file can
///      never put the Box on Base mainnet. Mainnet uses DeployBox.s.sol, and only with the
///      owner's explicit written OK.
///
///      Why mock USDC and not Circle's Sepolia USDC: Circle's faucet caps a wallet at a few
///      dollars a day, and a real cycle needs the vault seeded past the prize cap (a $1
///      jackpot is $36 and a prize is capped at 25% of inventory, so >= $144). Mint instead.
///
///      The deployer is the owner here, so the script does what the Safe does on mainnet:
///      `setBox` once, `addStock` for the two mock stocks, then seeds the vault. CHIP is
///      NEVER added as a stock and never deposited as inventory (H-01).
///
///      Env: BOX_TREASURY (5% recipient, required: pass a wallet you can watch),
///           BOX_SEED_USDC (whole dollars, default 1000), BOX_BUYER (optional, gets test
///           USDC + CHIP minted).
contract DeployBoxSepolia is Script {
    uint256 internal constant BASE_SEPOLIA = 84_532;
    /// @dev Pyth Entropy v2 on Base Sepolia (default provider 0x6CC1…6344), checked on chain.
    address internal constant ENTROPY = 0x41c9e39574F40Ad34c79f1C99B66A45eFB830d4c;
    /// @dev Same CHIP/USD as mainnet DeployBox: 467e6 CHIP = $700, rounded up.
    uint256 internal constant CHIP_PER_USD = 667_143 ether;

    function run() external {
        require(block.chainid == BASE_SEPOLIA, "DeployBoxSepolia: Base Sepolia (84532) only");
        address treasury = vm.envAddress("BOX_TREASURY");
        uint256 seedUsd = vm.envOr("BOX_SEED_USDC", uint256(1_000));
        address buyer = vm.envOr("BOX_BUYER", address(0));

        vm.startBroadcast();
        address owner = msg.sender;
        require(treasury != owner, "treasury must differ from owner so the 5% is measurable");

        MockERC20 chip = new MockERC20("Mock CHIP (Sepolia)", "mCHIP", 18);
        MockERC20 usdc = new MockERC20("Mock USDC (Sepolia)", "mUSDC", 6);
        MockERC20 nvda = new MockERC20("Mock NVIDIA (Sepolia)", "mNVDAc", 8);
        MockERC20 aapl = new MockERC20("Mock Apple (Sepolia)", "mAAPLc", 8);
        MockAggregatorV3 nvdaFeed = new MockAggregatorV3(8, 225e8, "mNVDA / USD");
        MockAggregatorV3 aaplFeed = new MockAggregatorV3(8, 250e8, "mAAPL / USD");

        PrizeVault vault = new PrizeVault(owner, address(usdc), address(chip), 2_500);
        Box box = new Box(
            owner,
            address(usdc),
            address(chip),
            treasury,
            address(vault),
            ENTROPY,
            uint128(CHIP_PER_USD),
            uint128(10 * CHIP_PER_USD),
            uint128(25 * CHIP_PER_USD)
        );

        vault.setBox(address(box));
        vault.addStock(address(nvda), address(nvdaFeed), 8);
        vault.addStock(address(aapl), address(aaplFeed), 8);

        // Seed: USDC plus an equal dollar amount split across the two stocks.
        usdc.mint(owner, seedUsd * 1e6);
        usdc.approve(address(vault), seedUsd * 1e6);
        vault.deposit(address(usdc), seedUsd * 1e6);
        uint256 nvdaAmt = seedUsd * 1e8 / 2 / 225;
        uint256 aaplAmt = seedUsd * 1e8 / 2 / 250;
        nvda.mint(owner, nvdaAmt);
        aapl.mint(owner, aaplAmt);
        nvda.approve(address(vault), nvdaAmt);
        aapl.approve(address(vault), aaplAmt);
        vault.deposit(address(nvda), nvdaAmt);
        vault.deposit(address(aapl), aaplAmt);

        // Test money for whoever runs the cycle (owner always, BOX_BUYER if given).
        usdc.mint(owner, 200e6);
        chip.mint(owner, 100 * CHIP_PER_USD);
        if (buyer != address(0)) {
            usdc.mint(buyer, 200e6);
            chip.mint(buyer, 100 * CHIP_PER_USD);
        }
        vm.stopBroadcast();

        console2.log("BOX_ADDRESS    ", address(box));
        console2.log("VAULT_ADDRESS  ", address(vault));
        console2.log("MOCK_CHIP      ", address(chip));
        console2.log("MOCK_USDC      ", address(usdc));
        console2.log("MOCK_NVDA      ", address(nvda));
        console2.log("MOCK_AAPL      ", address(aapl));
        console2.log("NVDA_FEED      ", address(nvdaFeed));
        console2.log("AAPL_FEED      ", address(aaplFeed));
        console2.log("OWNER          ", owner);
        console2.log("TREASURY (5%)  ", treasury);
        console2.log("inventoryUsd   ", vault.inventoryUsd());
        console2.log("prizeCapUsd    ", vault.prizeCapUsd());
    }
}
