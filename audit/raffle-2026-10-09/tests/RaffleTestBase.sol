// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Raffle} from "../../src/raffle/Raffle.sol";
import {Venue} from "../../src/interfaces/IStockRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockEntropyV2} from "../mocks/MockEntropyV2.sol";
import {MockStockRegistry} from "../mocks/MockStockRegistry.sol";
import {MockNoun} from "../mocks/MockNoun.sol";

/// @notice The Raffle on mocks. Entropy fee 0.00002 ETH (Base, 2026-10-08), so the minimum
///         reserve is 0.00006 ETH.
contract RaffleTestBase is Test {
    Raffle internal raffle;
    MockERC20 internal usdc;
    MockERC20 internal nvda;
    MockStockRegistry internal registry;
    MockEntropyV2 internal entropy;
    MockNoun internal noun;

    address internal house = makeAddr("house"); // the Safe: owner, creator and payee
    address internal pot = makeAddr("pot");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint128 internal constant FEE = 0.00002 ether;
    uint256 internal constant RESERVE = 3 * uint256(FEE);
    uint256 internal constant PRIZE = 5e7; // 0.5 NVDAc (8 dp)

    function setUp() public virtual {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        nvda = new MockERC20("NVIDIA", "NVDAc", 8);
        registry = new MockStockRegistry(address(usdc));
        registry.setStock(address(nvda), Venue.Slipstream, 0, 10, 8, true);
        entropy = new MockEntropyV2();
        entropy.setFee(FEE);
        noun = new MockNoun("Based Nouns", "NOUN");
        raffle = new Raffle(house, address(usdc), address(entropy), address(registry), pot, 1 hours);

        nvda.mint(house, 1_000e8);
        vm.deal(house, 10 ether);
        vm.prank(house);
        nvda.approve(address(raffle), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            address a = [alice, bob, carol][i];
            usdc.mint(a, 1_000_000e6);
            vm.prank(a);
            usdc.approve(address(raffle), type(uint256).max);
        }
    }

    function _erc20Prize(address token, uint256 amount) internal pure returns (Raffle.Prize memory) {
        return Raffle.Prize({kind: Raffle.PrizeKind.ERC20, token: token, amountOrId: amount});
    }

    function _create(uint64 base) internal returns (uint256 id) {
        vm.prank(house);
        id = raffle.createRaffle{value: RESERVE}(_erc20Prize(address(nvda), PRIZE), base, house);
    }

    function _buy(address who, uint256 id, uint64 qty) internal {
        vm.prank(who);
        raffle.buy(id, qty);
    }

    function _state(uint256 id) internal view returns (Raffle.State) {
        return raffle.getRaffle(id).state;
    }

    /// @dev Deliver the reveal for raffle `id` as Entropy does.
    function _reveal(uint256 id, bytes32 rnd) internal {
        entropy.fulfill(raffle.getRaffle(id).sequence, rnd);
    }

    /// @dev A random number whose draw lands on ticket `t` of a raffle with `n` tickets.
    function _rndFor(uint64 t, uint64 n) internal pure returns (bytes32) {
        return bytes32(uint256(n) * 7919 + t);
    }
}
