// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ChipRounds} from "../src/ChipRounds.sol";
import {ChipClaims} from "../src/ChipClaims.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {POLTreasury} from "../src/POLTreasury.sol";
import {Pot} from "../src/Pot.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {ClaimRouter} from "../src/ClaimRouter.sol";
import {ClutchVaultAdapter} from "../src/adapters/ClutchVaultAdapter.sol";

/// @title CodeSizeTest
/// @notice Fails the build if any deployable contract grows past the budget.
///
/// @dev THIS EXISTS BECAUSE THE PROBLEM WAS ALREADY MISSED ONCE. ChipRewards reached 27,551
///      bytes — nearly 3KB over the EIP-170 limit of 24,576 — and a full suite of 362 tests
///      passed without noticing, because **Foundry exempts test-deployed contracts from the
///      code size limit**. It was only caught when an external tool tried a real deployment.
///
///      So the check cannot rely on deployment failing. It reads `.code.length` directly,
///      which is the same number a chain would enforce.
///
///      The budget is 24,000, not 24,576. The 576-byte gap is deliberate headroom: a
///      contract that creeps to 24,500 is one small change away from being undeployable,
///      and finding that out at deploy time is exactly the failure this test prevents.
contract CodeSizeTest is Test {
    /// @notice Hard EVM limit. Exceeding this makes a contract undeployable.
    uint256 internal constant EIP170_LIMIT = 24_576;

    /// @notice Our budget, deliberately below the limit so there is room to fix a bug.
    uint256 internal constant SIZE_BUDGET = 24_000;

    address internal multisig = makeAddr("multisig");

    function _check(string memory name, address deployed) internal {
        uint256 size = deployed.code.length;
        console2Log(name, size);

        if (size > EIP170_LIMIT) {
            emit log_named_uint(string.concat("UNDEPLOYABLE, over EIP-170: ", name), size);
        }
        assertLe(
            size,
            SIZE_BUDGET,
            string.concat(
                name,
                " exceeds the 24,000 byte budget. Split it by responsibility rather than shaving bytes; ",
                "see AUDIT_BRIEF section 1."
            )
        );
    }

    function console2Log(string memory name, uint256 size) internal {
        emit log_named_uint(string.concat("size  ", name), size);
    }

    function test_everyDeployableContractIsWithinBudget() public {
        // Constructor arguments are irrelevant to runtime size; these only need to be valid.
        address registry = address(new StockRegistry(multisig, _erc20(), _factory(), _factory()));
        address claims = address(new ChipClaims(multisig, registry));
        address pot = address(new Pot(multisig, _erc20()));
        address adapter = address(new ClutchVaultAdapter(multisig, [uint32(10_000), 12_500, 16_000, 20_000, 33_300]));

        _check("StockRegistry", registry);
        _check("ChipClaims", claims);
        _check("Pot", pot);
        _check("ClutchVaultAdapter", adapter);

        _check("ChipRounds", address(new ChipRounds(multisig, registry, pot, adapter, claims, 5_000 ether)));
        _check("FeeSplitter", address(new FeeSplitter(multisig, multisig, multisig, 2_000, 2_000)));
        _check("POLTreasury", address(new POLTreasury(multisig, _erc20(), _nft(), multisig)));
        _check("ClaimRouter", address(new ClaimRouter(multisig, claims, adapter, 1_000_000)));
    }

    /* --------------------------- tiny stand-ins --------------------------- */

    function _erc20() internal returns (address a) {
        a = address(new SizeStubERC20());
    }

    function _factory() internal returns (address a) {
        a = address(new SizeStub());
    }

    function _nft() internal returns (address a) {
        a = address(new SizeStub());
    }
}

contract SizeStub {
    fallback() external {}
}

contract SizeStubERC20 {
    function decimals() external pure returns (uint8) {
        return 6;
    }

    fallback() external {}
}
