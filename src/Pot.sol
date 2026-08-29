// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {ConversionRoutes} from "./base/ConversionRoutes.sol";

/// @title Pot
/// @notice Holds the money the 24h rounds draw from, and realises whatever arrives into
///         the round currency itself.
///
/// @dev Fees reach this contract in several shapes: ETH from the LP locker and royalties,
///      WETH from some venues, AERO from protocol-owned liquidity. Rounds can only spend
///      the quote token, so anything else has to be converted or it just sits there. The
///      full-system fork test caught exactly that: recycled AERO landed in the Pot and no
///      round could spend a cent of it.
///
///      CONVERSION IS A PER-TOKEN ROUTE TABLE. Each convertible token has its own row:
///      Chainlink feed, router, pool fee tier, slippage bound, per-call cap and staleness
///      limit. `convert(token)` is permissionless for every registered token, with the
///      minimum output bounded by that token's own Chainlink mark. Adding an income token
///      is one multisig call, not a redeploy.
///
///      THE PER-CALL CAP IS THE POINT. Without it a pot that has accumulated a large
///      balance gets walked through the pool in a single swap. Verified on a Base fork:
///      2 ETH converted comfortably inside the Chainlink floor, while an uncapped 500 ETH
///      breached the bound and was refused outright. Rounds are capped for the same reason.
///
///      UNCONVERTED ASSETS DO NOT COUNT. `available()` reports quote-token balance only, so
///      a round can never open against money that has not actually been realised.
contract Pot is Ownable2Step, ReentrancyGuard, ConversionRoutes {
    using SafeERC20 for IERC20;

    /// @notice The only address allowed to pull a round budget.
    address public rewards;

    event RewardsUpdated(address indexed previousRewards, address indexed newRewards);
    event BudgetPulled(address indexed to, uint256 amount);
    event Returned(address indexed from, uint256 amount);
    event NonQuoteSwept(address indexed token, address indexed to, uint256 amount);
    event EthSwept(address indexed to, uint256 amount);

    error ZeroAddress();
    error NotRewards(address caller);
    error CannotSweepQuoteToken();
    error NothingToSweep();
    error ConversionNotConfigured();

    constructor(address multisig, address quoteToken_) Ownable(multisig) ConversionRoutes(quoteToken_) {
        if (multisig == address(0)) revert ZeroAddress();
    }

    /// @notice Accept ETH from the FeeSplitter. Cheap on purpose so 2300-gas senders succeed.
    receive() external payable {}

    modifier onlyRewards() {
        if (msg.sender != rewards) revert NotRewards(msg.sender);
        _;
    }

    /* ------------------------------------------------------------------ */
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Round currency available to fund a round. Excludes anything unconverted.
    function available() public view returns (uint256) {
        return IERC20(quoteToken).balanceOf(address(this));
    }

    /// @notice How much the next ETH conversion would push through the pool.
    function nextConversionAmount() public view returns (uint256) {
        return nextConversionAmount(weth);
    }

    /// @notice Minimum quote-token output the ETH conversion would insist on.
    function conversionMinOut(uint256 ethAmount) public view returns (uint256) {
        return minOutFor(weth, ethAmount);
    }

    /* ------------------------------------------------------------------ */
    /*                            CONVERSION                                */
    /* ------------------------------------------------------------------ */

    /// @notice Turn accumulated ETH (and any WETH) into round currency. Permissionless.
    function convert() external nonReentrant returns (uint256 amountIn, uint256 quoteOut) {
        if (weth == address(0) || !_routes[weth].enabled) revert ConversionNotConfigured();
        return _convert(weth);
    }

    /// @notice Turn an accumulated income token into round currency. Permissionless.
    /// @dev This is how recycled POL income becomes budget a round can actually spend.
    ///      Same Chainlink-bounded, capped, permissionless shape as the ETH path.
    function convert(address token) external nonReentrant returns (uint256 amountIn, uint256 quoteOut) {
        if (!_routes[token].enabled) revert NoRoute(token);
        return _convert(token);
    }

    /* ------------------------------------------------------------------ */
    /*                            GOVERNANCE                                */
    /* ------------------------------------------------------------------ */

    /// @notice Point at the ChipRewards contract. Multisig only.
    function setRewards(address newRewards) external onlyOwner {
        if (newRewards == address(0)) revert ZeroAddress();
        emit RewardsUpdated(rewards, newRewards);
        rewards = newRewards;
    }

    /// @notice Set the wrapped-native token and its conversion route in one call.
    /// @dev Convenience wrapper over {setRoute} for the ETH path.
    function setConversionConfig(
        address weth_,
        address ethUsdFeed_,
        address swapRouter_,
        uint24 conversionFee_,
        uint32 maxSlippageBps_,
        uint128 maxConvertPerCall_,
        uint64 maxFeedAge_
    ) external onlyOwner {
        _setWeth(weth_);
        _setRoute(weth_, ethUsdFeed_, swapRouter_, conversionFee_, maxSlippageBps_, maxConvertPerCall_, maxFeedAge_);
    }

    /// @notice Register or update the conversion route for one token. Multisig only.
    function setRoute(
        address token,
        address feed,
        address router,
        uint24 fee,
        uint32 maxSlippageBps,
        uint128 maxPerCall,
        uint64 maxFeedAge
    ) external onlyOwner {
        _setRoute(token, feed, router, fee, maxSlippageBps, maxPerCall, maxFeedAge);
    }

    /// @notice Stop converting a token. Its balance stays put and can still be swept.
    function disableRoute(address token) external onlyOwner {
        _disableRoute(token);
    }

    /// @notice Send a round budget to ChipRewards. Callable only by ChipRewards.
    function pullBudget(uint256 amount) external onlyRewards returns (uint256) {
        uint256 balance = available();
        if (amount > balance) amount = balance;
        IERC20(quoteToken).safeTransfer(msg.sender, amount);
        emit BudgetPulled(msg.sender, amount);
        return amount;
    }

    /// @notice Logged when ChipRewards hands back budget a round could not spend.
    function noteReturned(uint256 amount) external {
        emit Returned(msg.sender, amount);
    }

    /// @notice Move a non-round-currency asset out. Multisig only.
    /// @dev Cannot touch the quote token: that is the round budget and belongs to holders.
    ///      Still useful for a token with no route, or one whose route is broken.
    function sweepNonQuote(address token, address to) external onlyOwner {
        if (token == quoteToken) revert CannotSweepQuoteToken();
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToSweep();
        IERC20(token).safeTransfer(to, amount);
        emit NonQuoteSwept(token, to, amount);
    }

    /// @notice Escape hatch for ETH if the conversion route is broken. Multisig only.
    function sweepEth(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToSweep();
        Address.sendValue(payable(to), amount);
        emit EthSwept(to, amount);
    }
}
