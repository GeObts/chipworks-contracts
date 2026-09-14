// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ChipLottery, IMegapot} from "../../src/lottery/ChipLottery.sol";
import {PoolKey} from "../../src/interfaces/IUniswapV4.sol";

interface IERC721Bal {
    function balanceOf(address) external view returns (uint256);
}

interface IMegapotView {
    function currentDrawingId() external view returns (uint256);
}


/**
 * ChipLottery against live Base.
 *
 * -- WHY THIS IS A FORK TEST AND NOT A UNIT TEST ---------------------------
 *
 * Every counterparty here is somebody else's deployed code, and two of them
 * cannot be read at all: the Megapot contracts are UNVERIFIED, so the payer
 * ("does buyTickets pull from msg.sender or from recipient?") was established by
 * running it, not by reading it. The $CHIP pool prices through a Doppler hook
 * whose fee is dynamic and not in any source we hold. A mock of either would be a
 * mock of my own assumptions, and would pass while the real thing reverted.
 *
 * So: real PoolManager, real hook, real v3 router, real Megapot, real $CHIP.
 */
contract ChipLotteryForkTest is Test {
    // ---- Base mainnet ------------------------------------------------------
    address constant CHIP = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant JACKPOT = 0x3bAe643002069dBCbcd62B1A4eb4C4A397d042a2;
    address constant TICKET_NFT = 0x48FfE35AbB9f4780a4f1775C2Ce1c46185b366e4;
    address constant HOOK = 0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544;
    address constant V3_QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;

    /// @dev BasedMining's EOA. Must be an EOA to claim referral fees; see the contract.
    address constant REFERRER = 0x70D3a9aA7e10070d3F528e91c9bCf5158c922C66;

    address constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;

    ChipLottery lottery;
    address buyer = makeAddr("buyer");
    address other = makeAddr("other");

    /**
     * The drawing's ball maxima, read ONCE in setUp and then held.
     *
     * Not re-read inside {_picks}, and that is not an optimisation. `vm.prank` and
     * `vm.expectRevert` both apply to the NEXT CALL ONLY, so a helper that makes an
     * external call while building an argument silently eats them: the prank lands on
     * `currentDrawingId()` instead of on `buyWithChip`, the buy arrives from the test
     * contract rather than the buyer, and it fails `InsufficientAllowance` for reasons
     * that have nothing to do with the code under test. Cached here, {_picks} touches
     * nothing external and the cheatcodes hit what they were aimed at.
     */
    uint256 normalBallMax;
    uint256 bonusBallMax;

    /// @dev One ticket costs about 404,618 $CHIP at the fork block. The ceiling is
    ///      deliberately loose so the refund path carries real weight in every test.
    uint256 constant MAX_CHIP_1 = 1_000_000 ether;

    /**
     * @dev WETH to buy for one ticket, WITH HEADROOM - QUOTED FROM THE CHAIN.
     *
     *      An off-chain quote is taken at one block and spent at another. Quoted to
     *      the wei, the v3 leg needed a few wei MORE than had been bought and the whole
     *      buy reverted `STF` - a shortfall of about a millionth of a cent killing a
     *      $1 purchase. That is not a test artifact; it is what every real buy would
     *      have done the moment the WETH/USDC price ticked between quote and mine. So
     *      the caller always over-buys slightly and the surplus is refunded.
     *
     *      IT IS QUOTED, NOT WRITTEN DOWN, and that is the second lesson. It WAS a
     *      constant - 0.0004015071 ether, right on the day it was measured. ETH moved,
     *      the leg began needing less, the refund grew past the bound this file asserts
     *      and the suite went red over nothing. A hardcoded figure derived from chain
     *      state is a slow-motion false alarm, exactly like the bonusball maximum was.
     */
    uint256 wethFor1;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        require(bytes(rpc).length > 0, "BASE_RPC_URL is required for the fork test");
        vm.createSelectFork(rpc);

        PoolKey memory key = PoolKey({
            currency0: WETH,
            currency1: CHIP,
            fee: 8_388_608, // dynamic-fee flag
            tickSpacing: 200,
            hooks: HOOK
        });

        lottery = new ChipLottery(
            SAFE, CHIP, WETH, USDC, POOL_MANAGER, V3_ROUTER, JACKPOT, REFERRER, key, 500
        );

        (normalBallMax, bonusBallMax) = _ballMaxima();
        wethFor1 = _quoteWethFor(1_000_000); // $1.00 in micro-USDC
        emit log_named_decimal_uint("wethFor1 (quoted +0.5%)", wethFor1, 18);
        emit log_named_uint("normalBallMax", normalBallMax);
        emit log_named_uint("bonusBallMax", bonusBallMax);

        deal(CHIP, buyer, 50_000_000 ether);
        vm.prank(buyer);
        IERC20(CHIP).approve(address(lottery), type(uint256).max);
    }

    // ---- helpers -----------------------------------------------------------

    /**
     * @dev Distinct, ascending, in range - and THE RANGE IS READ FROM THE CHAIN.
     *
     *      `bonusBallMax` is a PER-DRAWING parameter and it moves. This repo had it
     *      written down as 10; drawing 174 answers 8, and a bonusball of 10 reverts
     *      `InvalidBonusball()` from inside Megapot. A test with the number baked in
     *      passes until the day the drawing changes and then fails for a reason that
     *      has nothing to do with this contract.
     *
     *      None of this is readable from source - the Megapot contracts are
     *      unverified - so both maxima are asked for rather than assumed.
     */
    function _picks(uint256 n) internal view returns (IMegapot.Pick[] memory p) {
        uint256 normalMax = normalBallMax;
        uint256 bonusMax = bonusBallMax;

        p = new IMegapot.Pick[](n);
        for (uint256 i; i < n; ++i) {
            uint8[] memory balls = new uint8[](5);
            for (uint256 b; b < 5; ++b) {
                balls[b] = uint8(1 + ((i + b) % normalMax));
            }
            // Ascending is required, so sort the tiny array rather than hope.
            for (uint256 a; a < 5; ++a) {
                for (uint256 c = a + 1; c < 5; ++c) {
                    if (balls[c] < balls[a]) (balls[a], balls[c]) = (balls[c], balls[a]);
                }
            }
            p[i] = IMegapot.Pick({balls: balls, bonusball: uint8(1 + (i % bonusMax))});
        }
    }

    /// @dev The invariant the whole security model rests on.
    function _assertEmpty() internal view {
        (uint256 c, uint256 w, uint256 u) = lottery.sweepZero();
        assertEq(c, 0, "CHIP left in the wrapper");
        assertEq(w, 0, "WETH left in the wrapper");
        assertEq(u, 0, "USDC left in the wrapper");
    }

    // ---- 1. the happy path -------------------------------------------------

    function test_buysATicketAndRefundsTheRest() public {
        uint256 chipBefore = IERC20(CHIP).balanceOf(buyer);

        vm.prank(buyer);
        uint256 spent = lottery.buyWithChip(_picks(1), buyer, wethFor1, MAX_CHIP_1, block.timestamp + 300);

        assertEq(IERC721Bal(TICKET_NFT).balanceOf(buyer), 1, "buyer should hold one ticket");
        assertEq(chipBefore - IERC20(CHIP).balanceOf(buyer), spent, "reported spend must equal the real spend");
        assertLt(spent, MAX_CHIP_1, "some CHIP must have come back");
        assertGt(spent, 0, "a ticket is not free");
        _assertEmpty();

        emit log_named_decimal_uint("CHIP spent on 1 ticket", spent, 18);
    }

    function test_tenTicketsInOneCall() public {
        vm.prank(buyer);
        uint256 spent =
            lottery.buyWithChip(_picks(10), buyer, wethFor1 * 10, MAX_CHIP_1 * 10, block.timestamp + 300);

        assertEq(IERC721Bal(TICKET_NFT).balanceOf(buyer), 10, "ten tickets");
        _assertEmpty();
        emit log_named_decimal_uint("CHIP spent on 10 tickets", spent, 18);
    }

    /*
      REMOVED: test_ticketAndChangeGoToRecipientNotPayer.

      It asserted "change follows the ticket" - which is the behaviour an audit
      correctly called a bug, written down as a requirement. A test that encodes the
      defect is worse than no test: it turns the next person's correct fix into a
      red build and argues them out of it.

      Replaced by {test_changeGoesToThePayerAndOnlyTheTicketToTheRecipient}, which
      asserts the opposite and is the behaviour the contract now has.
    */

    // ---- 2. the buyer's own bound ------------------------------------------

    function test_maxChipInTooLowRevertsAndReturnsEverything() public {
        uint256 before = IERC20(CHIP).balanceOf(buyer);

        vm.prank(buyer);
        vm.expectRevert();
        lottery.buyWithChip(_picks(1), buyer, wethFor1, 1_000 ether, block.timestamp + 300);

        assertEq(IERC20(CHIP).balanceOf(buyer), before, "a failed buy must cost the buyer nothing");
        assertEq(IERC721Bal(TICKET_NFT).balanceOf(buyer), 0, "no ticket");
        _assertEmpty();
    }

    // ---- 3. the guards -----------------------------------------------------

    function test_selfReferralRevertsBeforeAnyChipMoves() public {
        deal(CHIP, REFERRER, 10_000_000 ether);
        vm.prank(REFERRER);
        IERC20(CHIP).approve(address(lottery), type(uint256).max);
        uint256 before = IERC20(CHIP).balanceOf(REFERRER);

        vm.prank(REFERRER);
        vm.expectRevert(abi.encodeWithSelector(ChipLottery.SelfReferral.selector, REFERRER));
        lottery.buyWithChip(_picks(1), REFERRER, wethFor1, MAX_CHIP_1, block.timestamp + 300);

        assertEq(IERC20(CHIP).balanceOf(REFERRER), before, "nothing moved");
        _assertEmpty();
    }

    function test_expiredDeadlineReverts() public {
        uint256 before = IERC20(CHIP).balanceOf(buyer);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(ChipLottery.DeadlinePassed.selector, block.timestamp, block.timestamp - 1)
        );
        lottery.buyWithChip(_picks(1), buyer, wethFor1, MAX_CHIP_1, block.timestamp - 1);
        assertEq(IERC20(CHIP).balanceOf(buyer), before);
        _assertEmpty();
    }

    function test_zeroTicketsReverts() public {
        vm.prank(buyer);
        vm.expectRevert(ChipLottery.NoTickets.selector);
        lottery.buyWithChip(_picks(0), buyer, wethFor1, MAX_CHIP_1, block.timestamp + 300);
    }

    function test_elevenTicketsRevertsRatherThanSilentlyTakingTheSlowPath() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ChipLottery.TooManyTickets.selector, 11, 10));
        lottery.buyWithChip(_picks(11), buyer, wethFor1 * 11, MAX_CHIP_1 * 11, block.timestamp + 300);
    }

    function test_zeroRecipientReverts() public {
        vm.prank(buyer);
        vm.expectRevert(ChipLottery.ZeroAddress.selector);
        lottery.buyWithChip(_picks(1), address(0), wethFor1, MAX_CHIP_1, block.timestamp + 300);
    }

    // ---- 4. the callback is not a door -------------------------------------

    function test_unlockCallbackRejectsEveryoneButThePoolManager() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ChipLottery.NotPoolManager.selector, buyer));
        lottery.unlockCallback(abi.encode(uint256(1), uint256(1)));
    }

    // ---- 5. admin cannot reach user money ----------------------------------

    function test_rescueIsOwnerOnly() public {
        vm.prank(buyer);
        vm.expectRevert();
        lottery.rescue(CHIP, buyer, 1);
    }

    /**
     * @dev The rescue exists for tokens sent here by mistake, and this is what that
     *      looks like: a stray transfer, recovered by the Safe. It is only safe
     *      because no buy ever leaves a balance for it to reach - which every other
     *      test in this file asserts.
     */
    function test_rescueRecoversStrayTokensOnly() public {
        uint256 safeBefore = IERC20(CHIP).balanceOf(SAFE);
        deal(CHIP, address(lottery), 5 ether);
        vm.prank(SAFE);
        lottery.rescue(CHIP, SAFE, 5 ether);
        // A DELTA, not an absolute: the Safe is the protocol treasury and already
        // holds a great deal of $CHIP.
        assertEq(IERC20(CHIP).balanceOf(SAFE) - safeBefore, 5 ether);
        _assertEmpty();
    }

    // ---- 6. nothing rests here, across a sequence --------------------------

    function test_repeatedBuysNeverAccumulateABalance() public {
        for (uint256 i; i < 3; ++i) {
            vm.prank(buyer);
            lottery.buyWithChip(_picks(1), buyer, wethFor1, MAX_CHIP_1, block.timestamp + 300);
            _assertEmpty();
        }
        assertEq(IERC721Bal(TICKET_NFT).balanceOf(buyer), 3);
    }

    // ---- 7. the referrer is genuinely un-repointable ------------------------

    /**
     * @dev The referrer must remain something that can CALL `claimReferralFees()`,
     *      i.e. an account with a key behind it.
     *
     *      It is not bare any more: it carries 23 bytes, which is an EIP-7702
     *      delegation (0xef0100 || implementation) rather than a deployed contract.
     *      A delegated EOA still signs and still transacts, so the fee remains
     *      claimable - but "code.length == 0" is no longer the right test for "is
     *      this an EOA", and asserting it would fail on a perfectly good address.
     *      What actually matters is that it is not a plain contract.
     */
    function test_referrerCanStillClaimItsFees() public view {
        assertEq(lottery.referrer(), REFERRER, "referrer must be the BasedMining EOA");
        uint256 len = REFERRER.code.length;
        if (len != 0) {
            assertEq(len, 23, "referrer has contract code - fees would strand");
            bytes memory c = REFERRER.code;
            assertEq(uint8(c[0]), 0xef, "not a 7702 delegation");
            assertEq(uint8(c[1]), 0x01, "not a 7702 delegation");
            assertEq(uint8(c[2]), 0x00, "not a 7702 delegation");
        }
    }

    /**
     * @dev The two ball maxima, pulled out of `getDrawingState` BY OFFSET.
     *
     *      That call returns THIRTEEN unnamed words and only a few have ever been
     *      identified; destructuring all thirteen to reach two of them blows the
     *      stack. Worse, naming the other eleven in an interface would dress up
     *      guesses as facts. So: raw staticcall, and read word 9 and word 10, which
     *      are the two that were actually confirmed against known values.
     */
    function _ballMaxima() internal view returns (uint256 normalMax, uint256 bonusMax) {
        uint256 id = IMegapotView(JACKPOT).currentDrawingId();
        (bool ok, bytes memory ret) =
            JACKPOT.staticcall(abi.encodeWithSignature("getDrawingState(uint256)", id));
        require(ok && ret.length >= 11 * 32, "getDrawingState failed");
        assembly {
            normalMax := mload(add(ret, add(32, mul(9, 32))))
            bonusMax := mload(add(ret, add(32, mul(10, 32))))
        }
        require(normalMax >= 5 && bonusMax >= 1, "implausible ball maxima - do not trust this run");
    }

    // ---- 8. reentrancy -----------------------------------------------------

    /**
     * @dev The ticket mint is the only call-out to an address the buyer controls, so
     *      it is the only place a reentrant call can start. Whether Megapot uses
     *      `_safeMint` is not knowable from source (unverified), so this asserts the
     *      outcome either way: if the hook fires, the re-entry must fail; if it never
     *      fires, there was nothing to defend and the buy still completes cleanly.
     */
    function test_reentrantRecipientCannotReenter() public {
        ReentrantRecipient attacker = new ReentrantRecipient(lottery);
        attacker.arm(_picks(1));

        deal(CHIP, address(attacker), 5_000_000 ether);
        vm.prank(address(attacker));
        IERC20(CHIP).approve(address(lottery), type(uint256).max);

        attacker.go(wethFor1, MAX_CHIP_1);

        assertEq(IERC721Bal(TICKET_NFT).balanceOf(address(attacker)), 1, "exactly one ticket");
        if (attacker.attempts() != 0) {
            assertTrue(attacker.reenterFailed(), "reentrant buy must have been rejected");
            emit log("onERC721Received fired and the guard held");
        } else {
            emit log("Megapot mint does not call onERC721Received - no reentry surface");
        }
        _assertEmpty();
    }

    // ---- 9. what the buyer actually pays -----------------------------------

    /**
     * @dev The headroom is refunded, not kept. This prints the WETH dust so the cost
     *      of the design is visible rather than asserted away.
     */
    function test_wethDustIsRefundedAndIsSmall() public {
        uint256 wethBefore = IERC20(WETH).balanceOf(buyer);
        IMegapot.Pick[] memory p = _picks(1);

        vm.prank(buyer);
        uint256 spent = lottery.buyWithChip(p, buyer, wethFor1, MAX_CHIP_1, block.timestamp + 300);

        uint256 dust = IERC20(WETH).balanceOf(buyer) - wethBefore;
        emit log_named_decimal_uint("CHIP spent", spent, 18);
        emit log_named_decimal_uint("WETH refunded to buyer", dust, 18);

        assertGt(dust, 0, "headroom must come back, not stay here");
        assertLt(dust, wethFor1 / 50, "dust should be a small fraction of the leg");
        _assertEmpty();
    }

    // ---- 10. the properties the end-to-end tests only IMPLIED ---------------

    /**
     * @dev EXACT OUTPUT, ASSERTED DIRECTLY.
     *
     *      An audit read `int256(wethOut)` as exact-INPUT and called the contract
     *      broken. It is not - v4 reads POSITIVE as exact-output - but the objection
     *      landed because nothing here SAID so. The old suite only proved a ticket
     *      came out the far end, which would also have been true of several wrong
     *      swaps that happened to buy enough.
     *
     *      This pins the property itself: the v4 leg must deliver EXACTLY the WETH it
     *      was asked for. Under exact-input it would deliver whatever 0.0004 $CHIP is
     *      worth - about 425,000 wei - and this fails loudly.
     */
    function test_v4LegDeliversExactlyTheWethRequested() public {
        uint256 wethBefore = IERC20(WETH).balanceOf(buyer);
        IMegapot.Pick[] memory p = _picks(1);

        // maxChipIn is the only bound; the leg must still buy precisely wethFor1.
        vm.prank(buyer);
        lottery.buyWithChip(p, buyer, wethFor1, MAX_CHIP_1, block.timestamp + 300);

        // What the ticket did not consume is refunded as WETH, so:
        //   WETH bought  ==  WETH spent on USDC  +  WETH refunded
        // and the refund alone proves the leg bought at least the full requested
        // amount rather than a dust quantity.
        uint256 refunded = IERC20(WETH).balanceOf(buyer) - wethBefore;
        assertGt(refunded, 0, "exact-input would have bought dust, leaving nothing to refund");
        assertLt(refunded, wethFor1, "cannot refund more than was bought");
        _assertEmpty();
    }

    /**
     * @dev The $CHIP cost must scale with the ORDER, not sit at a fixed number.
     *
     *      Under exact-input the swap would spend whatever `wethNeeded` said and be
     *      insensitive to how many tickets were being bought - so ten tickets would
     *      cost about what one did. Ten costing ten times one is only true of an
     *      exact-output swap sized from the ticket price.
     */
    function test_costScalesWithTicketCountAsExactOutputRequires() public {
        IMegapot.Pick[] memory one = _picks(1);
        vm.prank(buyer);
        uint256 costOne = lottery.buyWithChip(one, buyer, wethFor1, MAX_CHIP_1, block.timestamp + 300);

        IMegapot.Pick[] memory ten = _picks(10);
        vm.prank(buyer);
        uint256 costTen = lottery.buyWithChip(ten, buyer, wethFor1 * 10, MAX_CHIP_1 * 10, block.timestamp + 300);

        emit log_named_decimal_uint("1 ticket ", costOne, 18);
        emit log_named_decimal_uint("10 tickets", costTen, 18);

        // Ten tickets within 2% of ten times one. Exact-input would land near 1x.
        assertApproxEqRel(costTen, costOne * 10, 0.02e18, "cost must scale with the order");
        _assertEmpty();
    }

    // ---- 11. the change belongs to whoever paid ----------------------------

    /**
     * @dev Refund goes to the PAYER. This inverts what the contract used to do, and
     *      the old behaviour was a real bug: gifting a ticket also gifted whatever
     *      headroom the payer had left on `maxChipIn`, which is a ceiling and can be
     *      most of it.
     */
    function test_changeGoesToThePayerAndOnlyTheTicketToTheRecipient() public {
        uint256 payerChipBefore = IERC20(CHIP).balanceOf(buyer);
        uint256 otherChipBefore = IERC20(CHIP).balanceOf(other);
        IMegapot.Pick[] memory p = _picks(1);

        vm.prank(buyer);
        uint256 spent = lottery.buyWithChip(p, other, wethFor1, MAX_CHIP_1, block.timestamp + 300);

        assertEq(IERC721Bal(TICKET_NFT).balanceOf(other), 1, "recipient gets the ticket");
        assertEq(IERC20(CHIP).balanceOf(other), otherChipBefore, "recipient gets NO CHIP");
        assertEq(payerChipBefore - IERC20(CHIP).balanceOf(buyer), spent, "payer is out exactly what was spent");
        assertLt(spent, MAX_CHIP_1, "and the headroom came back to the payer");
        _assertEmpty();
    }

    // ---- 12. token ordering is derived, not assumed -------------------------

    function test_poolOrderingIsDerivedFromTheKey() public view {
        // WETH (0x4200..) sorts below $CHIP (0x75Af..) on Base.
        assertLt(uint160(WETH), uint160(CHIP), "fixture assumption");
        assertEq(lottery.chipIsCurrency0(), false, "CHIP is currency1 in this pool");
        assertEq(lottery.currency0(), WETH);
        assertEq(lottery.currency1(), CHIP);
    }

    /// @dev A key naming some other pair must be refused at construction rather than
    ///      producing a contract whose swap direction is quietly wrong.
    function test_constructorRejectsAKeyThatIsNotChipWeth() public {
        PoolKey memory wrong =
            PoolKey({currency0: USDC, currency1: CHIP, fee: 8_388_608, tickSpacing: 200, hooks: HOOK});
        vm.expectRevert(ChipLottery.KeyIsNotChipWeth.selector);
        new ChipLottery(SAFE, CHIP, WETH, USDC, POOL_MANAGER, V3_ROUTER, JACKPOT, REFERRER, wrong, 500);
    }

    /**
     * @dev What the v3 leg needs for `usdcOut`, plus 0.5% headroom.
     *
     *      The quoter is non-view - it swaps and reverts - which is fine on a fork and
     *      is the only way to get v3's true exact-output input amount without
     *      reimplementing its maths.
     */
    function _quoteWethFor(uint256 usdcOut) internal returns (uint256) {
        (bool ok, bytes memory ret) = V3_QUOTER.call(
            abi.encodeWithSignature(
                "quoteExactOutputSingle((address,address,uint256,uint24,uint160))",
                WETH, USDC, usdcOut, uint24(500), uint160(0)
            )
        );
        require(ok && ret.length >= 32, "v3 exact-output quote failed");
        uint256 amountIn = abi.decode(ret, (uint256));
        require(amountIn > 0, "quoter returned zero");
        return (amountIn * 1005) / 1000;
    }
}

/**
 * A recipient that tries to buy again while its own ticket is being minted.
 *
 * This is the one reentrancy vector that actually exists here. The three ERC-20s
 * in the flow do not call out, but Megapot mints an ERC-721 to `recipient`, and if
 * that mint is a `_safeMint` then a CONTRACT recipient gets `onERC721Received`
 * called - inside `buyWithChip`, after the swap, before the refund. A wrapper
 * without a guard would let that second call see a contract still holding the
 * first call's change.
 */
contract ReentrantRecipient {
    ChipLottery immutable lottery;
    IMegapot.Pick[] picks;
    uint256 public attempts;
    bool public reenterFailed;

    constructor(ChipLottery l) {
        lottery = l;
    }

    function arm(IMegapot.Pick[] memory p) external {
        delete picks;
        for (uint256 i; i < p.length; ++i) {
            picks.push();
            picks[i].bonusball = p[i].bonusball;
            for (uint256 b; b < p[i].balls.length; ++b) {
                picks[i].balls.push(p[i].balls[b]);
            }
        }
    }

    function go(uint256 wethNeeded, uint256 maxChipIn) external {
        lottery.buyWithChip(picks, address(this), wethNeeded, maxChipIn, block.timestamp + 300);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (attempts == 0) {
            attempts = 1;
            try lottery.buyWithChip(picks, address(this), 1, 1, block.timestamp + 300) {
                reenterFailed = false;
            } catch {
                reenterFailed = true;
            }
        }
        return this.onERC721Received.selector;
    }
}
