// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title FeeSplitter
/// @notice Single collection point for every Chipworks fee stream: CHIP/ETH pool
///         fees via the LP locker, secondary royalties, POL income (Aerodrome fees
///         plus AERO), and arcade rake. Splits everything it holds between the Pot
///         (which funds the 24h rounds), the ops wallet, and optionally the POL treasury.
///
/// @dev Design notes:
///      - PULL, NOT PUSH. Nothing is split inside receive(). Fee sources vary
///        wildly in how much gas they forward (some LP lockers still use the
///        2300-gas transfer), so receive() here is deliberately empty and cheap.
///        Splitting happens when someone calls distributeETH or distributeToken,
///        which is permissionless: the keeper bot, the website, or any passer-by
///        can trigger it.
///      - The split is CONFIGURED, never hardcoded. opsBps is a constructor
///        argument and the multisig can change it later, but only within
///        maxOpsBps, which is immutable. That bound is the holder protection:
///        even a compromised multisig cannot route more than maxOpsBps to ops.
///      - Rounding dust always favours the Pot (holders), never ops or POL.
///      - ONE BAD RECIPIENT CANNOT FREEZE THE OTHER TWO. ETH legs are paid with a bounded
///        gas stipend and, on failure, credited to a claimable escrow instead of reverting
///        the batch. A paused Pot, an ops wallet that becomes a contract without a payable
///        fallback, or a POL treasury mid-upgrade therefore costs that recipient a delay and
///        costs everybody else nothing. See {withdrawEth}. Raised by external review as
///        SEC-FEE-001.
///      - THE POT IS THE RESIDUAL CLAIMANT. Ops and POL are paid their exact computed
///        shares; the Pot takes whatever is left. That is what makes rounding dust land on
///        holders, and it is also what stops a token that takes a cut in transit from making
///        the final transfer exceed the balance. See {_splitToken} and SEC-FEE-003.
///      - The POL leg is OPT-IN and defaults to zero. It exists so protocol-owned
///        liquidity can pair its stock holdback with quote token of its own, rather than
///        depending on expired reward credits or manual transfers out of ops. It is capped
///        at MAX_POL_SHARE_BPS, which is a constant, not a setting.
contract FeeSplitter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Basis-point denominator. 10_000 bps equals 100 percent.
    uint32 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard ceiling on the ops share, fixed forever at deploy time.
    uint32 public immutable maxOpsBps;

    /// @notice Gas handed to each ETH leg.
    ///
    /// @dev SIZED TO HONOUR TWO OPPOSING REQUIREMENTS, so the number is not arbitrary.
    ///
    ///      Too low and the escrow stops being a safety net and becomes the normal path: the
    ///      2300-gas `transfer()` stipend is famously too small for a Safe, a proxy, or any
    ///      recipient that writes a slot on receipt, and this contract has always
    ///      deliberately forwarded more than that.
    ///
    ///      Too high — unbounded, say — and a hostile recipient burns 63/64 of the remaining
    ///      gas under EIP-150 and starves the legs after it, which is the wedge the escrow
    ///      exists to prevent.
    ///
    ///      150,000 clears a recipient doing real work on receipt (several cold storage
    ///      writes is ~110k) while bounding a worst case of three legs to under half a
    ///      million — comfortable in any block. Both real recipients, `Pot` and
    ///      `POLTreasury`, have an empty `receive()` and use a few hundred.
    uint256 public constant PAYOUT_GAS = 150_000;

    /// @notice Largest number of tokens one batched call may touch. SEC-FEE-004.
    /// @dev The batch entry points are permissionless, so an unbounded array is a way for a
    ///      caller to build a transaction that cannot fit in a block and then blame the
    ///      protocol. The keeper pages; nothing here needs a hundred tokens at once.
    uint256 public constant MAX_BATCH = 32;

    /// @notice ETH owed to a recipient whose payment failed, claimable via {withdrawEth}.
    mapping(address recipient => uint256) public owedEth;

    /// @notice Sum of {owedEth}. Held back from every split so escrow is never re-split.
    uint256 public totalOwedEth;

    /// @notice Hard ceiling on the POL share. Fixed in code, not configurable.
    /// @dev POL is protocol-owned, so a slice routed there is not lost to holders the way
    ///      the ops share is. It is still capped, because a large POL share delays rewards
    ///      in favour of liquidity and that trade-off should be bounded by something other
    ///      than a multisig vote.
    uint32 public constant MAX_POL_SHARE_BPS = 2_000;

    /// @notice Current ops share in basis points. The Pot receives the remainder.
    uint32 public opsBps;

    /// @notice Contract that funds the 24h reward rounds.
    address public pot;

    /// @notice Operations wallet.
    address public ops;

    /// @notice Share of every inflow routed to protocol-owned liquidity, in basis points.
    /// @dev Defaults to zero: the three-way split is opt-in. This exists so POL can pair
    ///      its stock holdback with quote token of its own, instead of depending on
    ///      expired credits or manual transfers from ops. See OPEN_ITEMS.md item 2.
    uint32 public polShareBps;

    /// @notice Protocol-owned liquidity treasury. May be unset while `polShareBps` is zero.
    address public polTreasury;

    event Distributed(
        address indexed asset, uint256 potAmount, uint256 opsAmount, uint256 polAmount, address indexed caller
    );
    event OpsUpdated(address indexed previousOps, address indexed newOps);
    event PotUpdated(address indexed previousPot, address indexed newPot);
    event OpsBpsUpdated(uint32 previousOpsBps, uint32 newOpsBps);
    event PolTreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event PolShareBpsUpdated(uint32 previousBps, uint32 newBps);
    /// @notice An ETH leg could not be paid and is now claimable by `recipient`.
    event EthEscrowed(address indexed recipient, uint256 amount, uint256 totalOwed);
    event EthWithdrawn(address indexed recipient, uint256 amount);

    error ZeroAddress();
    error OpsBpsTooHigh(uint32 provided, uint32 maximum);
    error MaxOpsBpsTooHigh(uint32 provided, uint32 maximum);
    error NothingToDistribute(address asset);
    error PolShareTooHigh(uint32 provided, uint32 maximum);
    error PolTreasuryNotSet();
    error SharesExceedTotal(uint32 opsBps, uint32 polBps);
    error NothingOwed(address recipient);
    error BatchTooLarge(uint256 provided, uint256 maximum);

    /// @param multisig   Owner. Governs ops, pot and opsBps. Must be the multisig.
    /// @param pot_       Pot contract address (round budget).
    /// @param ops_       Operations wallet.
    /// @param opsBps_    Initial ops share in bps. Spec calls for 2000 (20 percent).
    /// @param maxOpsBps_ Immutable ceiling for opsBps. Recommend 2000 unless you
    ///                   deliberately want headroom to raise the ops share later.
    constructor(address multisig, address pot_, address ops_, uint32 opsBps_, uint32 maxOpsBps_) Ownable(multisig) {
        if (multisig == address(0) || pot_ == address(0) || ops_ == address(0)) revert ZeroAddress();
        if (maxOpsBps_ > BPS_DENOMINATOR) revert MaxOpsBpsTooHigh(maxOpsBps_, BPS_DENOMINATOR);
        if (opsBps_ > maxOpsBps_) revert OpsBpsTooHigh(opsBps_, maxOpsBps_);

        maxOpsBps = maxOpsBps_;
        opsBps = opsBps_;
        pot = pot_;
        ops = ops_;

        emit PotUpdated(address(0), pot_);
        emit OpsUpdated(address(0), ops_);
        emit OpsBpsUpdated(0, opsBps_);
    }

    /// @notice Accept ETH from any fee source. Intentionally does no work and emits
    ///         no event, so that senders forwarding only 2300 gas still succeed.
    receive() external payable {}

    /* ------------------------------------------------------------------ */
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    /// @notice ETH available to split: the balance minus anything already owed to a
    ///         recipient whose payment failed.
    /// @dev THIS IS THE NUMBER EVERY ETH SPLIT USES, not `address(this).balance`. Escrowed
    ///      ETH is already allocated to somebody; re-splitting it would pay it out twice and
    ///      leave the escrow unbacked.
    function distributableEth() public view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 owed = totalOwedEth;
        return balance > owed ? balance - owed : 0;
    }

    /// @notice Pot share in basis points. Whatever ops and POL do not take.
    function potBps() public view returns (uint32) {
        return BPS_DENOMINATOR - opsBps - polShareBps;
    }

    /// @notice Preview how amount would be split, without moving anything.
    /// @dev Rounding dust always lands on the Pot, never on ops or POL.
    function previewSplit(uint256 amount)
        public
        view
        returns (uint256 potAmount, uint256 opsAmount, uint256 polAmount)
    {
        opsAmount = (amount * opsBps) / BPS_DENOMINATOR;
        polAmount = (amount * polShareBps) / BPS_DENOMINATOR;
        potAmount = amount - opsAmount - polAmount;
    }

    /* ------------------------------------------------------------------ */
    /*                          DISTRIBUTION                                */
    /* ------------------------------------------------------------------ */

    /// @notice Split the full ETH balance. Permissionless.
    function distributeETH() external nonReentrant returns (uint256 potAmount, uint256 opsAmount, uint256 polAmount) {
        uint256 balance = distributableEth();
        if (balance == 0) revert NothingToDistribute(address(0));
        (potAmount, opsAmount, polAmount) = _splitETH(balance);
    }

    /// @notice Split the full balance of one ERC-20. Permissionless.
    function distributeToken(IERC20 token)
        external
        nonReentrant
        returns (uint256 potAmount, uint256 opsAmount, uint256 polAmount)
    {
        if (address(token) == address(0)) revert ZeroAddress();
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) revert NothingToDistribute(address(token));
        (potAmount, opsAmount, polAmount) = _splitToken(token, balance);
    }

    /// @notice Split several ERC-20s in one transaction. Zero balances are skipped
    ///         rather than reverting, so one empty token cannot brick a batch.
    function distributeTokens(IERC20[] calldata tokens) external nonReentrant {
        if (tokens.length > MAX_BATCH) revert BatchTooLarge(tokens.length, MAX_BATCH);
        for (uint256 i; i < tokens.length; ++i) {
            IERC20 token = tokens[i];
            if (address(token) == address(0)) continue;
            uint256 balance = token.balanceOf(address(this));
            if (balance == 0) continue;
            _splitToken(token, balance);
        }
    }

    /// @notice Split ETH and a list of ERC-20s in one transaction. Nothing reverts
    ///         on an empty balance; this is the keeper bot default entry point.
    function distributeAll(IERC20[] calldata tokens) external nonReentrant {
        if (tokens.length > MAX_BATCH) revert BatchTooLarge(tokens.length, MAX_BATCH);
        uint256 balance = distributableEth();
        if (balance != 0) _splitETH(balance);
        for (uint256 i; i < tokens.length; ++i) {
            IERC20 token = tokens[i];
            if (address(token) == address(0)) continue;
            uint256 tokenBalance = token.balanceOf(address(this));
            if (tokenBalance == 0) continue;
            _splitToken(token, tokenBalance);
        }
    }

    /// @notice Pay out ETH escrowed for `recipient` after a failed distribution leg.
    ///
    /// @dev PERMISSIONLESS, and it always pays the recipient rather than the caller — same
    ///      rule as `ChipClaims.claimFor`, for the same reason: a stranger calling it can
    ///      only help, so a keeper can clear a stuck balance without anybody handing over a
    ///      key. Full gas is forwarded here, unlike the bounded stipend during a split,
    ///      because at this point one recipient's failure can only cost that recipient.
    ///
    ///      A failure reverts the whole call, which rolls the bookkeeping back — the escrow
    ///      is not consumed by a payment that did not land.
    function withdrawEth(address recipient) external nonReentrant returns (uint256 amount) {
        amount = owedEth[recipient];
        if (amount == 0) revert NothingOwed(recipient);

        owedEth[recipient] = 0;
        totalOwedEth -= amount;

        Address.sendValue(payable(recipient), amount);
        emit EthWithdrawn(recipient, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                          GOVERNANCE                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Change the operations wallet. Multisig only.
    function setOps(address newOps) external onlyOwner {
        if (newOps == address(0)) revert ZeroAddress();
        emit OpsUpdated(ops, newOps);
        ops = newOps;
    }

    /// @notice Point at a new Pot, for example after a Pot redeploy. Multisig only.
    function setPot(address newPot) external onlyOwner {
        if (newPot == address(0)) revert ZeroAddress();
        emit PotUpdated(pot, newPot);
        pot = newPot;
    }

    /// @notice Change the ops share. Multisig only, capped by the immutable maxOpsBps.
    function setOpsBps(uint32 newOpsBps) external onlyOwner {
        if (newOpsBps > maxOpsBps) revert OpsBpsTooHigh(newOpsBps, maxOpsBps);
        if (uint256(newOpsBps) + polShareBps > BPS_DENOMINATOR) revert SharesExceedTotal(newOpsBps, polShareBps);
        emit OpsBpsUpdated(opsBps, newOpsBps);
        opsBps = newOpsBps;
    }

    /// @notice Set the protocol-owned liquidity treasury. Multisig only.
    function setPolTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit PolTreasuryUpdated(polTreasury, newTreasury);
        polTreasury = newTreasury;
    }

    /// @notice Route a slice of every inflow to POL. Multisig only, capped at
    ///         {MAX_POL_SHARE_BPS}. Defaults to zero, so the split stays two-way until
    ///         someone deliberately turns this on.
    /// @dev Requires a treasury to be set first, so a non-zero share can never be
    ///      configured with nowhere to send it.
    function setPolShareBps(uint32 newPolShareBps) external onlyOwner {
        if (newPolShareBps > MAX_POL_SHARE_BPS) revert PolShareTooHigh(newPolShareBps, MAX_POL_SHARE_BPS);
        if (newPolShareBps != 0 && polTreasury == address(0)) revert PolTreasuryNotSet();
        if (uint256(opsBps) + newPolShareBps > BPS_DENOMINATOR) revert SharesExceedTotal(opsBps, newPolShareBps);
        emit PolShareBpsUpdated(polShareBps, newPolShareBps);
        polShareBps = newPolShareBps;
    }

    /* ------------------------------------------------------------------ */
    /*                           INTERNALS                                  */
    /* ------------------------------------------------------------------ */

    /// @dev SEC-FEE-001. Each leg is attempted with a bounded stipend and escrowed on
    ///      failure, so the split ALWAYS completes. The amounts in {Distributed} are the
    ///      allocation, not proof of receipt — check {EthEscrowed} for what did not land.
    function _splitETH(uint256 amount) internal returns (uint256 potAmount, uint256 opsAmount, uint256 polAmount) {
        (potAmount, opsAmount, polAmount) = previewSplit(amount);
        emit Distributed(address(0), potAmount, opsAmount, polAmount, msg.sender);
        _payEth(pot, potAmount);
        _payEth(ops, opsAmount);
        if (polAmount != 0) _payEth(polTreasury, polAmount);
    }

    /// @dev Attempt, then escrow. Never reverts, which is the whole point: a recipient that
    ///      cannot accept ETH must not be able to hold the other two hostage, nor to stop
    ///      new fees being split as they arrive.
    function _payEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount, gas: PAYOUT_GAS}("");
        if (ok) return;

        owedEth[to] += amount;
        totalOwedEth += amount;
        emit EthEscrowed(to, amount, totalOwedEth);
    }

    /// @dev SEC-FEE-003. Ops and POL are paid their exact shares; THE POT TAKES WHAT IS LEFT.
    ///
    ///      The ordering is the fix. Paying the Pot first and the others from a precomputed
    ///      remainder means a token that takes a cut in transit leaves the final transfer
    ///      larger than the balance, and `safeTransfer` reverts — freezing that token's fees
    ///      entirely. Paying the Pot last, from the measured remaining balance, cannot
    ///      overdraw by construction.
    ///
    ///      It also keeps the existing promise: with a well-behaved token the Pot receives
    ///      exactly `potAmount` plus every wei of rounding dust, because ops and POL take
    ///      their floors and the remainder is the Pot's share. The Pot is simply the residual
    ///      claimant in both directions — it gains the dust and absorbs any transit
    ///      shortfall, which is the honest place to put it, since holders are also the ones
    ///      the token was collected for.
    ///
    ///      No fee token Chipworks routes today behaves this way (WETH, USDC, AERO, $CHIP).
    ///      This is the same "measure, never assume" discipline `ChipRounds._deliver` and
    ///      `ChipClaims.recordAcquired` already apply, made consistent here.
    function _splitToken(IERC20 token, uint256 amount)
        internal
        returns (uint256 potAmount, uint256 opsAmount, uint256 polAmount)
    {
        (potAmount, opsAmount, polAmount) = previewSplit(amount);

        opsAmount = _payToken(token, ops, opsAmount);
        if (polAmount != 0) polAmount = _payToken(token, polTreasury, polAmount);

        uint256 remaining = token.balanceOf(address(this));
        if (remaining < potAmount) potAmount = remaining;
        potAmount = _payToken(token, pot, potAmount);

        emit Distributed(address(token), potAmount, opsAmount, polAmount, msg.sender);
    }

    /// @dev Moves `amount` and reports what actually left this contract.
    function _payToken(IERC20 token, address to, uint256 amount) internal returns (uint256 moved) {
        if (amount == 0) return 0;
        uint256 before = token.balanceOf(address(this));
        token.safeTransfer(to, amount);
        uint256 remaining = token.balanceOf(address(this));
        moved = before > remaining ? before - remaining : 0;
    }
}
