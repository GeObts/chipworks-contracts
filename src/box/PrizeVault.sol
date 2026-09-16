// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {IPrizeVault} from "../interfaces/IPrizeVault.sol";

/// @title PrizeVault
/// @notice Holds USDC and Coinbase B20 inventory that ChipWorks Box pays out on open.
///
/// @dev UNAUDITED. A new product family: this file shares no storage, no inheritance and
///      no call path with Anvil, ChipRounds, ChipClaims, Pot or POLTreasury. A bug here
///      can lose Box prize inventory; it cannot touch round credits or the Anvil shelf.
///
///      WHAT IT OWES. {Box} is the only caller of {settle}. The draw (tier, USD prize) is
///      decided on Box from the published odds table; this vault only tries to PAY that
///      USD amount in a registered B20, and if it cannot, in USDC. It never pays more
///      tokens than it holds, and a single prize is capped at `maxPrizeBps` of current
///      inventory (USD-equivalent). Empty or thin stocks are skipped in the open, not
///      reverted — Entropy callbacks must not revert.
///
///      NO BLIND OWNER DRAIN. Gifted-stock style "owner withdraws the inventory" is
///      refused. Prize assets (USDC and registered B20) leave through {settle} or through
///      a 48-hour surplus withdraw that still leaves enough inventory to cover outstanding
///      Box EV. Stray tokens that are not prize assets can be rescued immediately.
///
///      FEEDS ARE BEST-EFFORT IN THE CALLBACK. B20 USD feeds hold last close over the
///      weekend (ASSUMPTIONS A-13). A reverting or non-positive feed skips that stock
///      rather than bricking the open.
contract PrizeVault is IPrizeVault, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint32 public constant BPS = 10_000;
    uint256 public constant DECIMALS_PROBE_GAS = 50_000;
    uint256 public constant MAX_STOCKS = 16;
    uint64 public constant CONFIG_TIMELOCK = 48 hours;
    uint64 public constant CONFIG_GRACE = 14 days;
    uint32 public constant MAX_PRIZE_BPS_CEILING = 5_000;
    uint32 public constant SURPLUS_BUFFER_BPS = 11_000;

    /// @notice Quote token prizes can fall back to. USDC on Base, 6 decimals.
    address public immutable override usdc;

    /// @notice Cached USDC decimals. Expected 6; stored so we never assume a literal.
    uint8 public immutable usdcDecimals;

    /// @notice The Box contract allowed to settle. Set once via {setBox}.
    address public override box;

    /// @notice Largest single prize as a fraction of live inventory. 2_500 = 25%.
    uint32 public override maxPrizeBps;

    struct PrizeStock {
        bool registered;
        bool enabled;
        address feed;
        uint8 tokenDecimals;
        uint8 feedDecimals;
    }

    mapping(address token => PrizeStock) internal _stocks;
    address[] internal _stockList;

    struct PendingBps {
        bool queued;
        uint64 executableAt;
        uint32 bps;
    }

    struct PendingSurplus {
        bool queued;
        uint64 executableAt;
        address token;
        address to;
        uint256 amount;
    }

    PendingBps internal _pendingMaxPrizeBps;
    PendingSurplus internal _pendingSurplus;

    event BoxSet(address indexed box);
    event StockAdded(address indexed token, address indexed feed, uint8 tokenDecimals, uint8 feedDecimals);
    event StockEnabled(address indexed token, bool enabled);
    event FeedUpdated(address indexed token, address indexed feed);
    event MaxPrizeBpsQueued(uint32 bps, uint64 executableAt);
    event MaxPrizeBpsExecuted(uint32 previous, uint32 bps);
    event MaxPrizeBpsCancelled();
    event SurplusQueued(address indexed token, address indexed to, uint256 amount, uint64 executableAt);
    event SurplusWithdrawn(address indexed token, address indexed to, uint256 amount);
    event SurplusCancelled();
    event Deposited(address indexed token, address indexed from, uint256 amount);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event StockSkipped(address indexed token, bytes32 indexed reason);
    event PrizePaid(
        address indexed to,
        uint256 requestedUsd,
        uint256 payableUsd,
        uint256 paidUsd,
        address indexed stock,
        uint256 stockAmount,
        uint256 usdcAmount,
        bool capped,
        bool shortfall,
        bool fallbackStock,
        bool usdcFallback
    );

    error ZeroAddress();
    error BadConfig();
    error AlreadyWired();
    error OnlyBox();
    error AlreadyRegistered(address token);
    error NotRegistered(address token);
    error TooManyStocks();
    error DecimalsMismatch(address token, uint8 provided, uint8 actual);
    error ProtectedAsset(address token);
    error InsufficientSurplus(uint256 inventoryUsd, uint256 requiredUsd);
    error NothingQueued();
    error TimelockNotElapsed(uint64 nowTs, uint64 executableAt);
    error TimelockExpired(uint64 nowTs, uint64 expiredAt);
    error TransferFailed();

    /// @param multisig      Owner. Two-step.
    /// @param usdc_         USDC on Base. 6 decimals.
    /// @param maxPrizeBps_  Single-prize cap vs inventory. Launch at 2_500 (25%).
    constructor(address multisig, address usdc_, uint32 maxPrizeBps_) Ownable(multisig) {
        if (multisig == address(0) || usdc_ == address(0)) revert ZeroAddress();
        if (maxPrizeBps_ == 0 || maxPrizeBps_ > MAX_PRIZE_BPS_CEILING) revert BadConfig();
        usdc = usdc_;
        usdcDecimals = IERC20Metadata(usdc_).decimals();
        maxPrizeBps = maxPrizeBps_;
    }

    /* ------------------------------------------------------------------ */
    /*                              WIRING                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Point at the Box. Allowed ONCE, while unset.
    /// @dev Same shape as ChipClaims.setRounds: the first wire is not timelocked because
    ///      at deploy there is nothing to protect. There is no later retarget — a new Box
    ///      is a new vault. That is deliberate: retargeting the settler is a drain.
    function setBox(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        if (box != address(0)) revert AlreadyWired();
        box = v;
        emit BoxSet(v);
    }

    /* ------------------------------------------------------------------ */
    /*                             DEPOSITS                                 */
    /* ------------------------------------------------------------------ */

    /// @notice Permissionless inventory top-up. USDC, CHIP (if sent), or a registered B20.
    function deposit(address token, uint256 amount) external nonReentrant {
        if (token == address(0) || amount == 0) revert BadConfig();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(token, msg.sender, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                              SETTLE                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Pay `to` up to `prizeUsd` (6 decimals) in B20 or USDC.
    /// @dev MUST NOT REVERT on empty inventory, a dead feed, or a failing transfer: Pyth
    ///      Entropy will not retry a reverting callback. Shortfall is emitted, not thrown.
    function settle(address to, uint256 prizeUsd, bytes32 entropy)
        external
        override
        nonReentrant
        returns (Payout memory p)
    {
        if (msg.sender != box) revert OnlyBox();
        p.requestedUsd = prizeUsd;
        if (to == address(0) || prizeUsd == 0) {
            p.shortfall = prizeUsd != 0;
            _emitPaid(to, p);
            return p;
        }

        p.payableUsd = prizeUsd;
        uint256 cap = _prizeCapUsd();
        if (p.payableUsd > cap) {
            p.payableUsd = cap;
            p.capped = true;
        }
        if (p.payableUsd == 0) {
            p.shortfall = true;
            _emitPaid(to, p);
            return p;
        }

        if (_payInStock(to, entropy, p)) {
            _emitPaid(to, p);
            return p;
        }

        _payInUsdc(to, p);
        _emitPaid(to, p);
    }

    function _payInStock(address to, bytes32 entropy, Payout memory p) internal returns (bool) {
        uint256 n = _stockList.length;
        if (n == 0) return false;
        uint256 start = uint256(entropy) % n;
        for (uint256 i; i < n; ++i) {
            address token = _stockList[_wrap(start + i, n)];
            (bool ok, uint256 amount) = _canPayStock(token, p.payableUsd);
            if (!ok) continue;
            if (!_tryTransfer(token, to, amount)) {
                emit StockSkipped(token, bytes32("transfer"));
                continue;
            }
            p.stock = token;
            p.stockAmount = amount;
            p.paidUsd = p.payableUsd;
            p.fallbackStock = i != 0;
            p.shortfall = p.paidUsd < p.requestedUsd;
            return true;
        }
        return false;
    }

    function _payInUsdc(address to, Payout memory p) internal {
        uint256 usdcBal = IERC20(usdc).balanceOf(address(this));
        uint256 need = _usdToUsdc(p.payableUsd);
        uint256 pay = need <= usdcBal ? need : usdcBal;
        if (pay != 0 && _tryTransfer(usdc, to, pay)) {
            p.usdcAmount = pay;
            p.paidUsd = _usdcToUsd(pay);
            p.usdcFallback = true;
        }
        p.shortfall = p.paidUsd < p.requestedUsd;
    }

    function _emitPaid(address to, Payout memory p) internal {
        emit PrizePaid(
            to,
            p.requestedUsd,
            p.payableUsd,
            p.paidUsd,
            p.stock,
            p.stockAmount,
            p.usdcAmount,
            p.capped,
            p.shortfall,
            p.fallbackStock,
            p.usdcFallback
        );
    }

    /* ------------------------------------------------------------------ */
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    function inventoryUsd() public view override returns (uint256 usd) {
        usd = _usdcToUsd(IERC20(usdc).balanceOf(address(this)));
        uint256 n = _stockList.length;
        for (uint256 i; i < n; ++i) {
            address token = _stockList[i];
            PrizeStock memory st = _stocks[token];
            if (!st.enabled) continue;
            uint256 price = _readPrice(st.feed);
            if (price == 0) continue;
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal == 0) continue;
            usd += _tokensToUsd(bal, price, st.tokenDecimals, st.feedDecimals);
        }
    }

    function prizeCapUsd() public view override returns (uint256) {
        return _prizeCapUsd();
    }

    function stockCount() external view override returns (uint256) {
        return _stockList.length;
    }

    function stockAt(uint256 index) external view override returns (address) {
        return _stockList[index];
    }

    function getStock(address token) external view returns (PrizeStock memory) {
        return _stocks[token];
    }

    function quoteTokenAmount(address token, uint256 prizeUsd) external view override returns (uint256) {
        PrizeStock memory st = _stocks[token];
        if (!st.registered) revert NotRegistered(token);
        uint256 price = _readPrice(st.feed);
        if (price == 0) return 0;
        return _usdToTokens(prizeUsd, price, st.tokenDecimals, st.feedDecimals);
    }

    /* ------------------------------------------------------------------ */
    /*                          ADMIN: CATALOG                              */
    /* ------------------------------------------------------------------ */

    /// @notice Register a B20 prize token, keyed by ADDRESS (never by ticker).
    /// @param token          B20 token. Identified only by this address.
    /// @param feed           Chainlink USD aggregator. Weekend staleness is expected.
    /// @param tokenDecimals_ Expected decimals (B20 is 8). Cross-checked when callable.
    function addStock(address token, address feed, uint8 tokenDecimals_) external onlyOwner {
        if (token == address(0) || feed == address(0)) revert ZeroAddress();
        if (token == usdc) revert BadConfig();
        if (_stocks[token].registered) revert AlreadyRegistered(token);
        if (_stockList.length >= MAX_STOCKS) revert TooManyStocks();
        if (tokenDecimals_ == 0 || tokenDecimals_ > 18) revert BadConfig();

        uint8 actual = _checkedDecimals(token);
        if (actual != 0 && actual != tokenDecimals_) {
            revert DecimalsMismatch(token, tokenDecimals_, actual);
        }

        uint8 feedDecimals = IAggregatorV3(feed).decimals();
        if (feedDecimals == 0 || feedDecimals > 18) revert BadConfig();

        _stocks[token] = PrizeStock({
            registered: true, enabled: true, feed: feed, tokenDecimals: tokenDecimals_, feedDecimals: feedDecimals
        });
        _stockList.push(token);
        emit StockAdded(token, feed, tokenDecimals_, feedDecimals);
        emit StockEnabled(token, true);
    }

    function setStockEnabled(address token, bool enabled) external onlyOwner {
        PrizeStock storage st = _stocks[token];
        if (!st.registered) revert NotRegistered(token);
        st.enabled = enabled;
        emit StockEnabled(token, enabled);
    }

    function setFeed(address token, address feed) external onlyOwner {
        if (feed == address(0)) revert ZeroAddress();
        PrizeStock storage st = _stocks[token];
        if (!st.registered) revert NotRegistered(token);
        uint8 feedDecimals = IAggregatorV3(feed).decimals();
        if (feedDecimals == 0 || feedDecimals > 18) revert BadConfig();
        st.feed = feed;
        st.feedDecimals = feedDecimals;
        emit FeedUpdated(token, feed);
    }

    /// @notice Lowering the prize cap is immediate (safety). Raising it is timelocked.
    function setMaxPrizeBps(uint32 bps) external onlyOwner {
        if (bps == 0 || bps > MAX_PRIZE_BPS_CEILING) revert BadConfig();
        if (bps >= maxPrizeBps) revert BadConfig();
        emit MaxPrizeBpsExecuted(maxPrizeBps, bps);
        maxPrizeBps = bps;
    }

    function queueMaxPrizeBps(uint32 bps) external onlyOwner {
        if (bps == 0 || bps > MAX_PRIZE_BPS_CEILING) revert BadConfig();
        uint64 executableAt = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingMaxPrizeBps = PendingBps({queued: true, executableAt: executableAt, bps: bps});
        emit MaxPrizeBpsQueued(bps, executableAt);
    }

    function executeMaxPrizeBps() external onlyOwner {
        PendingBps memory p = _pendingMaxPrizeBps;
        if (!p.queued) revert NothingQueued();
        _requireInWindow(p.executableAt);
        emit MaxPrizeBpsExecuted(maxPrizeBps, p.bps);
        maxPrizeBps = p.bps;
        delete _pendingMaxPrizeBps;
    }

    function cancelMaxPrizeBps() external onlyOwner {
        if (!_pendingMaxPrizeBps.queued) revert NothingQueued();
        delete _pendingMaxPrizeBps;
        emit MaxPrizeBpsCancelled();
    }

    /* ------------------------------------------------------------------ */
    /*                     ADMIN: SURPLUS / RESCUE                          */
    /* ------------------------------------------------------------------ */

    /// @notice Queue a withdraw of prize assets. 48h notice. Execution still checks that
    ///         remaining inventory covers outstanding Box EV with a 10% buffer.
    /// @dev This is the lever that Gifted-style vaults usually make instant and unbounded.
    ///      It is neither. `{Box.outstandingLiabilityUsd}` is the floor.
    function queueSurplusWithdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0) || token == address(0) || amount == 0) revert BadConfig();
        if (token != usdc && !_stocks[token].registered) revert NotRegistered(token);
        uint64 executableAt = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingSurplus =
            PendingSurplus({queued: true, executableAt: executableAt, token: token, to: to, amount: amount});
        emit SurplusQueued(token, to, amount, executableAt);
    }

    function executeSurplusWithdraw() external onlyOwner nonReentrant {
        PendingSurplus memory p = _pendingSurplus;
        if (!p.queued) revert NothingQueued();
        _requireInWindow(p.executableAt);
        delete _pendingSurplus;

        uint256 required = _requiredInventoryUsd();
        IERC20(p.token).safeTransfer(p.to, p.amount);
        uint256 left = inventoryUsd();
        if (left < required) revert InsufficientSurplus(left, required);
        emit SurplusWithdrawn(p.token, p.to, p.amount);
    }

    function cancelSurplusWithdraw() external onlyOwner {
        if (!_pendingSurplus.queued) revert NothingQueued();
        delete _pendingSurplus;
        emit SurplusCancelled();
    }

    /// @notice Rescue a token that is NOT USDC and NOT a registered prize stock.
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0) || token == address(0)) revert ZeroAddress();
        if (token == usdc || _stocks[token].registered) revert ProtectedAsset(token);
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                              INTERNAL                                */
    /* ------------------------------------------------------------------ */

    function _prizeCapUsd() internal view returns (uint256) {
        return inventoryUsd() * maxPrizeBps / BPS;
    }

    function _requiredInventoryUsd() internal view returns (uint256) {
        address box_ = box;
        if (box_ == address(0)) return 0;
        (bool ok, bytes memory ret) = box_.staticcall(abi.encodeWithSignature("outstandingLiabilityUsd()"));
        if (!ok || ret.length < 32) return 0;
        uint256 liability = abi.decode(ret, (uint256));
        return liability * SURPLUS_BUFFER_BPS / BPS;
    }

    function _canPayStock(address token, uint256 prizeUsd) internal returns (bool ok, uint256 amount) {
        PrizeStock memory st = _stocks[token];
        if (!st.enabled) {
            emit StockSkipped(token, bytes32("disabled"));
            return (false, 0);
        }
        uint256 price = _readPrice(st.feed);
        if (price == 0) {
            emit StockSkipped(token, bytes32("feed"));
            return (false, 0);
        }
        amount = _usdToTokens(prizeUsd, price, st.tokenDecimals, st.feedDecimals);
        if (amount == 0) {
            emit StockSkipped(token, bytes32("dust"));
            return (false, 0);
        }
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) {
            emit StockSkipped(token, bytes32("empty"));
            return (false, 0);
        }
        if (amount > bal) {
            emit StockSkipped(token, bytes32("thin"));
            return (false, 0);
        }
        return (true, amount);
    }

    function _readPrice(address feed) internal view returns (uint256) {
        try IAggregatorV3(feed).latestRoundData() returns (uint80, int256 answer, uint256, uint256, uint80) {
            if (answer <= 0) return 0;
            return uint256(answer);
        } catch {
            return 0;
        }
    }

    function _usdToTokens(uint256 prizeUsd, uint256 price, uint8 tokenDecimals, uint8 feedDecimals)
        internal
        view
        returns (uint256)
    {
        uint256 usdScale = 10 ** uint256(usdcDecimals);
        uint256 tokenScale = 10 ** uint256(tokenDecimals);
        uint256 feedScale = 10 ** uint256(feedDecimals);
        return Math.mulDiv(prizeUsd, tokenScale * feedScale, price * usdScale);
    }

    function _tokensToUsd(uint256 amount, uint256 price, uint8 tokenDecimals, uint8 feedDecimals)
        internal
        view
        returns (uint256)
    {
        uint256 usdScale = 10 ** uint256(usdcDecimals);
        uint256 tokenScale = 10 ** uint256(tokenDecimals);
        uint256 feedScale = 10 ** uint256(feedDecimals);
        return Math.mulDiv(amount, price * usdScale, tokenScale * feedScale);
    }

    function _usdcToUsd(uint256 amount) internal view returns (uint256) {
        uint8 d = usdcDecimals;
        if (d == 6) return amount;
        if (d > 6) return amount / (10 ** uint256(d - 6));
        return amount * (10 ** uint256(6 - d));
    }

    function _usdToUsdc(uint256 usd) internal view returns (uint256) {
        uint8 d = usdcDecimals;
        if (d == 6) return usd;
        if (d > 6) return usd * (10 ** uint256(d - 6));
        return usd / (10 ** uint256(6 - d));
    }

    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool) {
        try this.extTransfer(token, to, amount) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice External wrapper so {settle} can try/catch a SafeERC20 transfer.
    function extTransfer(address token, address to, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlyBox();
        IERC20(token).safeTransfer(to, amount);
    }

    function _checkedDecimals(address token) internal view returns (uint8) {
        (bool ok, bytes memory ret) = token.staticcall{gas: DECIMALS_PROBE_GAS}(abi.encodeWithSignature("decimals()"));
        if (!ok || ret.length < 32) return 0;
        uint256 d = abi.decode(ret, (uint256));
        if (d == 0 || d > 18) return 0;
        return uint8(d);
    }

    function _wrap(uint256 i, uint256 n) internal pure returns (uint256) {
        return i < n ? i : i - n;
    }

    function _requireInWindow(uint64 executableAt) internal view {
        if (block.timestamp < executableAt) revert TimelockNotElapsed(uint64(block.timestamp), executableAt);
        uint64 expiresAt = executableAt + CONFIG_GRACE;
        if (block.timestamp > expiresAt) revert TimelockExpired(uint64(block.timestamp), expiresAt);
    }
}
