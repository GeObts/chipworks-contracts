// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Raffle} from "../../src/raffle/Raffle.sol";
import {Venue} from "../../src/interfaces/IStockRegistry.sol";
import {MockEntropyV2} from "../mocks/MockEntropyV2.sol";
import {MockStockRegistry} from "../mocks/MockStockRegistry.sol";
import {BlacklistToken} from "../mocks/HostileTokens.sol";
import {MockSlipstreamPool, MockSlipstreamFactory, MockSlipstreamRouter} from "../mocks/MockSlipstream.sol";

/// @notice Raffle v2 on mocks. NVDAc trades at $250 in a USDC/NVDAc Slipstream pool (USDC is
///         token0): one raw USDC unit buys 0.4 raw NVDAc units (6 vs 8 decimals). Entropy fee
///         0.00002 ETH, so the minimum reserve is 0.00006 ETH. USDC and the stock are both
///         blacklistable, to model B20 / Circle refusals.
contract RaffleTestBase is Test {
    Raffle internal raffle;
    BlacklistToken internal usdc;
    BlacklistToken internal nvda;
    MockStockRegistry internal registry;
    MockEntropyV2 internal entropy;
    MockSlipstreamFactory internal factory;
    MockSlipstreamPool internal pool;
    MockSlipstreamRouter internal router;

    address internal house = makeAddr("house"); // the Safe: owner and creator
    address internal keeperAcct = makeAddr("keeper");
    address internal pot = makeAddr("pot");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint128 internal constant FEE = 0.00002 ether;
    uint256 internal constant RESERVE = 3 * uint256(FEE);
    int24 internal constant SPACING = 10;
    /// @dev $250: 0.4 raw NVDAc per raw USDC. floor(log_1.0001(0.4)) = -9164.
    uint256 internal constant PRICE_NUM = 4;
    uint256 internal constant PRICE_DEN = 10;
    int24 internal constant SPOT_TICK = -9164;
    uint256 internal constant POOL_USDC = 10_000_000e6; // 1% cap = $100k

    function setUp() public virtual {
        usdc = new BlacklistToken("USD Coin", "USDC", 6);
        nvda = new BlacklistToken("NVIDIA", "NVDAc", 8);
        registry = new MockStockRegistry(address(usdc));
        factory = new MockSlipstreamFactory();
        registry.setSlipstreamFactory(address(factory));
        router = new MockSlipstreamRouter(address(factory));
        pool = _newPool(address(nvda));

        entropy = new MockEntropyV2();
        entropy.setFee(FEE);
        raffle = new Raffle(house, address(usdc), address(entropy), address(registry), pot, address(router), 1 hours, 6 hours);
        vm.prank(house);
        raffle.setKeeper(keeperAcct);

        vm.deal(house, 10 ether);
        for (uint256 i; i < 3; ++i) {
            address a = [alice, bob, carol][i];
            usdc.mint(a, 1_000_000e6);
            vm.prank(a);
            usdc.approve(address(raffle), type(uint256).max);
        }
    }

    /// @dev A registry-enabled stock with a USDC pool at $250 that the factory and router know.
    function _newPool(address stock) internal returns (MockSlipstreamPool p) {
        registry.setStock(stock, Venue.Slipstream, 0, SPACING, 8, true);
        p = new MockSlipstreamPool(address(usdc), stock, SPACING);
        p.setSpot(_sqrtPriceFor(PRICE_NUM, PRICE_DEN), SPOT_TICK);
        p.setTwapTick(SPOT_TICK);
        registry.setPool(stock, address(p));
        factory.setPool(address(usdc), stock, SPACING, address(p));
        usdc.mint(address(p), POOL_USDC);
        BlacklistToken(stock).mint(address(router), 1_000_000e8);
    }

    /// @dev sqrtPriceX96 for a token1/token0 price of num/den, independently of the contract.
    function _sqrtPriceFor(uint256 num, uint256 den) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(num, 1 << 192, den)));
    }

    /// @dev Raw NVDAc that `usdcAmount` buys at exactly $250 — the test's own reference.
    function _expectedOut(uint256 usdcAmount) internal pure returns (uint256) {
        return (usdcAmount * PRICE_NUM) / PRICE_DEN;
    }

    function _create(uint64 base) internal returns (uint256 id) {
        vm.prank(house);
        id = raffle.createRaffle{value: RESERVE}(address(nvda), base);
    }

    function _buy(address who, uint256 id, uint64 qty) internal {
        vm.prank(who);
        raffle.buy(id, qty);
    }

    /// @dev Sell every ticket to `who`.
    function _sellOut(uint256 id, address who) internal {
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        _buy(who, id, r.totalTickets - r.sold);
    }

    /// @dev The keeper buys the prize; the router fills 0.1% under the $250 reference.
    function _acquire(uint256 id) internal {
        uint256 budget = uint256(raffle.getRaffle(id).base) * 1e6;
        router.setFillOut((_expectedOut(budget) * 9_990) / 10_000);
        vm.prank(keeperAcct);
        raffle.acquirePrize(id);
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
