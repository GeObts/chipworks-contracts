// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {INonfungiblePositionManager, ISlipstreamGauge} from "./interfaces/INonfungiblePositionManager.sol";
import {ISlipstreamFactory, IAerodromeVoter} from "./interfaces/IAmmFactories.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {ConversionRoutes} from "./base/ConversionRoutes.sol";

/// @title POLTreasury
/// @notice Protocol-owned liquidity. Receives the per-round stock holdback plus USDC,
///         pairs them into Aerodrome Slipstream positions, and routes the income those
///         positions throw off back to the FeeSplitter, where it re-enters the Pot.
///
/// @dev THE MANAGER IS A HOT KEY, AND THIS CONTRACT IS WRITTEN AS IF IT IS ALREADY LEAKED.
///
///      `manager` exists so the Bankr optimizer can move ranges without holding the keys to
///      configuration. That is a session key on a server, so the only useful security claim
///      is one that survives its loss. External review (TRIAGE batch 6, H-01/H-02) showed the
///      earlier version did not: the per-operation allowance work was real but it hardened
///      the wrong layer. Allowances were never the vector. **The vector was the parameters.**
///      A leaked key could stake a position into a contract of its own choosing, or mint the
///      whole USDC balance against a token it had just printed, with correctly-scoped,
///      promptly-cleared approvals throughout.
///
///      So every `onlyManager` entry point is now written to be safe for ANY arguments:
///
///        1. TOKENS ARE ALLOWLISTED. A position is always the quote token paired with a
///           registered POL asset. There is no path that touches an arbitrary token.
///        2. POOLS ARE DERIVED, NOT SUPPLIED. The pool comes from the Slipstream factory for
///           that exact pair and tick spacing, and `sqrtPriceX96` is forced to zero, so a
///           caller can neither name a pool nor create one at a price of their choosing.
///        3. GAUGES ARE VERIFIED AGAINST THE VOTER. `voter.gauges(pool)` is the only thing
///           that makes an address a gauge, with the pool derived from the position itself.
///        4. EXECUTION IS BOUNDED BY CHAINLINK. The pool's own price must sit inside a band
///           around the POL asset's feed before liquidity moves in either direction. That
///           band, not the caller's minimums, is what bounds the value that moves; blank
///           minimums are refused on top of it as operator hygiene.
///
///      What a leaked manager key can still do is move liquidity between honest ranges of
///      honest pools at honest prices. It cannot send value anywhere, because no manager
///      function has a destination argument at all. That is the claim, and it is enforced
///      here rather than by key hygiene.
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
///        - the position manager itself, and so no position NFT.
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

    /// @notice Widest band a POL asset may be registered with: 10%.
    uint32 public constant MAX_DEVIATION_BPS = 1_000;

    /// @notice Aerodrome Slipstream position manager.
    INonfungiblePositionManager public immutable positionManager;

    /// @notice The concentrated-liquidity factory the position manager itself reports.
    /// @dev Read from `positionManager.factory()` at construction rather than passed in, so
    ///      the pool check can never be pointed at a factory that disagrees with the manager
    ///      the positions actually live in.
    address public immutable positionFactory;

    /// @notice Aerodrome's Voter. The only authority on which gauge belongs to which pool.
    IAerodromeVoter public immutable voter;

    /// @notice Where POL income is sent. The FeeSplitter, which then feeds the Pot.
    address public feeSplitter;

    /// @notice The Bankr optimizer. May manage positions, may not change configuration.
    address public manager;

    /// @notice ChipRewards, the only contract allowed to record compound credits.
    address public rewards;

    /// @notice A token this treasury deliberately holds as POL, and the feed that prices it.
    /// @dev The feed is MANDATORY. An optional price check that silently does nothing when
    ///      the feed was forgotten is exactly the shape of guard this repo has already been
    ///      bitten by once (the `setCustodian` trap in LAUNCH_CONFIG). A POL asset without a
    ///      price is one no LP operation could bound, so it cannot be registered at all.
    struct PolAsset {
        bool registered;
        address feed; // Chainlink <asset>/USD
        uint8 tokenDecimals; // cached
        uint8 feedDecimals; // cached
        uint32 maxDeviationBps; // how far the pool price may sit from the feed
        uint64 maxFeedAge; // reject a feed older than this. 0 disables the check
    }

    mapping(address token => PolAsset) internal _polAssets;

    /// @notice Tokens that count as income and get forwarded to the splitter (AERO,
    ///         collected fees). Never rescuable.
    mapping(address token => bool) public isIncomeToken;

    /// @notice Position NFTs this treasury holds.
    uint256[] public positionIds;
    mapping(uint256 tokenId => bool) public holdsPosition;

    /// @notice Which gauge a position is staked in, if any. Set only by `stakePosition`.
    mapping(uint256 tokenId => address) public stakedIn;

    /// @notice Compound-share ledger. USD value each holder has routed into POL.
    mapping(address owner => uint256) public compoundShares;
    uint256 public totalCompoundShares;

    event ManagerUpdated(address indexed previousManager, address indexed newManager);
    event FeeSplitterUpdated(address indexed previousSplitter, address indexed newSplitter);
    event RewardsUpdated(address indexed previousRewards, address indexed newRewards);
    event PolAssetSet(address indexed token, address feed, uint32 maxDeviationBps, uint64 maxFeedAge);
    event PolAssetRemoved(address indexed token);
    event IncomeTokenSet(address indexed token, bool isIncome);
    event PositionMinted(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event PositionRegistered(uint256 indexed tokenId);
    event PositionPruned(uint256 indexed tokenId);
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
    error BadConfig();

    /// @notice H-01. The address is not the gauge Aerodrome's voter names for this pool.
    error GaugeNotCanonical(address gauge);
    /// @notice H-01. The gauge did not take custody, so a live approval would have been left.
    error GaugeDidNotCustody(address gauge);
    /// @notice H-02(a). A token in the pair is not a registered POL asset.
    error TokenNotPolAsset(address token);
    /// @notice H-02(a). Every POL position is quote-paired; neither side was the quote token.
    error NotQuotePaired();
    /// @notice H-02(b). The Slipstream factory has no pool for that pair and tick spacing.
    error PoolNotCanonical(address pool);
    /// @notice H-02(c). The pool's price is outside the band around the POL asset's feed.
    error PoolPriceOffMark(uint256 poolPrice, uint256 markPrice);
    /// @notice H-02(c). The pool would not report a price at all.
    error PoolPriceUnavailable(address pool);
    /// @notice H-02(c)/(d). Minimums were blank or looser than the configured bound.
    error SlippageUnbounded();
    /// @notice M-02. Income tokens must be disjoint from the quote token and POL assets.
    error TokenNotDisjoint(address token);
    /// @notice M-03. The position is still held here, or still staked, so it cannot be pruned.
    error PositionStillHeld(uint256 tokenId);

    constructor(
        address multisig,
        address quoteToken_,
        address positionManager_,
        address feeSplitter_,
        address uniswapV3Factory_,
        address voter_
    ) Ownable(multisig) ConversionRoutes(quoteToken_, uniswapV3Factory_) {
        if (
            multisig == address(0) || quoteToken_ == address(0) || positionManager_ == address(0)
                || feeSplitter_ == address(0) || voter_ == address(0)
        ) revert ZeroAddress();
        positionManager = INonfungiblePositionManager(positionManager_);
        voter = IAerodromeVoter(voter_);

        address f = INonfungiblePositionManager(positionManager_).factory();
        if (f == address(0)) revert ZeroAddress();
        positionFactory = f;

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

    /// @notice Register a token as POL, with the feed that bounds every LP operation on it.
    /// @dev Registration is what makes an asset usable in `mintPosition` at all, so this is
    ///      the whole of the H-02(a) allowlist. Re-registering an existing asset updates its
    ///      feed and band.
    function setPolAsset(address token, address feed, uint32 maxDeviationBps, uint64 maxFeedAge) external onlyOwner {
        if (token == address(0) || feed == address(0)) revert ZeroAddress();
        if (token == quoteToken) revert TokenNotDisjoint(token);
        if (isIncomeToken[token]) revert TokenNotDisjoint(token); // M-02
        if (maxDeviationBps == 0 || maxDeviationBps > MAX_DEVIATION_BPS) revert BadConfig();

        uint8 feedDecimals = IAggregatorV3(feed).decimals();
        if (feedDecimals == 0 || feedDecimals > 18) revert BadConfig();

        _polAssets[token] = PolAsset({
            registered: true,
            feed: feed,
            tokenDecimals: _probeDecimals(token),
            feedDecimals: feedDecimals,
            maxDeviationBps: maxDeviationBps,
            maxFeedAge: maxFeedAge
        });
        emit PolAssetSet(token, feed, maxDeviationBps, maxFeedAge);
    }

    /// @notice Stop treating a token as POL. It stays protected from the rescue only while
    ///         registered, so this is a deliberate two-consequence action.
    /// @dev There is no on-chain enumeration of POL assets: nothing in this contract iterates
    ///      them, and the array plus its removal loop cost more code size than the repo's
    ///      24,000-byte budget had to spare. `PolAssetSet` and `PolAssetRemoved` carry the
    ///      full history, so the set is reconstructible from logs.
    function removePolAsset(address token) external onlyOwner {
        if (!_polAssets[token].registered) revert TokenNotPolAsset(token);
        delete _polAssets[token];
        emit PolAssetRemoved(token);
    }

    /// @notice Mark a token as income, so `forwardIncome` will push it to the splitter.
    /// @dev M-02. `forwardIncome` sends the FULL balance of an income token to the splitter,
    ///      so an income token that was also a POL asset or the quote token would turn a
    ///      permissionless function into a drain of pairing inventory. The two sets are kept
    ///      disjoint here, in both directions — see also `setPolAsset`.
    function setIncomeToken(address token, bool isIncome) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (isIncome) {
            if (token == quoteToken || _polAssets[token].registered) revert TokenNotDisjoint(token);
        }
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

    /// @notice Convert with a floor of the caller's own, on top of the Chainlink one.
    /// @dev M-01, and the call that finally makes SEC-POT-002 reachable. The keeper-floor
    ///      defence was built into `_convert` in batch 3, but on this contract the only
    ///      caller passed a hardcoded zero — so the parameter existed and the defence did
    ///      not. A keeper holding a real quote can now refuse a worse fill. The floor may
    ///      only be RAISED: `_convert` takes the maximum of this and the Chainlink minimum,
    ///      so a caller can tighten the bound and never widen it.
    function convert(address token, uint256 callerMinOut)
        external
        nonReentrant
        returns (uint256 amountIn, uint256 quoteOut)
    {
        if (!_routes[token].enabled) revert NoRoute(token);
        return _convert(token, callerMinOut);
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
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    function positionCount() external view returns (uint256) {
        return positionIds.length;
    }

    function isPolAsset(address token) public view returns (bool) {
        return _polAssets[token].registered;
    }

    function polAssetOf(address token) external view returns (PolAsset memory) {
        return _polAssets[token];
    }

    /// @notice The gauge Aerodrome names for a position's pool. Zero if the pool has none.
    function canonicalGaugeOf(uint256 tokenId) external view returns (address) {
        (address pool,,) = _positionPool(tokenId);
        return voter.gauges(pool);
    }

    /// @notice Quote-token value of one whole `asset` at its Chainlink mark, and at `pool`.
    /// @dev Exposed so an operator can see why an operation was refused rather than guessing.
    function markAndPoolPrice(address asset, address pool) external view returns (uint256 mark, uint256 poolPrice) {
        PolAsset storage a = _polAssets[asset];
        if (!a.registered) revert TokenNotPolAsset(asset);
        mark = (_readFeed(a.feed, a.maxFeedAge) * (10 ** quoteDecimals)) / (10 ** a.feedDecimals);
        poolPrice = _poolQuotePerAsset(pool, asset, a.tokenDecimals);
    }

    /* ------------------------------------------------------------------ */
    /*                             POSITIONS                                */
    /* ------------------------------------------------------------------ */

    /// @notice Open a new Slipstream position. Manager or multisig.
    /// @dev H-02. The caller chooses the range and the size. It does not choose the tokens,
    ///      the pool, the pool's price, or where the NFT lands. `sqrtPriceX96` is forced to
    ///      zero because that field exists only to CREATE and initialise a pool, and this
    ///      function may only add liquidity to one that already exists and already prices
    ///      correctly.
    function mintPosition(INonfungiblePositionManager.MintParams calldata params)
        external
        onlyManager
        nonReentrant
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        address asset = _requireQuotePaired(params.token0, params.token1);
        address pool = _requireCanonicalPool(params.token0, params.token1, params.tickSpacing);
        _requirePoolOnMark(pool, asset);
        _requireStatedMins(params.amount0Min, params.amount1Min);

        IERC20(params.token0).forceApprove(address(positionManager), params.amount0Desired);
        IERC20(params.token1).forceApprove(address(positionManager), params.amount1Desired);

        INonfungiblePositionManager.MintParams memory p = params;
        p.recipient = address(this); // never mint to anywhere but here
        p.sqrtPriceX96 = 0; // never create a pool, only join one that exists

        (tokenId, liquidity, amount0, amount1) = positionManager.mint(p);

        IERC20(params.token0).forceApprove(address(positionManager), 0);
        IERC20(params.token1).forceApprove(address(positionManager), 0);

        _register(tokenId);
        emit PositionMinted(tokenId, liquidity, amount0, amount1);
    }

    /// @notice Add to an existing position. Manager or multisig.
    /// @dev The pair is read from the position rather than taken from the caller, so the
    ///      approvals granted here are always for the tokens that position actually holds.
    ///      A caller-supplied pair let a manager approve one token while topping up a
    ///      position in another; there was no legitimate use for the freedom.
    function increaseLiquidity(
        uint256 tokenId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external onlyManager nonReentrant returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (!holdsPosition[tokenId]) revert UnknownPosition(tokenId);

        (address pool, address token0, address token1) = _positionPool(tokenId);
        _requirePoolOnMark(pool, _requireQuotePaired(token0, token1));
        _requireStatedMins(amount0Min, amount1Min);

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
    ///
    ///      H-02(d). An exit is the mirror of an entry and was previously the softer of the
    ///      two: `amountMin = 0` let a position be unwound at whatever price the pool happened
    ///      to be showing. The Chainlink band is the real bound here — a manipulated pool is
    ///      refused outright — and blank minimums are refused on top of it, because an
    ///      operator who has not said what they expect is not in a position to notice they
    ///      did not get it. A single-sided exit is normal for an out-of-range position, so
    ///      only one of the two must be stated.
    function decreaseLiquidity(uint256 tokenId, uint128 liquidity, uint256 amount0Min, uint256 amount1Min)
        external
        onlyManager
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (!holdsPosition[tokenId]) revert UnknownPosition(tokenId);
        _requireStatedMins(amount0Min, amount1Min);

        (address pool, address token0, address token1) = _positionPool(tokenId);
        _requirePoolOnMark(pool, _requireQuotePaired(token0, token1));

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
    ///      broken or frozen pair cannot stop the others from paying out. The list it walks
    ///      is bounded by construction — see `onERC721Received` and `prunePosition` (M-03).
    function collectAllFees() external returns (uint256 collected) {
        uint256 len = positionIds.length;
        for (uint256 i; i < len; ++i) {
            try this.collectFees(positionIds[i]) returns (uint256, uint256) {
                ++collected;
            } catch {}
        }
    }

    /* ------------------------------------------------------------------ */
    /*                       POSITION BOOKKEEPING                           */
    /* ------------------------------------------------------------------ */

    /// @notice Track a position that arrived without being minted here. Multisig only.
    /// @dev M-03. Auto-registration on receipt now covers only positions minted TO this
    ///      contract, so a deliberate transfer in — a migration, a top-up from the multisig —
    ///      is registered here instead. Owner-gated, because the cost of a junk entry is paid
    ///      by `collectAllFees` forever.
    function registerPosition(uint256 tokenId) external onlyOwner {
        if (positionManager.ownerOf(tokenId) != address(this)) revert UnknownPosition(tokenId);
        _register(tokenId);
        emit PositionRegistered(tokenId);
    }

    /// @notice Forget a position this treasury no longer holds. Manager or multisig.
    /// @dev M-03, the other half. `positionIds` was append-only, so anything that ever landed
    ///      here was walked by `collectAllFees` forever — a griefer could donate dust
    ///      positions until the sweep ran out of gas. Removal is permitted only for a token
    ///      this contract genuinely no longer owns and has not staked, so it can never be
    ///      used to hide a live position from the fee sweep.
    function prunePosition(uint256 tokenId) external onlyManager {
        if (!holdsPosition[tokenId]) revert UnknownPosition(tokenId);
        if (stakedIn[tokenId] != address(0)) revert PositionStillHeld(tokenId);
        if (positionManager.ownerOf(tokenId) == address(this)) revert PositionStillHeld(tokenId);

        holdsPosition[tokenId] = false;
        uint256 len = positionIds.length;
        for (uint256 i; i < len; ++i) {
            if (positionIds[i] == tokenId) {
                positionIds[i] = positionIds[len - 1];
                positionIds.pop();
                break;
            }
        }
        emit PositionPruned(tokenId);
    }

    /* ------------------------------------------------------------------ */
    /*                          GAUGE STAKING                               */
    /* ------------------------------------------------------------------ */

    /// @notice Stake a position in its Aerodrome gauge to earn AERO. Manager or multisig.
    /// @dev H-01. `stakePosition` grants the gauge an ERC-721 approval and then calls into
    ///      it, so an arbitrary gauge address was an arbitrary `transferFrom` of the position
    ///      — a one-call theft by anyone holding the manager key. The gauge must now be the
    ///      one Aerodrome's voter names for the pool this position is actually in, and the
    ///      pool is derived from `positions(tokenId)` rather than supplied.
    ///
    ///      The approval is also checked out again: after `deposit` the gauge must own the
    ///      position. A canonical gauge always takes custody, so this both asserts the stake
    ///      happened and guarantees no live approval is left behind — the ERC-721 transfer
    ///      clears it.
    function stakePosition(uint256 tokenId, address gauge) external onlyManager nonReentrant {
        if (!holdsPosition[tokenId]) revert UnknownPosition(tokenId);
        _requireCanonicalGauge(tokenId, gauge);

        stakedIn[tokenId] = gauge;
        IERC721Approve(address(positionManager)).approve(gauge, tokenId);
        ISlipstreamGauge(gauge).deposit(tokenId);

        if (positionManager.ownerOf(tokenId) != gauge) revert GaugeDidNotCustody(gauge);
        emit PositionStaked(tokenId, gauge);
    }

    /// @notice Withdraw a staked position back to this contract. Manager or multisig.
    /// @dev Withdrawal goes to the gauge we actually deposited into, recorded at stake time.
    ///      Nothing else is a legitimate counterparty, and remembering is stricter than
    ///      re-deriving: it holds even if the voter's answer for that pool changes later.
    function unstakePosition(uint256 tokenId, address gauge) external onlyManager nonReentrant {
        if (!holdsPosition[tokenId]) revert UnknownPosition(tokenId);
        if (gauge == address(0) || stakedIn[tokenId] != gauge) revert GaugeNotCanonical(gauge);

        delete stakedIn[tokenId];
        ISlipstreamGauge(gauge).withdraw(tokenId);
        emit PositionUnstaked(tokenId, gauge);
    }

    /// @notice Claim AERO for a staked position. Permissionless.
    /// @dev The gauge is the one we staked into, not one the caller names. As an arbitrary
    ///      `getReward(uint256)` against any address, this was a free call primitive pointed
    ///      wherever a caller liked, made from the contract that holds the treasury's assets.
    ///      There is no reason for it to reach anything but our own gauge.
    function claimGaugeRewards(uint256 tokenId) external nonReentrant {
        address gauge = stakedIn[tokenId];
        if (gauge == address(0)) revert UnknownPosition(tokenId);
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
    /// @dev The position manager is named explicitly rather than left to the fact that an
    ///      ERC-721 has no matching `transfer` shape. Relying on the absence of a function
    ///      selector on a third-party contract is a property of THEIR code, not ours, and it
    ///      would stop being true the day the NFPM gained an ERC-20-shaped method.
    function isProtected(address token) public view returns (bool) {
        return token == quoteToken || _polAssets[token].registered || isIncomeToken[token]
            || token == address(positionManager);
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

    /// @notice Accept position NFTs, and remember the ones minted to us.
    /// @dev M-03. Registration is limited to `from == address(0)` — a fresh mint into this
    ///      contract. A transfer in from somebody else is accepted (refusing it would let a
    ///      griefer make our own migrations fail) but not tracked, so donated dust cannot
    ///      grow the list `collectAllFees` walks. A deliberate transfer in is picked up by
    ///      `registerPosition`.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (msg.sender == address(positionManager) && from == address(0)) _register(tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    /* ------------------------------------------------------------------ */
    /*                            INTERNALS                                 */
    /* ------------------------------------------------------------------ */

    function _register(uint256 tokenId) internal {
        if (!holdsPosition[tokenId]) {
            holdsPosition[tokenId] = true;
            positionIds.push(tokenId);
        }
    }

    /// @dev H-02(a). Every POL position is the quote token paired with a registered POL
    ///      asset. Requiring the quote side is stricter than the finding asked for, and
    ///      deliberately so: it is what makes the pool's price checkable against a single
    ///      USD feed, and a POL/POL pair is not something this treasury has any reason to
    ///      hold. Adding an asset is a multisig call; adding a pair shape is a code change.
    function _requireQuotePaired(address token0, address token1) internal view returns (address asset) {
        if (token0 == quoteToken) asset = token1;
        else if (token1 == quoteToken) asset = token0;
        else revert NotQuotePaired();

        if (!_polAssets[asset].registered) revert TokenNotPolAsset(asset);
    }

    /// @dev H-02(b). The pool is whatever the position manager's own factory says it is.
    function _requireCanonicalPool(address token0, address token1, int24 tickSpacing)
        internal
        view
        returns (address pool)
    {
        pool = ISlipstreamFactory(positionFactory).getPool(token0, token1, tickSpacing);
        if (pool == address(0)) revert PoolNotCanonical(pool);
    }

    /// @dev The pool a position lives in, plus its pair. Derived, never supplied.
    function _positionPool(uint256 tokenId) internal view returns (address pool, address token0, address token1) {
        int24 tickSpacing;
        (,, token0, token1, tickSpacing,,,,,,,) = positionManager.positions(tokenId);
        pool = _requireCanonicalPool(token0, token1, tickSpacing);
    }

    /// @dev H-01. A gauge is only a gauge because the voter says so, for the pool this
    ///      position is actually in.
    function _requireCanonicalGauge(uint256 tokenId, address gauge) internal view {
        (address pool,,) = _positionPool(tokenId);
        if (gauge == address(0) || voter.gauges(pool) != gauge) revert GaugeNotCanonical(gauge);
    }

    /// @dev H-02(c). Liquidity moves only while the pool agrees with Chainlink.
    ///
    ///      This is the check that makes the pool derivation meaningful. Deriving the pool
    ///      stops a caller inventing one; the band stops them using a real-but-thin pool for
    ///      the same pair that they have just pushed to an absurd price. Both halves are
    ///      needed — either alone leaves a way to enter or exit at a price the treasury never
    ///      agreed to.
    function _requirePoolOnMark(address pool, address asset) internal view {
        PolAsset storage a = _polAssets[asset];
        uint256 mark = (_readFeed(a.feed, a.maxFeedAge) * (10 ** quoteDecimals)) / (10 ** a.feedDecimals);
        uint256 poolPrice = _poolQuotePerAsset(pool, asset, a.tokenDecimals);

        uint256 tolerance = (mark * a.maxDeviationBps) / BPS;
        uint256 delta = poolPrice > mark ? poolPrice - mark : mark - poolPrice;
        if (delta > tolerance) revert PoolPriceOffMark(poolPrice, mark);
    }

    /// @dev Quote-token units one whole unit of `asset` costs, at the pool's current price.
    ///      `slot0` is read by staticcall and decoded as a single word: Uniswap v3 and
    ///      Slipstream return different tuples and agree only on the first field, which is
    ///      the one we want.
    function _poolQuotePerAsset(address pool, address asset, uint8 assetDecimals) internal view returns (uint256) {
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        if (!ok || ret.length < 32) revert PoolPriceUnavailable(pool);
        // Read the first returned word directly. `abi.decode` would tie us to one tuple
        // arity, and the whole point is that we do not care about the fields after the price.
        uint256 word;
        assembly {
            word := mload(add(ret, 32))
        }
        uint256 sqrtPriceX96 = uint256(uint160(word));
        if (sqrtPriceX96 == 0) revert PoolPriceUnavailable(pool);

        uint256 q96 = 1 << 96;
        // token1 per token0, in raw units, Q96-scaled.
        uint256 priceX96 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, q96);
        uint256 whole = 10 ** assetDecimals;

        // Pools sort by address. If the asset is token0 the pool already quotes it in the
        // quote token; if it is token1 the ratio is the other way up and must be inverted.
        return asset < quoteToken ? Math.mulDiv(priceX96, whole, q96) : Math.mulDiv(whole, q96, priceX96);
    }

    /// @dev H-02(c)/(d). Blank minimums are refused on every liquidity operation.
    ///
    ///      WHAT ACTUALLY BOUNDS EXECUTION IS THE BAND, NOT THIS. It is worth being precise,
    ///      because a check that looks like the protection but is not would be worse than
    ///      none. `_requirePoolOnMark` has already established that the pool agrees with
    ///      Chainlink, and there is no external call between that check and the position
    ///      manager call — the tokens are allowlisted, so nothing in the pair can reenter and
    ///      move the pool in between. Liquidity therefore enters and leaves at a price the
    ///      treasury has verified, and its value is bounded by that.
    ///
    ///      This rule is hygiene on top: an operator who states no expectation cannot notice
    ///      they did not get it. It deliberately does NOT require the minimums to track the
    ///      desired amounts, because in concentrated liquidity `amountDesired` is a maximum
    ///      and a range sitting on one side of the current price legitimately consumes zero
    ///      of the other token. A ratio rule would refuse ordinary range orders, which is why
    ///      only one side must be stated.
    function _requireStatedMins(uint256 min0, uint256 min1) internal pure {
        if (min0 == 0 && min1 == 0) revert SlippageUnbounded();
    }
}

interface IERC721Approve {
    function approve(address to, uint256 tokenId) external;
}
