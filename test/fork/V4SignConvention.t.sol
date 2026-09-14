// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "../../src/interfaces/IUniswapV4.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * WHICH SIGN OF `amountSpecified` MEANS WHAT.
 *
 * Settled by running both, against the real pool, rather than by quoting a doc.
 * The whole of ChipLottery's cost model rests on this one convention.
 */
contract V4SignConventionTest is Test, IUnlockCallback {
    using SafeERC20 for IERC20;

    address constant CHIP = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant HOOK = 0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544;

    IPoolManager pm = IPoolManager(POOL_MANAGER);
    PoolKey key;

    int256 lastAmount0;
    int256 lastAmount1;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        require(bytes(rpc).length > 0, "BASE_RPC_URL is required");
        vm.createSelectFork(rpc);
        key = PoolKey({currency0: WETH, currency1: CHIP, fee: 8_388_608, tickSpacing: 200, hooks: HOOK});
        deal(CHIP, address(this), 100_000_000 ether);
    }

    function _run(int256 amountSpecified) internal {
        pm.unlock(abi.encode(amountSpecified));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == POOL_MANAGER, "not pm");
        int256 amountSpecified = abi.decode(data, (int256));

        int256 delta = pm.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341
            }),
            ""
        );

        lastAmount1 = int128(delta);
        lastAmount0 = int128(delta >> 128);

        // settle whatever is owed so the lock can close
        if (lastAmount1 < 0) {
            pm.sync(CHIP);
            IERC20(CHIP).safeTransfer(POOL_MANAGER, uint256(-lastAmount1));
            pm.settle();
        }
        if (lastAmount0 > 0) pm.take(WETH, address(this), uint256(lastAmount0));
        return "";
    }

    /// @dev 4e14 is a WETH-sized number. If positive meant exact INPUT, it would be
    ///      read as 0.0004 $CHIP of input and the WETH out would be dust.
    function test_positiveAmountSpecifiedIsExactOUTPUT() public {
        int256 want = 399509600000000; // 0.0003995096 WETH
        _run(want);

        emit log_named_int("amount0 (WETH)", lastAmount0);
        emit log_named_int("amount1 (CHIP)", lastAmount1);

        assertEq(lastAmount0, want, "POSITIVE gave exactly the WETH asked for -> exact OUTPUT");
        assertLt(lastAmount1, 0, "CHIP side is owed to the pool");
    }

    /// @dev The mirror. Negative must be exact INPUT: spend exactly this much $CHIP.
    function test_negativeAmountSpecifiedIsExactINPUT() public {
        int256 spend = 1_000_000 ether; // 1,000,000 CHIP in
        _run(-spend);

        emit log_named_int("amount0 (WETH)", lastAmount0);
        emit log_named_int("amount1 (CHIP)", lastAmount1);

        assertEq(lastAmount1, -spend, "NEGATIVE spent exactly the CHIP named -> exact INPUT");
        assertGt(lastAmount0, 0, "WETH came back");
    }

    /// @dev What the audit's proposed fix would actually do: -int256(wethOut) is read
    ///      as "spend 0.0003995096 CHIP", which buys essentially nothing.
    function test_theProposedFixWouldSpendChipNotBuyWeth() public {
        int256 wethOut = 399509600000000;
        _run(-wethOut);

        emit log_named_int("amount0 (WETH) from the proposed fix", lastAmount0);
        emit log_named_int("amount1 (CHIP) from the proposed fix", lastAmount1);

        assertEq(lastAmount1, -wethOut, "it spends 0.0004 CHIP as INPUT");
        assertLt(uint256(lastAmount0), 1_000_000, "and buys a rounding error of WETH");
    }
}
