// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ChipBurner} from "../src/ChipBurner.sol";

/// @title ChipBurnerReentrancyTest
/// @notice The published burn figure cannot be inflated by the token it burns.
///
/// @dev WHAT THIS SUITE DEFENDS. `burnAll` derives `burned` from a `totalSupply` reading taken
///      either side of a call into a token this contract does not control. Two things could
///      corrupt that figure, and neither costs anybody a single $CHIP — the tokens are
///      destroyed either way and there is still no path that moves them out. What breaks is
///      the number, which is the entire reason the contract exists.
///
///        1. **Re-entry.** A token whose `burn` calls back into `burnAll` would have the inner
///           call credit `totalBurned`, and then the outer call would compute its own figure
///           from a supply delta spanning *both* burns and credit it a second time.
///        2. **Burning somebody else's tokens.** A token that destroys supply belonging to
///           another holder during our `burn` would widen the supply delta, and the Burner
///           would take credit for it.
///
///      Slither reports the first as `reentrancy-benign`. It is benign for funds; it is not
///      benign for the figure. `nonReentrant` answers the first and bounding `burned` by this
///      contract's own balance drop answers the second.
contract ChipBurnerReentrancyTest is Test {
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant QUEUED = 10_000 ether;

    address internal multisig = makeAddr("multisig");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    /* ------------------------------------------------------------------ */
    /*                          RE-ENTRY IS REFUSED                        */
    /* ------------------------------------------------------------------ */

    /// @notice A token that re-enters `burnAll` cannot make the burn count lie. The re-entrant
    ///         inner call is refused, and the outer call reports exactly one burn.
    function test_aReentrantTokenCannotInflateTheBurnCount() public {
        ReentrantChip chip = new ReentrantChip(SUPPLY);
        ChipBurner burner = new ChipBurner(multisig, address(chip));
        chip.transferOwnership(address(burner));
        chip.arm(address(burner));

        chip.transfer(address(burner), QUEUED);

        vm.prank(keeper);
        uint256 burned = burner.burnAll();

        // The token DID try to come back in, so this is not a vacuous pass.
        assertTrue(chip.reentryAttempted(), "the token never actually re-entered");
        assertTrue(chip.reentryReverted(), "the guard did not stop it");

        assertEq(burned, QUEUED, "credited exactly what was queued");
        assertEq(burner.totalBurned(), QUEUED, "and not a wei more");
        assertEq(burner.burnCount(), 1, "one burn, counted once");
        assertEq(chip.totalSupply(), SUPPLY - QUEUED, "supply fell by exactly the queued amount");
        assertEq(chip.balanceOf(address(burner)), 0);
    }

    /// @notice The same token, burned twice in sequence, still totals correctly — the guard
    ///         releases and does not wedge the contract after a re-entry attempt.
    function test_theGuardDoesNotWedgeTheBurnerForLater() public {
        ReentrantChip chip = new ReentrantChip(SUPPLY);
        ChipBurner burner = new ChipBurner(multisig, address(chip));
        chip.transferOwnership(address(burner));
        chip.arm(address(burner));

        chip.transfer(address(burner), QUEUED);
        burner.burnAll();

        chip.transfer(address(burner), QUEUED);
        burner.burnAll();

        assertEq(burner.totalBurned(), QUEUED * 2);
        assertEq(burner.burnCount(), 2);
        assertEq(chip.totalSupply(), SUPPLY - (QUEUED * 2));
    }

    /* ------------------------------------------------------------------ */
    /*              THE FIGURE IS BOUNDED BY OUR OWN BALANCE               */
    /* ------------------------------------------------------------------ */

    /// @notice A token that burns somebody ELSE'S balance during our burn does not get to
    ///         inflate our figure. `burned` is capped by what actually left this contract.
    ///
    /// @dev Re-entry is not involved here — this is a single, well-behaved-looking call in
    ///      which `totalSupply` simply falls by more than we gave up. The supply delta alone
    ///      would have credited the Burner with the stranger's tokens too.
    function test_aTokenBurningSomebodyElsesSupplyCannotInflateTheFigure() public {
        GreedyBurnChip chip = new GreedyBurnChip(SUPPLY);
        ChipBurner burner = new ChipBurner(multisig, address(chip));
        chip.transferOwnership(address(burner));

        chip.transfer(stranger, 50_000 ether);
        chip.transfer(address(burner), QUEUED);
        chip.setCollateralVictim(stranger, 50_000 ether); // destroyed alongside ours

        uint256 supplyBefore = chip.totalSupply();
        uint256 burned = burner.burnAll();
        uint256 supplyDrop = supplyBefore - chip.totalSupply();

        assertEq(supplyDrop, QUEUED + 50_000 ether, "supply really did fall by more");
        assertEq(burned, QUEUED, "but we only take credit for our own");
        assertEq(burner.totalBurned(), QUEUED);
    }

    /// @notice A token that hands the Burner MORE than it destroys is refused outright rather
    ///         than allowed to underflow the balance delta.
    function test_aTokenThatPaysUsInsteadOfBurningIsRefused() public {
        RefundingChip chip = new RefundingChip(SUPPLY);
        ChipBurner burner = new ChipBurner(multisig, address(chip));
        chip.transferOwnership(address(burner));

        chip.transfer(address(burner), QUEUED);
        chip.setRefund(QUEUED * 2); // burns ours, then mints us more than it took

        vm.expectRevert();
        burner.burnAll();

        assertEq(burner.totalBurned(), 0, "nothing credited");
        assertEq(burner.burnCount(), 0);
    }

    /* ------------------------------------------------------------------ */
    /*                       THE HONEST PATH IS INTACT                     */
    /* ------------------------------------------------------------------ */

    /// @notice An ordinary token still burns and counts exactly as before. The guard and the
    ///         bound change nothing for the case that matters.
    function test_anOrdinaryTokenIsUnaffected() public {
        ReentrantChip chip = new ReentrantChip(SUPPLY); // never armed, so it never re-enters
        ChipBurner burner = new ChipBurner(multisig, address(chip));
        chip.transferOwnership(address(burner));

        chip.transfer(address(burner), QUEUED);

        vm.prank(keeper);
        uint256 burned = burner.burnAll();

        assertFalse(chip.reentryAttempted());
        assertEq(burned, QUEUED);
        assertEq(burner.totalBurned(), QUEUED);
        assertEq(burner.burnCount(), 1);
        assertEq(chip.totalSupply(), SUPPLY - QUEUED);
    }
}

/* ---------------------------------------------------------------------- */
/*                          HOSTILE TOKEN DOUBLES                          */
/* ---------------------------------------------------------------------- */

/// @notice Owner-gated burn, like Bankr's Doppler token, that calls back into the Burner.
contract ReentrantChip is ERC20 {
    address public owner;
    address public burner;
    bool public reentryAttempted;
    bool public reentryReverted;

    constructor(uint256 supply) ERC20("Chipworks", "CHIP") {
        owner = msg.sender;
        _mint(msg.sender, supply);
    }

    function transferOwnership(address n) external {
        require(msg.sender == owner, "NOT_OWNER");
        owner = n;
    }

    /// @notice Point the token at the Burner it should try to re-enter.
    function arm(address b) external {
        burner = b;
    }

    function burn(uint256 amount) external {
        require(msg.sender == owner, "NOT_OWNER");
        _burn(msg.sender, amount);

        if (burner != address(0)) {
            reentryAttempted = true;
            // Deliberately swallowed: a token that let the revert propagate would just make
            // the whole burn fail, which proves nothing about the accounting. Swallowing it
            // is the dangerous shape -- the outer call carries on and must still be right.
            (bool ok,) = burner.call(abi.encodeWithSignature("burnAll()"));
            reentryReverted = !ok;
        }
    }
}

/// @notice Burns its own holder's balance AND a nominated victim's in the same call, widening
///         the `totalSupply` delta beyond what the Burner actually gave up.
contract GreedyBurnChip is ERC20 {
    address public owner;
    address internal victim;
    uint256 internal victimAmount;

    constructor(uint256 supply) ERC20("Chipworks", "CHIP") {
        owner = msg.sender;
        _mint(msg.sender, supply);
    }

    function transferOwnership(address n) external {
        require(msg.sender == owner, "NOT_OWNER");
        owner = n;
    }

    function setCollateralVictim(address v, uint256 amount) external {
        victim = v;
        victimAmount = amount;
    }

    function burn(uint256 amount) external {
        require(msg.sender == owner, "NOT_OWNER");
        _burn(msg.sender, amount);
        if (victim != address(0)) _burn(victim, victimAmount);
    }
}

/// @notice Burns what it was given, then mints the caller strictly more back.
contract RefundingChip is ERC20 {
    address public owner;
    uint256 internal refund;

    constructor(uint256 supply) ERC20("Chipworks", "CHIP") {
        owner = msg.sender;
        _mint(msg.sender, supply);
    }

    function transferOwnership(address n) external {
        require(msg.sender == owner, "NOT_OWNER");
        owner = n;
    }

    function setRefund(uint256 r) external {
        refund = r;
    }

    function burn(uint256 amount) external {
        require(msg.sender == owner, "NOT_OWNER");
        _burn(msg.sender, amount);
        _mint(msg.sender, refund);
    }
}
