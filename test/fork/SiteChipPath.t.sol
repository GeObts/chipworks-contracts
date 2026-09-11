// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ChipActivationV2} from "../../src/activation/ChipActivationV2.sol";

/// @notice Reproduces, then fixes, the bug that made EVERY chip on the site revert.
///
/// @dev The site built its approval with `BigInt(Math.round(unit * 1e18))`, where `unit`
///      is a JS number of whole $CHIP. For a 1,000,000 $CHIP tier that expression is
///      1e24, which is far past Number.MAX_SAFE_INTEGER — float64 lands on the nearest
///      representable integer instead, 999999999999999983222784, and BigInt() converts
///      that wrong number faithfully. The approval went out 2^24 wei short, transferFrom
///      failed its allowance check, and the transaction reverted.
///
///      Observed on mainnet: tx 0xa35f104a…, Based Noun #2124, reverted with 0 logs,
///      allowance left standing at 999999.999999999983222784 against a 1,000,000 cost.
contract SiteChipPathForkTest is Test {
    address constant V2 = 0x762984092Cb9404982835551970C73b5838d5411;
    address constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
    address constant CHIP = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;
    address constant BURNER = 0x7Bc1C03e843C37845d89B54667382b4577Ead5C0;
    address constant BASED = 0xBf57D0535E10E7033447174404b9bEd3D9eF4C88;
    address constant CHIPLETS = 0xC7c114191aa3b2225F9bb053Bc55b3d6F145Bd33;

    /// The wallet that actually hit this on mainnet, and the Noun it tried to chip.
    address constant HOLDER = 0xCE1Db3439F5972a9E9Ca31450827bc25626302c4;
    uint256 constant NOUN = 2124;

    /// What the site approved, byte for byte. NOT 1e24.
    uint256 constant FLOAT_WEI = 999999999999999983222784;
    /// What the contract charges.
    uint256 constant EXACT_WEI = 1_000_000 ether;

    ChipActivationV2 act = ChipActivationV2(payable(V2));

    function _forked() internal view returns (bool) {
        return block.chainid == 8453;
    }

    /// The float is genuinely a different number. This is the whole bug in one assert.
    function test_theFloatApprovalIsShort() public pure {
        assertLt(FLOAT_WEI, EXACT_WEI, "float was not short");
        assertEq(EXACT_WEI - FLOAT_WEI, 16777216, "shortfall is not 2^24 wei");
    }

    /// REPRODUCTION: approve what the site approved, and watch the chip revert.
    function test_reproduce_floatApprovalReverts() public {
        if (!_forked()) { console2.log("skipped: not forked"); return; }

        assertEq(act.costOf(BASED, 0), EXACT_WEI, "tier 1 is not 1,000,000 CHIP");
        assertEq(IERC721(BASED).ownerOf(NOUN), HOLDER, "holder no longer owns #2124");

        vm.prank(HOLDER);
        IERC20(CHIP).approve(V2, FLOAT_WEI);

        vm.prank(HOLDER);
        vm.expectRevert();
        act.activate(BASED, NOUN, 0);

        assertFalse(act.isActive(BASED, NOUN), "it chipped on a short allowance");
        console2.log("reproduced: approving", FLOAT_WEI);
        console2.log("            charging ", EXACT_WEI);
        console2.log("            reverts, exactly as tx 0xa35f104a did");
    }

    /// THE FIX: approve the bigint the contract reported, unconverted. It goes through.
    function test_fix_exactApprovalChips() public {
        if (!_forked()) return;

        uint256 burner0 = IERC20(CHIP).balanceOf(BURNER);
        uint256 safe0 = IERC20(CHIP).balanceOf(SAFE);

        vm.prank(HOLDER);
        IERC20(CHIP).approve(V2, EXACT_WEI);

        vm.prank(HOLDER);
        act.activate(BASED, NOUN, 0);

        assertTrue(act.isActive(BASED, NOUN), "#2124 did not chip");
        ChipActivationV2.Activation memory a = act.activationOf(BASED, NOUN);
        assertEq(a.tier, 0, "wrong tier recorded");

        uint256 half = EXACT_WEI / 2;
        assertEq(IERC20(CHIP).balanceOf(BURNER) - burner0, half, "burn leg wrong");
        assertEq(IERC20(CHIP).balanceOf(SAFE) - safe0, half, "collect leg wrong");
        assertEq(IERC20(CHIP).allowance(HOLDER, V2), 0, "allowance not fully consumed");

        console2.log("fixed: #2124 chipped with the exact bigint");
        console2.log("  burned to ChipBurner :", half / 1e18);
        console2.log("  collected to Safe    :", half / 1e18);
    }

    /// The site's OLD call on a Chiplet. This is why Chiplet chipping was dead.
    function test_chiplets_activateReverts_activateFlatIsTheWayIn() public {
        if (!_forked()) return;

        assertTrue(act.isFlatRate(CHIPLETS), "Chiplets are not flat-rate");

        vm.prank(HOLDER);
        vm.expectRevert(
            abi.encodeWithSelector(ChipActivationV2.WrongActivationKind.selector, CHIPLETS)
        );
        act.activate(CHIPLETS, 1, 0);

        console2.log("confirmed: activate() on Chiplets reverts WrongActivationKind");
        console2.log("  flat cost:", act.costOf(CHIPLETS, 0) / 1e18, "CHIP + one Chiplet");
    }

    /// THE FLAT PATH, end to end, with two real Chiplets and a real supply drop.
    function test_flat_chipletBurnsASecondChipletAndSupplyFalls() public {
        if (!_forked()) return;

        // Ids start at 1 and 1-2 are held by one wallet today, which is the shape
        // the picker requires: two Chiplets, same owner, one paying for the other.
        uint256 keep = 1;
        uint256 burn = 2;
        address owner = IERC721(CHIPLETS).ownerOf(keep);
        assertEq(IERC721(CHIPLETS).ownerOf(burn), owner, "ids 1 and 2 are not one wallet");

        uint256 cost = act.costOf(CHIPLETS, 0);
        vm.prank(SAFE);
        IERC20(CHIP).transfer(owner, cost);
        vm.prank(owner);
        IERC20(CHIP).approve(V2, cost);

        /*
          THE THIRD SIGNATURE. Without it activateFlat reverts.

          Chiplets is an ERC721SeaDrop (ERC721A underneath) and its burn(tokenId)
          checks the CALLER, not the token's owner: _burn(tokenId, approvalCheck=true).
          ChipActivationV2 calls that burn itself, so unless the holder has approved
          the activation contract as an operator, both legs of _consumeToken fail -
          burn() with TransferCallerNotOwnerNorApproved, and then the 0xdead fallback
          transferFrom with the same error, because that is also called by V2.

          Discovered on a fork before anyone paid for it. Approving the whole
          collection rather than one token is deliberate on the site's side: an
          approve(tokenId) is consumed by the burn and every later Chiplet chip would
          need another signature.
        */
        vm.prank(owner);
        IERC721(CHIPLETS).setApprovalForAll(V2, true);

        uint256 chipletsBefore = IChiplets(CHIPLETS).totalSupply();
        uint256 burner0 = IERC20(CHIP).balanceOf(BURNER);
        uint256 safe0 = IERC20(CHIP).balanceOf(SAFE);

        vm.prank(owner);
        act.activateFlat(CHIPLETS, keep, burn);

        assertTrue(act.isActive(CHIPLETS, keep), "the kept Chiplet did not activate");
        assertEq(
            IChiplets(CHIPLETS).totalSupply(),
            chipletsBefore - 1,
            "CHIPLET SUPPLY DID NOT FALL - the sacrifice was not a true burn"
        );
        assertEq(IERC20(CHIP).balanceOf(BURNER) - burner0, cost / 2, "burn leg wrong");
        assertEq(IERC20(CHIP).balanceOf(SAFE) - safe0, cost / 2, "collect leg wrong");

        // And the one that was burned is gone, not merely moved.
        vm.expectRevert();
        IERC721(CHIPLETS).ownerOf(burn);

        console2.log("flat path proven end to end");
        console2.log("  Chiplet supply before:", chipletsBefore);
        console2.log("  Chiplet supply after :", IChiplets(CHIPLETS).totalSupply());
        console2.log("  CHIP charged         :", cost / 1e18);
    }

    /// The approval is not optional, and this is the proof it is load-bearing.
    function test_flat_withoutTheNftApproval_itReverts() public {
        if (!_forked()) return;

        uint256 keep = 1;
        uint256 burn = 2;
        address owner = IERC721(CHIPLETS).ownerOf(keep);
        uint256 cost = act.costOf(CHIPLETS, 0);

        vm.prank(SAFE);
        IERC20(CHIP).transfer(owner, cost);
        vm.prank(owner);
        IERC20(CHIP).approve(V2, cost);

        // $CHIP approved, Chiplets NOT approved. This is what the site used to send.
        assertFalse(
            IERC721(CHIPLETS).isApprovedForAll(owner, V2),
            "already approved - test proves nothing"
        );

        vm.prank(owner);
        vm.expectRevert(); // TransferCallerNotOwnerNorApproved from ERC721A
        act.activateFlat(CHIPLETS, keep, burn);

        console2.log("confirmed: activateFlat needs setApprovalForAll on Chiplets");
    }

    /// The three refusals the picker has to prevent, straight from the contract.
    function test_flat_theThreeRefusals() public {
        if (!_forked()) return;

        uint256 id = 1;
        address owner = IERC721(CHIPLETS).ownerOf(id);
        uint256 cost = act.costOf(CHIPLETS, 0);

        vm.prank(SAFE);
        IERC20(CHIP).transfer(owner, cost);
        vm.prank(owner);
        IERC20(CHIP).approve(V2, cost);

        // 1. A Chiplet cannot pay for itself.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ChipActivationV2.CannotSacrificeItself.selector, id)
        );
        act.activateFlat(CHIPLETS, id, id);

        // 2. The sacrifice must be held by the caller.
        address stranger = address(0xBEEF);
        vm.prank(stranger);
        vm.expectRevert();
        act.activateFlat(CHIPLETS, id, id + 1);

        console2.log("refusals confirmed: self-sacrifice and foreign sacrifice both revert");
    }
}

/// Chiplets is NOT ERC-721Enumerable - tokenByIndex and tokenOfOwnerByIndex both
/// revert - but it does carry totalSupply(), which is what the burn proof needs.
interface IChiplets {
    function totalSupply() external view returns (uint256);
}
