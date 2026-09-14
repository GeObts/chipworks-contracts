// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager, IUnlockCallback, IUniswapV3ExactOutput, PoolKey, SwapParams} from "../interfaces/IUniswapV4.sol";

interface IMegapot {
    struct Pick {
        uint8[] balls;
        uint8 bonusball;
    }

    function buyTickets(
        Pick[] calldata picks,
        address recipient,
        address[] calldata referrers,
        uint256[] calldata shares,
        bytes32 source
    ) external;

    function ticketPrice() external view returns (uint256);
}

/**
 * Buy a Megapot lottery ticket with $CHIP.
 *
 * $CHIP in, a ticket NFT out, one transaction. The holder never touches USDC and
 * never holds a half-finished position.
 *
 * -- WHY A CONTRACT AND NOT FOUR SIGNATURES --------------------------------
 *
 * Done in the front end this is approve -> swap -> approve -> buy, and the
 * failure that matters is the one in the middle: a swap that lands followed by a
 * buy that reverts leaves somebody holding USDC they never wanted, from a screen
 * that promised them a lottery ticket. Here the whole thing is one call - a
 * ticket, or nothing moved.
 *
 * -- THE SECURITY MODEL IS "THERE IS NEVER ANYTHING HERE" ------------------
 *
 * This contract holds no balance between transactions. Every path either
 * finishes - $CHIP in, ticket to the buyer, every unspent wei returned in the
 * same call - or reverts whole. {sweepZero} is asserted at the end of every fork
 * test. A contract with an empty balance cannot be drained of user funds, which
 * removes most of the attack surface rather than defending it.
 *
 * -- WHAT IT ASSUMES ABOUT ITS THREE TOKENS -------------------------------
 *
 * $CHIP, WETH and USDC are assumed to be PLAIN ERC-20s: a transfer of n moves
 * exactly n, balances do not rebase, and no fee is skimmed in transit. All three
 * satisfy that today.
 *
 * The contract does not merely assume it, though - it measures. The swap's
 * reported cost is checked against the balance delta, and the buyer's spend is
 * computed from balances rather than from what any pool said. A token that began
 * taking a cut on transfer would trip {SwapAccountingMismatch} and revert, rather
 * than quietly charging one number while another moved. It would stop working; it
 * would not start lying.
 *
 * -- THE PRICE IS THE MARKET'S, NOT OURS -----------------------------------
 *
 * No wrapper fee, no spread, no rounding in our favour. The swap is EXACT
 * OUTPUT: it buys precisely the micro-USDC the tickets cost and no more, so the
 * buyer's $CHIP is spent at the real rate and the remainder of `maxChipIn` comes
 * straight back. Revenue is the Megapot referral fee, which Megapot pays out of
 * the ticket, and the demand the ticket creates for $CHIP.
 */
contract ChipLottery is Ownable, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    /* ------------------------------------------------------------------ */
    /*                            IMMUTABLES                                */
    /* ------------------------------------------------------------------ */

    IERC20 public immutable chip;
    IERC20 public immutable weth;
    IERC20 public immutable usdc;
    IPoolManager public immutable poolManager;
    IUniswapV3ExactOutput public immutable v3Router;
    IMegapot public immutable jackpot;

    /**
     * The address Megapot pays the referral fee to. IMMUTABLE ON PURPOSE.
     *
     * `referralScheme` is written into each ticket at mint and survives transfer,
     * so a ticket pays whoever was named when it was bought and nothing can
     * re-point it afterwards. The fee accrues to the address and ONLY that address
     * can call `claimReferralFees()` - so this must stay an EOA. Naming a contract
     * here would strand every fee it ever earned.
     *
     * A setter would buy nothing (old tickets keep their old referrer either way)
     * and would add a way to quietly break exactly that. There is no setter.
     */
    address public immutable referrer;

    /// @notice The v3 fee tier for the WETH -> USDC leg. 500 = 0.05%.
    uint24 public immutable v3Fee;

    /*
      THE POOL KEY, FIELD BY FIELD.

      A struct cannot be `immutable` in Solidity, so holding the key whole meant
      holding it in STORAGE: five slots read on every swap, and mutable state in a
      contract whose whole claim is that it has none. Split into immutables it costs
      nothing to read and there is no writable storage left on this contract at all.

      {_key} puts it back together when the PoolManager needs it.
    */
    address public immutable currency0;
    address public immutable currency1;
    uint24 public immutable poolFee;
    int24 public immutable tickSpacing;
    address public immutable hooks;

    /**
     * Which side of the pool $CHIP sits on, decided at construction.
     *
     * v4 orders a key by address, so which of $CHIP and WETH is `currency0` is an
     * accident of their addresses. For the live pool WETH (0x4200..) sorts below
     * $CHIP (0x75Af..) - but hardcoding that made the swap direction and the delta
     * decode silently wrong for any other pair, including a future $CHIP redeploy.
     * Derived once here and used everywhere instead.
     */
    bool public immutable chipIsCurrency0;

    /// @notice Megapot needs the batch facilitator above ten, and that mints a minute or
    ///         two later. A wrapper that silently took the slow path would report a
    ///         purchase that is not there yet, so ten is the ceiling and it is enforced.
    uint256 public constant MAX_TICKETS = 10;

    /// @notice Tag Megapot records on each ticket, so the source is attributable.
    bytes32 public constant SOURCE = bytes32("chipworks");

    /*
      The price limits, which are direction-dependent.

      A swap that moves the price DOWN (zeroForOne) must be limited from below, and
      one that moves it UP from above. Neither is a slippage bound - `maxChipIn` is
      the bound, and it is the buyer's own number. These only stop the swap running
      off the end of the curve.
    */
    /// @dev TickMath.MAX_SQRT_PRICE - 1.
    uint160 internal constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;
    /// @dev TickMath.MIN_SQRT_PRICE + 1.
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4295128740;

    /* ------------------------------------------------------------------ */
    /*                              ERRORS                                  */
    /* ------------------------------------------------------------------ */

    error ZeroAddress();
    error DeadlinePassed(uint256 nowTs, uint256 deadline);
    error NoTickets();
    error TooManyTickets(uint256 asked, uint256 max);
    error SelfReferral(address recipient);
    error ChipCostAboveMax(uint256 needed, uint256 max);
    error NotPoolManager(address caller);
    error NothingSwapped();
    error KeyIsNotChipWeth();
    error SwapAccountingMismatch(uint256 reported, uint256 measured);

    event TicketsBought(
        address indexed buyer, address indexed recipient, uint256 count, uint256 chipSpent, uint256 usdcPaid
    );
    event Rescued(address indexed token, address indexed to, uint256 amount);

    constructor(
        address owner_,
        address chip_,
        address weth_,
        address usdc_,
        address poolManager_,
        address v3Router_,
        address jackpot_,
        address referrer_,
        PoolKey memory poolKey_,
        uint24 v3Fee_
    ) Ownable(owner_) {
        if (
            owner_ == address(0) || chip_ == address(0) || weth_ == address(0) || usdc_ == address(0)
                || poolManager_ == address(0) || v3Router_ == address(0) || jackpot_ == address(0)
                || referrer_ == address(0)
        ) revert ZeroAddress();

        chip = IERC20(chip_);
        weth = IERC20(weth_);
        usdc = IERC20(usdc_);
        poolManager = IPoolManager(poolManager_);
        v3Router = IUniswapV3ExactOutput(v3Router_);
        jackpot = IMegapot(jackpot_);
        referrer = referrer_;
        v3Fee = v3Fee_;

        currency0 = poolKey_.currency0;
        currency1 = poolKey_.currency1;
        poolFee = poolKey_.fee;
        tickSpacing = poolKey_.tickSpacing;
        hooks = poolKey_.hooks;

        /*
          The key must be exactly {$CHIP, WETH} in some order. Checked rather than
          assumed, because everything downstream - the swap direction, which half of
          the delta is which - is derived from this one boolean, and a key naming some
          other pair would make all of it quietly wrong rather than loudly broken.
        */
        if (poolKey_.currency0 == chip_ && poolKey_.currency1 == weth_) {
            chipIsCurrency0 = true;
        } else if (poolKey_.currency0 == weth_ && poolKey_.currency1 == chip_) {
            chipIsCurrency0 = false;
        } else {
            revert KeyIsNotChipWeth();
        }
    }

    /// @dev The pool key, rebuilt from the immutables.
    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
    }

    /// @notice The pool this contract swaps through.
    function poolKey() external view returns (PoolKey memory) {
        return _key();
    }

    /* ------------------------------------------------------------------ */
    /*                               BUY                                    */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Spend $CHIP on Megapot tickets. The tickets go to `recipient`.
     *
     * @param picks       One tuple per ticket: five balls and a bonusball.
     * @param recipient   Who receives the ticket NFTs. Must not be the referrer.
     * @param wethNeeded  WETH the USDC leg is expected to need, quoted off chain. A
     *                    bound, not a promise: anything the leg does not spend goes
     *                    to `recipient` in this call.
     * @param maxChipIn   The most $CHIP the buyer will part with. The real cost is
     *                    whatever the pool charges; the rest is returned.
     * @param deadline    Unix seconds after which this call reverts.
     */
    function buyWithChip(
        IMegapot.Pick[] calldata picks,
        address recipient,
        uint256 wethNeeded,
        uint256 maxChipIn,
        uint256 deadline
    ) external nonReentrant returns (uint256 chipSpent) {
        if (block.timestamp > deadline) revert DeadlinePassed(block.timestamp, deadline);
        if (recipient == address(0)) revert ZeroAddress();
        if (picks.length == 0) revert NoTickets();
        if (picks.length > MAX_TICKETS) revert TooManyTickets(picks.length, MAX_TICKETS);
        /*
          Megapot reverts when the recipient is also a referrer, so this would fail
          deep inside the buy having already swapped. Caught here, before any of the
          buyer's $CHIP has moved, so the revert costs them gas and nothing else.
        */
        if (recipient == referrer) revert SelfReferral(recipient);

        uint256 usdcNeeded = jackpot.ticketPrice() * picks.length;

        // 1. Take the ceiling. Whatever is not spent goes back before this returns.
        chip.safeTransferFrom(msg.sender, address(this), maxChipIn);

        /*
          2. $CHIP -> WETH, exact output. Reverts if it would cost more than maxChipIn.

          The pool's reported cost is CHECKED AGAINST THE BALANCE, not trusted. They
          should always agree; if they ever did not - a token that takes a cut on
          transfer, a pool accounting for something this contract cannot see - the
          buyer would be charged one number while a different one moved. Better to
          stop than to report a spend that did not happen.
        */
        uint256 chipBefore = chip.balanceOf(address(this));
        uint256 reported = _swapChipForWeth(wethNeeded, maxChipIn);
        uint256 measured = chipBefore - chip.balanceOf(address(this));
        if (reported != measured) revert SwapAccountingMismatch(reported, measured);

        // 3. WETH -> USDC, exact output. Spends at most the WETH we just bought.
        uint256 wethHeld = weth.balanceOf(address(this));
        weth.forceApprove(address(v3Router), wethHeld);
        v3Router.exactOutputSingle(
            IUniswapV3ExactOutput.ExactOutputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(usdc),
                fee: v3Fee,
                recipient: address(this),
                amountOut: usdcNeeded,
                amountInMaximum: wethHeld,
                sqrtPriceLimitX96: 0
            })
        );
        weth.forceApprove(address(v3Router), 0);

        // 4. Buy. Megapot pulls the USDC from THIS contract and mints to `recipient` -
        //    proved on a fork before this contract was written, because the Megapot
        //    contracts are unverified and the payer could not be read from source.
        usdc.forceApprove(address(jackpot), usdcNeeded);
        _buy(picks, recipient);
        usdc.forceApprove(address(jackpot), 0);

        // 5. Nothing stays here. Ever. The change goes to whoever PAID.
        chipSpent = _refundAll(msg.sender, maxChipIn);

        emit TicketsBought(msg.sender, recipient, picks.length, chipSpent, usdcNeeded);
    }

    /// @dev Split out so the stack in {buyWithChip} stays under the limit.
    function _buy(IMegapot.Pick[] calldata picks, address recipient) internal {
        address[] memory referrers = new address[](1);
        referrers[0] = referrer;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 1e18; // one referrer taking the whole share

        jackpot.buyTickets(picks, recipient, referrers, shares, SOURCE);
    }

    /**
     * @dev Return every token this call did not consume, TO THE PAYER.
     *
     *      This used to refund the recipient, on the reasoning that change belongs
     *      with the ticket. That was wrong, and an audit was right to call it: the
     *      payer's $CHIP is the payer's. Buying somebody a lottery ticket should cost
     *      you a ticket, not a ticket plus whatever headroom you left on the approval
     *      - and `maxChipIn` is a CEILING, so the leftover can be most of it.
     *
     *      Only the ticket goes to `recipient`. Every unspent token comes back here.
     *
     *      WETH dust is real and expected: `amountInMaximum` is a bound and the v3 leg
     *      usually spends less than it. It is returned as WETH rather than swapped
     *      back, which would cost more gas than the dust is worth.
     *
     *      The $CHIP spent is MEASURED - what went in, less what came back - rather
     *      than taken from what the pool reported.
     */
    function _refundAll(address payer, uint256 maxChipIn) internal returns (uint256 chipSpent) {
        uint256 chipLeft = chip.balanceOf(address(this));
        if (chipLeft != 0) chip.safeTransfer(payer, chipLeft);

        uint256 wethLeft = weth.balanceOf(address(this));
        if (wethLeft != 0) weth.safeTransfer(payer, wethLeft);

        uint256 usdcLeft = usdc.balanceOf(address(this));
        if (usdcLeft != 0) usdc.safeTransfer(payer, usdcLeft);

        chipSpent = maxChipIn - chipLeft;
    }

    /* ------------------------------------------------------------------ */
    /*                          THE V4 SWAP                                 */
    /* ------------------------------------------------------------------ */

    /// @dev v4 does all its work inside a lock. Everything real happens in the callback.
    function _swapChipForWeth(uint256 wethOut, uint256 maxChipIn) internal returns (uint256 chipUsed) {
        bytes memory out = poolManager.unlock(abi.encode(wethOut, maxChipIn));
        chipUsed = abi.decode(out, (uint256));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager(msg.sender);
        (uint256 wethOut, uint256 maxChipIn) = abi.decode(data, (uint256, uint256));

        /*
          DIRECTION, DERIVED - NOT ASSUMED.

          Selling $CHIP for WETH means swapping whichever currency $CHIP is FOR the
          other one. If $CHIP is currency0 that is zeroForOne; if it is currency1 it is
          not. The price limit follows the direction: down-swaps are limited from
          below, up-swaps from above.
        */
        bool zeroForOne = chipIsCurrency0;

        /*
          POSITIVE `amountSpecified` IS EXACT OUTPUT.

          v4-core: "The desired input amount if negative (exactIn), or the desired
          output amount if positive (exactOut)." So a positive WETH figure here means
          "give me exactly this much WETH and charge me what it costs", which is what
          buying a fixed-price ticket needs.

          This is the opposite of the intuition that negative means "taking out", and
          getting it backwards does NOT revert - it would read `wethOut` as a $CHIP
          INPUT amount, spend 0.0004 $CHIP and buy a few hundred thousand wei of WETH.
          Proved both directions against the live pool in
          test/fork/V4SignConvention.t.sol, and {test_v4SwapIsExactOutput} asserts the
          property here rather than inferring it from the end-to-end result.
        */
        int256 delta = poolManager.swap(
            _key(),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(wethOut),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT
            }),
            ""
        );

        // Packed (int128 amount0, int128 amount1), caller's perspective:
        // negative is owed TO the pool, positive is owed BY it.
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);

        // $CHIP is the side being paid, WETH the side being received - whichever
        // currency index each of them happens to occupy.
        int128 chipDelta = chipIsCurrency0 ? amount0 : amount1;
        int128 wethDelta = chipIsCurrency0 ? amount1 : amount0;

        if (chipDelta >= 0 || wethDelta <= 0) revert NothingSwapped();

        uint256 chipOwed = uint256(uint128(-chipDelta));
        uint256 wethGot = uint256(uint128(wethDelta));

        // Exact output means exactly this, and it is worth stating: the pool must
        // have given the WETH that was asked for, not merely some WETH.
        if (wethGot != wethOut) revert NothingSwapped();

        if (chipOwed > maxChipIn) revert ChipCostAboveMax(chipOwed, maxChipIn);

        // Pay the pool: sync, transfer, settle. Skipping sync credits nothing.
        poolManager.sync(address(chip));
        chip.safeTransfer(address(poolManager), chipOwed);
        poolManager.settle();

        // Collect the WETH.
        poolManager.take(address(weth), address(this), wethGot);

        return abi.encode(chipOwed);
    }

    /* ------------------------------------------------------------------ */
    /*                              ADMIN                                   */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Recover a token sent here by mistake. Safe only.
     *
     * @dev This is safe BECAUSE of the invariant above, not in spite of it. No buy
     *      leaves a balance behind, so anything this can reach arrived by accident and
     *      belongs to whoever misdirected it. There is no in-flight user money for an
     *      owner to take: `nonReentrant` plus the whole flow living in one call means
     *      the only moment this contract holds anything is mid-call, and an owner
     *      cannot execute during someone else's transaction.
     */
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /// @notice What this contract is holding. Expected to be (0,0,0) between calls.
    function sweepZero() external view returns (uint256 chipBal, uint256 wethBal, uint256 usdcBal) {
        return (chip.balanceOf(address(this)), weth.balanceOf(address(this)), usdc.balanceOf(address(this)));
    }
}
