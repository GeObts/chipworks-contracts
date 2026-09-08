// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "./ChipRewardsBase.t.sol";
import {ChipRounds} from "../src/ChipRounds.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";

/// @title RouterGuardsTest
/// @notice `setRouters` refuses a router that cannot reach the pools the registry registered.
///
/// @dev WHY THIS SUITE EXISTS. `setRouters` used to accept anything at all — no zero check, no
///      `factory()` check. That was survivable only while the Slipstream branch was dead code:
///      every B20 stock registered as `Venue.UniswapV3`, so a wrong Slipstream router was
///      never called. Since ASSUMPTIONS A-22 the B20 pools are known to be on Aerodrome CL
///      **factory B**, ten of thirteen tickers register as `Venue.Slipstream`, and this is the
///      live buy path.
///
///      **The failure this prevents is quiet.** Two Aerodrome CL routers exist; they are the
///      same bytecode with different constructor arguments, and only one derives factory-B
///      pool addresses. Point the engine at the other and every buy reverts, on every round,
///      for every ticker — and the symptom reads like a depth problem, not a wiring one.
///
///      The expected factories are read from the REGISTRY, so the check is really "can this
///      router reach what we registered", not "is this a specific hardcoded address".
contract RouterGuardsTest is ChipRewardsBase {
    /* ------------------------------------------------------------------ */
    /*                         THE HAPPY PATH                              */
    /* ------------------------------------------------------------------ */

    /// @notice A correctly-paired set is accepted and stored.
    function test_routersMatchingTheRegistrysFactoriesAreAccepted() public {
        MockSwapRouter uni = new MockSwapRouter();
        uni.setFactory(address(uniFactory));
        MockSwapRouter slip = new MockSwapRouter();
        slip.setFactory(address(slipFactory));

        vm.prank(multisig);
        rounds.setRouters(address(uni), address(slip));

        assertEq(address(rounds.uniswapRouter()), address(uni));
        assertEq(address(rounds.slipstreamRouter()), address(slip));
    }

    /// @notice The check is against the registry's own immutables, not a hardcoded address.
    function test_theExpectedFactoriesComeFromTheRegistry() public view {
        assertEq(registry.uniswapV3Factory(), address(uniFactory));
        assertEq(registry.slipstreamFactory(), address(slipFactory));
    }

    /* ------------------------------------------------------------------ */
    /*                    A ROUTER ON THE WRONG FACTORY                    */
    /* ------------------------------------------------------------------ */

    /// @notice THE ONE THAT MATTERS. A Slipstream router bound to the wrong factory — the
    ///         real-world mistake, router A where router B was meant — is refused at
    ///         configuration time rather than reverting every buy later.
    function test_aSlipstreamRouterOnTheWrongFactoryIsRefused() public {
        MockSwapRouter uni = new MockSwapRouter();
        uni.setFactory(address(uniFactory));

        MockSwapRouter wrongSlip = new MockSwapRouter();
        wrongSlip.setFactory(address(uniFactory)); // belongs to the OTHER factory

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChipRounds.RouterNotOnFactory.selector, address(wrongSlip), address(slipFactory), address(uniFactory)
            )
        );
        rounds.setRouters(address(uni), address(wrongSlip));
    }

    /// @notice And the same in the other direction, so neither slot is special-cased.
    function test_aUniswapRouterOnTheWrongFactoryIsRefused() public {
        MockSwapRouter wrongUni = new MockSwapRouter();
        wrongUni.setFactory(address(slipFactory));

        MockSwapRouter slip = new MockSwapRouter();
        slip.setFactory(address(slipFactory));

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChipRounds.RouterNotOnFactory.selector, address(wrongUni), address(uniFactory), address(slipFactory)
            )
        );
        rounds.setRouters(address(wrongUni), address(slip));
    }

    /// @notice A router that reports a factory nobody has heard of is refused, and the revert
    ///         names both what was expected and what it actually said.
    function test_aRouterOnAnUnrelatedFactoryIsRefused() public {
        address nowhere = makeAddr("someOtherFactory");
        MockSwapRouter uni = new MockSwapRouter();
        uni.setFactory(address(uniFactory));
        MockSwapRouter slip = new MockSwapRouter();
        slip.setFactory(nowhere);

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(ChipRounds.RouterNotOnFactory.selector, address(slip), address(slipFactory), nowhere)
        );
        rounds.setRouters(address(uni), address(slip));
    }

    /* ------------------------------------------------------------------ */
    /*                      ZERO AND NON-CONTRACTS                         */
    /* ------------------------------------------------------------------ */

    /// @notice Neither slot may be zero, even though only one venue is in use today.
    function test_aZeroSlipstreamRouterIsRefused() public {
        MockSwapRouter uni = new MockSwapRouter();
        uni.setFactory(address(uniFactory));

        vm.prank(multisig);
        vm.expectRevert(ChipRounds.ZeroAddress.selector);
        rounds.setRouters(address(uni), address(0));
    }

    function test_aZeroUniswapRouterIsRefused() public {
        MockSwapRouter slip = new MockSwapRouter();
        slip.setFactory(address(slipFactory));

        vm.prank(multisig);
        vm.expectRevert(ChipRounds.ZeroAddress.selector);
        rounds.setRouters(address(0), address(slip));
    }

    /// @notice An EOA cannot be a router. Caught before the `factory()` staticcall, which
    ///         would otherwise succeed-with-empty-returndata against an account with no code.
    function test_anEoaIsRefused() public {
        address eoa = makeAddr("notARouter");
        MockSwapRouter slip = new MockSwapRouter();
        slip.setFactory(address(slipFactory));

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ChipRounds.NotAContract.selector, eoa));
        rounds.setRouters(eoa, address(slip));
    }

    /// @notice A contract that cannot answer `factory()` at all is refused, reported with a
    ///         zero "actual" so the two failure shapes stay distinguishable.
    function test_aContractWithNoFactoryFunctionIsRefused() public {
        Mute mute = new Mute();
        MockSwapRouter slip = new MockSwapRouter();
        slip.setFactory(address(slipFactory));

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChipRounds.RouterNotOnFactory.selector, address(mute), address(uniFactory), address(0)
            )
        );
        rounds.setRouters(address(mute), address(slip));
    }

    /* ------------------------------------------------------------------ */
    /*                           ACCESS CONTROL                            */
    /* ------------------------------------------------------------------ */

    /// @notice Still multisig-only. The guard is about correctness, not about who may call.
    function test_onlyTheMultisigCanSetRouters() public {
        MockSwapRouter uni = new MockSwapRouter();
        uni.setFactory(address(uniFactory));
        MockSwapRouter slip = new MockSwapRouter();
        slip.setFactory(address(slipFactory));

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        rounds.setRouters(address(uni), address(slip));
    }

    /// @notice A rejected call changes nothing — the previously configured pair survives.
    function test_aRejectedSetLeavesTheExistingRoutersInPlace() public {
        address uniBefore = address(rounds.uniswapRouter());
        address slipBefore = address(rounds.slipstreamRouter());

        MockSwapRouter wrong = new MockSwapRouter();
        wrong.setFactory(makeAddr("elsewhere"));

        vm.prank(multisig);
        vm.expectRevert();
        rounds.setRouters(address(wrong), address(wrong));

        assertEq(address(rounds.uniswapRouter()), uniBefore, "unchanged");
        assertEq(address(rounds.slipstreamRouter()), slipBefore, "unchanged");
    }
}

/// @notice A contract with code but no `factory()`.
contract Mute {
    uint256 public x;
}
