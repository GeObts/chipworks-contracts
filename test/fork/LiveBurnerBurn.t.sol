// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ChipBurner} from "../../src/ChipBurner.sol";

/// @title LiveBurnerBurnForkTest
/// @notice Does the ALREADY-DEPLOYED ChipBurner actually destroy $CHIP, given that the Doppler
///         factory owns the token permanently and ownership can never be transferred to us?
///
/// @dev THE QUESTION THIS SETTLES. LAUNCH_CONFIG was written believing $CHIP's `burn` was
///      owner-gated, so it required handing the token's ownership to `ChipBurner` before burns
///      would work. Bankr have since said ownership is permanently held by the Doppler factory
///      and `burn(uint256)` is a standard public burn of the caller's OWN balance.
///
///      If that is right, the hand-off was never needed: `burnAll()` calls
///      `chipToken.burn(balanceOf(this))` as an ordinary external call and the token burns the
///      Burner's own tokens. If it is wrong — if the token really does gate `burn` on
///      ownership — this test fails and the deployed Burner is a brick that must be redeployed.
///
///      Nothing here is hypothetical: it runs against the REAL token and the REAL deployed
///      Burner at their mainnet addresses, funded from a REAL holder.
contract LiveBurnerBurnForkTest is Test {
    address internal constant CHIP = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;
    address internal constant BURNER = 0x7Bc1C03e843C37845d89B54667382b4577Ead5C0;

    /// @dev The Chipworks Safe, which holds ~1.305e27 $CHIP on mainnet.
    address internal constant HOLDER = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;

    uint256 internal constant AMOUNT = 1e18;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    }

    /// @notice The deployed Burner destroys $CHIP with no ownership of the token whatsoever.
    function test_theDeployedBurnerTrulyBurnsWithoutOwningTheToken() public {
        // The premise: we do NOT own the token and never will.
        (bool ok, bytes memory ret) = CHIP.staticcall(abi.encodeWithSignature("owner()"));
        address tokenOwner = ok && ret.length >= 32 ? abi.decode(ret, (address)) : address(0);
        assertTrue(tokenOwner != BURNER, "premise: the Burner must NOT be the token owner");
        console2.log("token owner (not us, never will be):", tokenOwner);

        assertGt(BURNER.code.length, 0, "the deployed Burner has code");
        assertEq(address(ChipBurner(BURNER).chipToken()), CHIP, "Burner is bound to the live $CHIP");

        // Fund the Burner from a real holder, exactly as an app burn path would.
        vm.prank(HOLDER);
        IERC20(CHIP).transfer(BURNER, AMOUNT);
        assertEq(IERC20(CHIP).balanceOf(BURNER), AMOUNT, "Burner funded");

        uint256 supplyBefore = IERC20(CHIP).totalSupply();
        uint256 burnedBefore = ChipBurner(BURNER).totalBurned();
        uint256 countBefore = ChipBurner(BURNER).burnCount();

        // Permissionless: a random address triggers it, not the multisig, not the owner.
        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        uint256 burned = ChipBurner(BURNER).burnAll();

        uint256 supplyAfter = IERC20(CHIP).totalSupply();

        console2.log("supply before:", supplyBefore);
        console2.log("supply after :", supplyAfter);
        console2.log("burned       :", burned);

        // THE ASSERTIONS THAT DECIDE IT.
        assertEq(burned, AMOUNT, "burnAll reported the full amount");
        assertEq(supplyAfter, supplyBefore - AMOUNT, "TOTAL SUPPLY ACTUALLY FELL - the burn is real");
        assertEq(IERC20(CHIP).balanceOf(BURNER), 0, "the Burner kept nothing");
        assertEq(ChipBurner(BURNER).totalBurned(), burnedBefore + AMOUNT, "totalBurned credited");
        assertEq(ChipBurner(BURNER).burnCount(), countBefore + 1, "burnCount incremented");
    }

    /// @notice And the token's `burn` really is public - any holder can burn their own balance.
    /// @dev Proves Bankr's claim directly rather than inferring it from the Burner working.
    function test_theTokensBurnIsPublicNotOwnerGated() public {
        uint256 supplyBefore = IERC20(CHIP).totalSupply();

        vm.prank(HOLDER); // an ordinary holder, not the token owner
        (bool ok,) = CHIP.call(abi.encodeWithSignature("burn(uint256)", AMOUNT));

        assertTrue(ok, "burn(uint256) reverted for an ordinary holder - it IS owner-gated");
        assertEq(IERC20(CHIP).totalSupply(), supplyBefore - AMOUNT, "supply fell for a plain holder");
    }

    /// @notice The two pass-throughs DO still revert, and that is harmless.
    /// @dev They were only ever useful if the Burner became the token owner. It cannot, so they
    ///      are dead weight - not a fault. Recorded so nobody later reads a revert here as a
    ///      sign the Burner is broken.
    function test_thePassThroughsAreDeadWeightAndThatIsFine() public {
        address multisig = ChipBurner(BURNER).owner();

        vm.prank(multisig);
        vm.expectRevert(); // PassThroughFailed - the token refuses a non-owner
        ChipBurner(BURNER).updateTokenUri("ipfs://whatever");

        vm.prank(multisig);
        vm.expectRevert(); // same
        ChipBurner(BURNER).transferTokenOwnership(multisig);
    }
}
