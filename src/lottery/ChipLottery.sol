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

    /// @notice $CHIP/WETH. Stored as the key, not a poolId, because the PoolManager
    ///         takes the key.
    PoolKey public poolKey;

    /// @notice Megapot needs the batch facilitator above ten, and that mints a minute or
    ///         two later. A wrapper that silently took the slow path would report a
    ///         purchase that is not there yet, so ten is the ceiling and it is enforced.
    uint256 public constant MAX_TICKETS = 10;

    /// @notice Tag Megapot records on each ticket, so the source is attributable.
    bytes32 public constant SOURCE = bytes32("chipworks");

    /// @dev TickMath.MAX_SQRT_PRICE - 1. Not a slippage bound: `maxChipIn` is the
    ///      bound, and it is the buyer's own number.
    uint160 internal constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;

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
        poolKey = poolKey_;
        v3Fee = v3Fee_;
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

        // 2. $CHIP -> WETH, exact output. Reverts if it would cost more than maxChipIn.
        _swapChipForWeth(wethNeeded, maxChipIn);

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

        // 5. Nothing stays here. Ever.
        chipSpent = _refundAll(recipient, maxChipIn);

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
     * @dev Return every token this call did not consume, to the RECIPIENT.
     *
     *      To the recipient and not to msg.sender deliberately. The two are the same
     *      address in every normal buy; where they differ, msg.sender is paying on
     *      somebody's behalf and the change belongs with the ticket, not with the
     *      payer.
     *
     *      WETH dust is real and expected: `amountInMaximum` is a bound and the v3 leg
     *      usually spends less than it. It is returned as WETH rather than swapped
     *      back, which would cost more gas than the dust is worth.
     *
     *      The $CHIP actually spent is MEASURED here - what went in, less what came
     *      back - rather than taken from what the pool reported. The two should agree;
     *      if they ever did not, the number the buyer sees would be the true one.
     */
    function _refundAll(address recipient, uint256 maxChipIn) internal returns (uint256 chipSpent) {
        uint256 chipLeft = chip.balanceOf(address(this));
        if (chipLeft != 0) chip.safeTransfer(recipient, chipLeft);

        uint256 wethLeft = weth.balanceOf(address(this));
        if (wethLeft != 0) weth.safeTransfer(recipient, wethLeft);

        uint256 usdcLeft = usdc.balanceOf(address(this));
        if (usdcLeft != 0) usdc.safeTransfer(recipient, usdcLeft);

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
          currency0 is WETH and currency1 is $CHIP - v4 orders a key by address and
          0x4200... sorts below 0x75Af.... Selling $CHIP for WETH is therefore
          currency1 -> currency0, i.e. NOT zeroForOne.

          amountSpecified is POSITIVE for exact output: "give me exactly this much
          WETH and charge me what it costs".
        */
        int256 delta = poolManager.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: int256(wethOut),
                sqrtPriceLimitX96: MAX_SQRT_PRICE_LIMIT
            }),
            ""
        );

        // Packed (int128 amount0, int128 amount1). amount1 is $CHIP and is negative:
        // what this contract owes the pool. amount0 is the WETH it is owed.
        int128 amount1 = int128(delta);
        int128 amount0 = int128(delta >> 128);

        if (amount1 >= 0 || amount0 <= 0) revert NothingSwapped();

        uint256 chipOwed = uint256(uint128(-amount1));
        uint256 wethGot = uint256(uint128(amount0));

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
