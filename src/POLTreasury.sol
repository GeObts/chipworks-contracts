// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {INonfungiblePositionManager, ISlipstreamGauge} from "./interfaces/INonfungiblePositionManager.sol";
import {ConversionRoutes} from "./base/ConversionRoutes.sol";

/// @title POLTreasury
/// @notice Protocol-owned liquidity. Receives the per-round stock holdback plus USDC,
///         pairs them into Aerodrome Slipstream positions, and routes the income those
///         positions throw off back to the FeeSplitter, where it re-enters the Pot.
///
/// @dev THE RESCUE RULE IS DIFFERENT HERE, ON PURPOSE.
///      In ChipRewards, `recoverExcess` protects a computed sum of user credits, because
///      that contract holds tokens on behalf of named claimants. POLTreasury does not: it
///      holds protocol assets, so "balance minus owed" would protect nothing and the rescue
///      would be an unrestricted drain.
///      Instead the rescue works by strict exclusion. It can NEVER move:
///        - the quote token,
///        - any registered POL asset,
///        - any registered income token,
///        - any position NFT.
///      It can only move tokens the treasury does not recognise — stray airdrops. Anything
///      the protocol actually owns leaves only through `forwardIncome` (to the splitter) or
///      a manager action on a position. There is no path that sends POL assets to a wallet.
///
///      ROLES. The multisig owns configuration. A separate `manager` role exists for the
///      Bankr optimizer to move ranges and stake gauges without holding the keys to the
///      configuration. Fee collection and income forwarding are permissionless, so income
///      can always be pushed back to holders even if the optimizer goes quiet.
contract POLTreasury is Ownable2Step, ReentrancyGuard, IERC721Receiver, ConversionRoutes {
    using SafeERC20 for IERC20;

    /// @notice Aerodrome Slipstream position manager.
    INonfungiblePositionManager public immutable positionManager;

    /// @notice Where POL income is sent. The FeeSplitter, which then feeds the Pot.
    address public feeSplitter;

    /// @notice The Bankr optimizer. May manage positions, may not change configuration.
    address public manager;

    /// @notice ChipRewards, the only contract allowed to record compound credits.
    address public rewards;

    /// @notice Tokens this treasury deliberately holds as POL. Never rescuable.
    mapping(address token => bool) public isPolAsset;

    /// @notice Tokens that count as income and get forwarded to the splitter (AERO,
    ///         collected fees). Never rescuable.
    mapping(address token => bool) public isIncomeToken;

    /// @notice Position NFTs this treasury holds.
    uint256[] public positionIds;
    mapping(uint256 tokenId => bool) public holdsPosition;

    /// @notice Compound-share ledger. USD value each holder has routed into POL.
    mapping(address owner => uint256) public compoundShares;
    uint256 public totalCompoundShares;

    event ManagerUpdated(address indexed previousManager, address indexed newManager);
    event FeeSplitterUpdated(address indexed previousSplitter, address indexed newSplitter);
    event RewardsUpdated(address indexed previousRewards, address indexed newRewards);
    event PolAssetSet(address indexed token, bool isPol);
    event IncomeTokenSet(address indexed token, bool isIncome);
    event PositionMinted(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event LiquidityIncreased(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event LiquidityDecreased(uint256 indexed tokenId, uint256 amount0, uint256 amount1);
    event FeesCollected(uint256 indexed tokenId, uint256 amount0, uint256 amount1);
    event IncomeForwarded(address indexed token, uint256 amount, address indexed to);
    event CompoundRecorded(address indexed owner, address indexed token, uint256 amount, uint256 usdValue);
    event PositionStaked(uint256 indexed tokenId, address indexed gauge);
    event PositionUnstaked(uint256 indexed tokenId, address indexed gauge);
    event ExcessRecovered(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error NotManager(address caller);
    error NotRewards(address caller);
    error ProtectedToken(address token);
    error NothingToForward(address token);
    error UnknownPosition(uint256 tokenId);
    error NothingToRecover(address token);

    constructor(
        address multisig,
        address quoteToken_,
        address positionManager_,
        address feeSplitter_,
        address uniswapV3Factory_
    ) Ownable(multisig) ConversionRoutes(quoteToken_, uniswapV3Factory_) {
        if (
            multisig == address(0) || quoteToken_ == address(0) || positionManager_ == address(0)
                || feeSplitter_ == address(0)
        ) revert ZeroAddress();
        positionManager = INonfungiblePositionManager(positionManager_);
        feeSplitter = feeSplitter_;
        emit FeeSplitterUpdated(address(0), feeSplitter_);
    }

    receive() external payable {}

    modifier onlyManager() {
        if (msg.sender != manager && msg.sender != owner()) revert NotManager(msg.sender);
        _;
    }

    /* ------------------------------------------------------------------ */
    /*                            GOVERNANCE                                */
    /* ------------------------------------------------------------------ */

    function setManager(address newManager) external onlyOwner {
        emit ManagerUpdated(manager, newManager);
        manager = newManager;
    }

    function setFeeSplitter(address newSplitter) external onlyOwner {
        if (newSplitter == address(0)) revert ZeroAddress();
        emit FeeSplitterUpdated(feeSplitter, newSplitter);
        feeSplitter = newSplitter;
    }

    function setRewards(address newRewards) external onlyOwner {
        emit RewardsUpdated(rewards, newRewards);
        rewards = newRewards;
    }

    /// @notice Mark a token as POL. Protected from the rescue from then on.
    function setPolAsset(address token, bool isPol) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        isPolAsset[token] = isPol;
        emit PolAssetSet(token, isPol);
    }

    /// @notice Mark a token as income, so `forwardIncome` will push it to the splitter.
    function setIncomeToken(address token, bool isIncome) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        isIncomeToken[token] = isIncome;
        emit IncomeTokenSet(token, isIncome);
    }

    /* ------------------------------------------------------------------ */
    /*                            CONVERSION                                */
    /* ------------------------------------------------------------------ */

    /// @notice Turn an asset the treasury holds into the quote token, so it can be paired
    ///         with the stock holdback. Permissionless.
    /// @dev POL receives its share of fees in whatever asset was flowing — ETH from the LP
    ///      locker, AERO from gauges. Without this the slice arrives in a form POL cannot
    ///      pair, which is the same gap the Pot had. Same Chainlink-bounded, capped shape.
    function convert(address token) external nonReentrant returns (uint256 amountIn, uint256 quoteOut) {
        if (!_routes[token].enabled) revert NoRoute(token);
        return _convert(token, 0);
    }

    /// @notice Set the wrapped-native token so native ETH can be converted. Multisig only.
    function setWeth(address weth_) external onlyOwner {
        _setWeth(weth_);
    }

    /// @notice Register or update a conversion route. Multisig only.
    function setRoute(
        address token,
        address feed,
        address router,
        uint24 fee,
        uint32 maxSlippageBps,
        uint128 maxPerCall,
        uint128 minPerCall,
        uint64 maxFeedAge
    ) external onlyOwner {
        _setRoute(token, feed, router, fee, maxSlippageBps, maxPerCall, minPerCall, maxFeedAge);
    }

    /// @notice Stop converting a token. Multisig only.
    function disableRoute(address token) external onlyOwner {
        _disableRoute(token);
    }

    /* ------------------------------------------------------------------ */
    /*                             POSITIONS                                */
    /* ------------------------------------------------------------------ */

    function positionCount() external view returns (uint256) {
        return positionIds.length;
    }

    /// @notice Open a new Slipstream position. Manager or multisig.
    /// @dev Approvals are set to the exact amounts and cleared afterwards, so a stale
    ///      allowance can never be left sitting on the position manager.
    function mintPosition(INonfungiblePositionManager.MintParams calldata params)
        external
        onlyManager
        nonReentrant
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        IERC20(params.token0).forceApprove(address(positionManager), params.amount0Desired);
        IERC20(params.token1).forceApprove(address(positionManager), params.amount1Desired);

        INonfungiblePositionManager.MintParams memory p = params;
        p.recipient = address(this); // never mint to anywhere but here

        (tokenId, liquidity, amount0, amount1) = positionManager.mint(p);

        IERC20(params.token0).forceApprove(address(positionManager), 0);
        IERC20(params.token1).forceApprove(address(positionManager), 0);

        if (!holdsPosition[tokenId]) {
            holdsPosition[tokenId] = true;
            positionIds.push(tokenId);
        }
        emit PositionMinted(tokenId, liquidity, amount0, amount1);
    }

    /// @notice Add to an existing position. Manager or multisig.
    function increaseLiquidity(
        uint256 tokenId,
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external onlyManager nonReentrant returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (!holdsPosition[tokenId]) revert UnknownPosition(tokenId);

        IERC20(token0).forceApprove(address(positionManager), amount0Desired);
        IERC20(token1).forceApprove(address(positionManager), amount1Desired);

        (liquidity, amount0, amount1) = positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp
            })
        );

        IERC20(token0).forceApprove(address(positionManager), 0);
        IERC20(token1).forceApprove(address(positionManager), 0);
        emit LiquidityIncreased(tokenId, liquidity, amount0, amount1);
    }

    /// @notice Pull liquidity out of a position, e.g. to re-range. Manager or multisig.
    /// @dev The withdrawn tokens land in this contract and stay here. There is no path
    ///      from this function to an external wallet.
    function decreaseLiquidity(uint256 tokenId, uint128 liquidity, uint256 amount0Min, uint256 amount1Min)
        external
        onlyManager
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (!holdsPosition[tokenId]) revert UnknownPosition(tokenId);
        (amount0, amount1) = positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp
            })
        );
        emit LiquidityDecreased(tokenId, amount0, amount1);
    }

    /// @notice Collect trading fees from a position. Permissionless.
    /// @dev Anyone may call it, and the proceeds can only land in this contract, so income
    ///      keeps flowing even if the optimizer stops.
    function collectFees(uint256 tokenId) public nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (!holdsPosition[tokenId]) revert UnknownPosition(tokenId);
        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        emit FeesCollected(tokenId, amount0, amount1);
    }

    /// @notice Collect from every position we hold. Permissionless.
    /// @dev One failing position is skipped rather than reverting the sweep, so a single
    ///      broken or frozen pair cannot stop the others from paying out.
    function collectAllFees() external returns (uint256 collected) {
        uint256 len = positionIds.length;
        for (uint256 i; i < len; ++i) {
            try this.collectFees(positionIds[i]) returns (uint256, uint256) {
                ++collected;
            } catch {}
        }
    }

    /* ------------------------------------------------------------------ */
    /*                          GAUGE STAKING                               */
    /* ------------------------------------------------------------------ */

    /// @notice Stake a position in its Aerodrome gauge to earn AERO. Manager or multisig.
    function stakePosition(uint256 tokenId, address gauge) external onlyManager nonReentrant {
        if (!holdsPosition[tokenId]) revert UnknownPosition(tokenId);
        if (gauge == address(0)) revert ZeroAddress();
        IERC721Approve(address(positionManager)).approve(gauge, tokenId);
        ISlipstreamGauge(gauge).deposit(tokenId);
        emit PositionStaked(tokenId, gauge);
    }

    /// @notice Withdraw a staked position back to this contract. Manager or multisig.
    function unstakePosition(uint256 tokenId, address gauge) external onlyManager nonReentrant {
        if (!holdsPosition[tokenId]) revert UnknownPosition(tokenId);
        ISlipstreamGauge(gauge).withdraw(tokenId);
        emit PositionUnstaked(tokenId, gauge);
    }

    /// @notice Claim AERO for a staked position. Permissionless.
    function claimGaugeRewards(uint256 tokenId, address gauge) external nonReentrant {
        if (!holdsPosition[tokenId]) revert UnknownPosition(tokenId);
        ISlipstreamGauge(gauge).getReward(tokenId);
    }

    /* ------------------------------------------------------------------ */
    /*                              INCOME                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Push one income token to the FeeSplitter, where it re-enters the Pot.
    ///         Permissionless.
    /// @dev One token per call, deliberately. A frozen or paused income token fails only
    ///      its own call and cannot block the others.
    function forwardIncome(address token) public nonReentrant returns (uint256 amount) {
        if (!isIncomeToken[token]) revert ProtectedToken(token);
        amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToForward(token);
        IERC20(token).safeTransfer(feeSplitter, amount);
        emit IncomeForwarded(token, amount, feeSplitter);
    }

    /// @notice Push several income tokens. Empty or failing ones are skipped, so one bad
    ///         token cannot brick the batch.
    function forwardIncomeMany(address[] calldata tokens) external returns (uint256 forwarded) {
        for (uint256 i; i < tokens.length; ++i) {
            try this.forwardIncome(tokens[i]) returns (uint256) {
                ++forwarded;
            } catch {}
        }
    }

    /* ------------------------------------------------------------------ */
    /*                        COMPOUND SHARE LEDGER                         */
    /* ------------------------------------------------------------------ */

    /// @notice Record that a holder routed a claim into POL instead of taking it.
    /// @dev Only ChipRewards may call this. ChipRewards treats the call as best-effort so
    ///      a problem here can never block someone's claim; its own counter is the
    ///      authoritative record and this is the POL-side view of the same event.
    function notifyCompound(address owner, address token, uint256 amount, uint256 usdValue) external {
        if (msg.sender != rewards) revert NotRewards(msg.sender);
        compoundShares[owner] += usdValue;
        totalCompoundShares += usdValue;
        emit CompoundRecorded(owner, token, amount, usdValue);
    }

    /* ------------------------------------------------------------------ */
    /*                              RESCUE                                  */
    /* ------------------------------------------------------------------ */

    /// @notice True if the rescue is forbidden from moving this token.
    function isProtected(address token) public view returns (bool) {
        return token == quoteToken || isPolAsset[token] || isIncomeToken[token];
    }

    /// @notice Recover a token the treasury does not recognise. Multisig only.
    /// @dev Deliberately narrow: see the rescue rule at the top of this contract. Protocol
    ///      assets are not reachable by this function at any amount.
    function recoverExcess(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (isProtected(token)) revert ProtectedToken(token);
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (amount == 0 || amount > balance) revert NothingToRecover(token);
        IERC20(token).safeTransfer(to, amount);
        emit ExcessRecovered(token, to, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                             ERC721                                   */
    /* ------------------------------------------------------------------ */

    /// @notice Accept position NFTs, and remember any that arrive unannounced.
    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external override returns (bytes4) {
        if (msg.sender == address(positionManager) && !holdsPosition[tokenId]) {
            holdsPosition[tokenId] = true;
            positionIds.push(tokenId);
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

interface IERC721Approve {
    function approve(address to, uint256 tokenId) external;
}
