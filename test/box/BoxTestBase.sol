// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Box} from "../../src/box/Box.sol";
import {PrizeVault} from "../../src/box/PrizeVault.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockEntropyV2} from "../mocks/MockEntropyV2.sol";

contract BoxTestBase is Test {
    Box internal boxes;
    PrizeVault internal vault;
    MockEntropyV2 internal entropy;
    MockERC20 internal usdc;
    MockERC20 internal chip;
    MockERC20 internal nvda;
    MockERC20 internal tsla;
    MockAggregatorV3 internal nvdaFeed;
    MockAggregatorV3 internal tslaFeed;

    address internal multisig = makeAddr("multisig");
    /// @dev Goyabean's Safe — same address as {Box.DEFAULT_FEE_RECIPIENT}.
    address internal treasury = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint8 internal constant SKU1 = 0;
    uint8 internal constant SKU5 = 1;
    uint256 internal constant USD1 = 1_000_000;
    uint256 internal constant USD5 = 5_000_000;
    uint128 internal constant CHIP1 = 100 ether;
    uint128 internal constant CHIP5 = 500 ether;
    uint256 internal constant NVDA_PRICE = 100e8; // $100, 8 dp feed
    uint256 internal constant TSLA_PRICE = 200e8; // $200

    function setUp() public virtual {
        vm.warp(1_700_000_000);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        chip = new MockERC20("Chipworks", "CHIP", 18);
        nvda = new MockERC20("NVIDIA", "NVDAX", 8);
        tsla = new MockERC20("Tesla", "TSLAX", 8);
        nvdaFeed = new MockAggregatorV3(8, int256(NVDA_PRICE), "NVDA");
        tslaFeed = new MockAggregatorV3(8, int256(TSLA_PRICE), "TSLA");
        entropy = new MockEntropyV2();

        vault = new PrizeVault(multisig, address(usdc), 2_500);
        boxes =
            new Box(multisig, address(usdc), address(chip), treasury, address(vault), address(entropy), CHIP1, CHIP5);

        vm.startPrank(multisig);
        vault.setBox(address(boxes));
        vault.addStock(address(nvda), address(nvdaFeed), 8);
        vault.addStock(address(tsla), address(tslaFeed), 8);
        vm.stopPrank();

        _fundVault();
        _fundBuyer(alice);
        _fundBuyer(bob);
    }

    function _fundVault() internal {
        usdc.mint(address(vault), 10_000 * 1e6);
        nvda.mint(address(this), 1_000e8);
        tsla.mint(address(this), 1_000e8);
        nvda.approve(address(vault), type(uint256).max);
        tsla.approve(address(vault), type(uint256).max);
        vault.deposit(address(nvda), 1_000e8);
        vault.deposit(address(tsla), 1_000e8);
    }

    function _fundBuyer(address who) internal {
        usdc.mint(who, 1_000 * 1e6);
        chip.mint(who, 100_000 ether);
        vm.deal(who, 10 ether);
        vm.startPrank(who);
        usdc.approve(address(boxes), type(uint256).max);
        chip.approve(address(boxes), type(uint256).max);
        vm.stopPrank();
    }

    function _buy1(address who) internal returns (uint256 id) {
        vm.prank(who);
        id = boxes.buyWithUsdc(SKU1, who);
    }

    function _openAndFulfill(address who, uint256 id, bytes32 rand) internal {
        uint128 fee = boxes.quoteOpenFee();
        vm.prank(who);
        boxes.open{value: fee}(id);
        uint64 seq = boxes.boxInfo(id).sequence;
        entropy.fulfill(seq, rand);
    }

    function _rollForTier(uint8 tierId) internal view returns (bytes32) {
        IBox.PrizeTier[] memory tiers = boxes.oddsTable();
        uint256 acc;
        for (uint256 i; i < tierId; ++i) {
            acc += tiers[i].weight;
        }
        return bytes32(acc);
    }
}
