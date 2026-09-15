// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * A B20 STOCK CANNOT BE READ INSIDE A FORK, AND THIS PINS IT.
 *
 * The B20 stocks are node-native precompiles (ASSUMPTIONS A-15/A-17). On a real
 * node `balanceOf` answers; inside forge's EVM the address carries a single
 * placeholder byte and the call burns the entire gas limit before reverting.
 *
 * That looks exactly like a broken contract when it appears in an unrelated test,
 * and it cost an hour once. It is written down here so the next person reads the
 * failure correctly: any fork test needing B20 balances must assert them over RPC
 * instead - which is how the claims solvency sweep does it.
 */
contract B20ProbeTest is Test {
    address constant NVDA = 0xb20000000000000000000078ee7ce2fE4908108C;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CLAIMS = 0x9bD35c70a80F132d087719305E37A888204d4c80;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    }

    /// @dev The control: an ordinary ERC-20 reads fine.
    function test_anOrdinaryErc20ReadsInAFork() public {
        uint256 bal = IERC20(USDC).balanceOf(CLAIMS);
        assertGt(bal, 0, "USDC should read");
        emit log_named_decimal_uint("USDC held by ChipClaims", bal, 6);
    }

    /// @dev One byte of code. Not a contract in any executable sense.
    function test_aB20StockHasNoRealCodeInAFork() public {
        assertEq(NVDA.code.length, 1, "a B20 stock is a precompile, not bytecode");
    }

    /// @dev And so reading it reverts, consuming everything.
    function test_aB20BalanceReadRevertsInAFork() public {
        vm.expectRevert();
        IERC20(NVDA).balanceOf(CLAIMS);
    }
}
