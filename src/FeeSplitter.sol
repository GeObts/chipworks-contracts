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

    error ZeroAddress();
    error OpsBpsTooHigh(uint32 provided, uint32 maximum);
    error MaxOpsBpsTooHigh(uint32 provided, uint32 maximum);
    error NothingToDistribute(address asset);
    error PolShareTooHigh(uint32 provided, uint32 maximum);
    error PolTreasuryNotSet();
    error SharesExceedTotal(uint32 opsBps, uint32 polBps);

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
        uint256 balance = address(this).balance;
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
        uint256 balance = address(this).balance;
        if (balance != 0) _splitETH(balance);
        for (uint256 i; i < tokens.length; ++i) {
            IERC20 token = tokens[i];
            if (address(token) == address(0)) continue;
            uint256 tokenBalance = token.balanceOf(address(this));
            if (tokenBalance == 0) continue;
            _splitToken(token, tokenBalance);
        }
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

    function _splitETH(uint256 amount) internal returns (uint256 potAmount, uint256 opsAmount, uint256 polAmount) {
        (potAmount, opsAmount, polAmount) = previewSplit(amount);
        emit Distributed(address(0), potAmount, opsAmount, polAmount, msg.sender);
        if (potAmount != 0) Address.sendValue(payable(pot), potAmount);
        if (opsAmount != 0) Address.sendValue(payable(ops), opsAmount);
        if (polAmount != 0) Address.sendValue(payable(polTreasury), polAmount);
    }

    function _splitToken(IERC20 token, uint256 amount)
        internal
        returns (uint256 potAmount, uint256 opsAmount, uint256 polAmount)
    {
        (potAmount, opsAmount, polAmount) = previewSplit(amount);
        emit Distributed(address(token), potAmount, opsAmount, polAmount, msg.sender);
        if (potAmount != 0) token.safeTransfer(pot, potAmount);
        if (opsAmount != 0) token.safeTransfer(ops, opsAmount);
        if (polAmount != 0) token.safeTransfer(polTreasury, polAmount);
    }
}
