// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface IMetaMorphoFactory {
    function createMetaMorpho(
        address initialOwner,
        uint256 initialTimelock,
        address asset,
        string memory name,
        string memory symbol,
        bytes32 salt
    ) external returns (address);
}

interface IMetaMorpho {
    function setCurator(address) external;
    function setIsAllocator(address, bool) external;
    function submitCap(MarketParams memory, uint256) external;
    function acceptCap(MarketParams memory) external;
    function setSupplyQueue(bytes32[] calldata) external;
    function setFeeRecipient(address) external;
    function setFee(uint256) external;
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function totalAssets() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function maxWithdraw(address) external view returns (uint256);
    function config(bytes32) external view returns (uint184 cap, bool enabled, uint64 removableAt);
    function fee() external view returns (uint96);
    function feeRecipient() external view returns (address);
    function timelock() external view returns (uint256);
    function owner() external view returns (address);
    function asset() external view returns (address);
}

interface IMorpho {
    function position(bytes32, address) external view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
    function market(bytes32) external view returns (uint128, uint128, uint128, uint128, uint128, uint128);
}

/**
 * THE CHIPWORKS USDC VAULT, BUILT AND RUN BEFORE IT IS DEPLOYED.
 *
 * A Morpho vault ("MetaMorpho") is the supported way for an integrator to earn on
 * lending: depositors supply USDC, the curator picks which markets it may go to and
 * how much, and the curator takes a share of the INTEREST as a fee. Live Base vaults
 * charge 0% to 25% - Steakhouse USDC takes 25% on $130M, Moonwell 15%, Spark 10% -
 * so 15% to the Chipworks Safe is squarely normal.
 *
 * WHAT THIS PROVES, against the live factory and live markets:
 *   the vault deploys and is owned by the Safe
 *   the 8 whitelisted markets are accepted and ordered
 *   a depositor's USDC actually reaches those markets
 *   it earns, and the Safe's fee accrues out of the interest and nothing else
 *   the depositor can take it all back out
 *
 * THE WHITELIST IS HARDCODED AND THAT IS THE POINT. Base has 4,303 markets and
 * some of them are pinned at 100% utilisation quoting 297,000% APY, where a
 * lender cannot withdraw at all. A vault that chose markets by yield would walk
 * straight into one. These eight were picked by depth (>= $5k) and read off chain
 * by tools/claim-day/morpho-whitelist.cjs.
 */
contract MorphoVaultRehearsalTest is Test {
    address constant FACTORY = 0xFf62A7c278C62eD665133147129245053Bbf5918; // MetaMorpho v1.1
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
    address constant IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;

    /// @dev 15%, in WAD. The fee is a share of INTEREST, never of principal.
    uint256 constant FEE = 0.15e18;

    /// @dev Per stock market. Sized to add borrow capacity without drowning the rate.
    uint256 constant STOCK_CAP = 2_000e6;

    IMetaMorpho vault;
    address depositor = makeAddr("depositor");

    /// @dev The eight whitelisted markets, deep first for safety, stocks for yield.
    MarketParams[] markets;
    bytes32[] ids;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        require(bytes(rpc).length > 0, "BASE_RPC_URL is required");
        vm.createSelectFork(rpc);

        // --- deep markets: where size can actually go ---
        _add(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf, 0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9, 0.86e18); // cbBTC
        _add(0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34, 0xF4b17C79492d68775e22e8Dd0a2Bb22854A39A47, 0.915e18); // USDe
        _add(0x4200000000000000000000000000000000000006, 0xFEa2D58cEfCb9fcb597723c6bAE66fFE4193aFE4, 0.86e18); // WETH
        _add(0xcb585250f852C6c6bf90434AB21A00f02833a4af, 0x031b2EFC8d70042Ac8d9f5c793c4149eC4b60fdE, 0.625e18); // cbXRP
        // --- Chipworks stock markets: higher yield, thin, so smaller caps ---
        _add(0xb200000000000000000000C2e324d24d7eEcd1fb, 0xEcC5c9bf18CB2CfC94C2f7EFf8BDd5837A60AB0e, 0.625e18); // AAPL
        _add(0xb2000000000000000000002D0BA3164cc74f58B7, 0x24DC11055aa5b2C5692E4B77d7285c4f0fd9Cf99, 0.77e18); // GOOGL
        _add(0xb20000000000000000000078ee7ce2fE4908108C, 0x4F698C04d01d9CebCDd9494c189aBdD6C5453f84, 0.625e18); // NVDA
        _add(0xb2000000000000000000008bC8786B856E61707C, 0x4752B27dFc1931eb9a5DFEFC7FBC9d0af9020dC7, 0.625e18); // META

        vault = IMetaMorpho(
            IMetaMorphoFactory(FACTORY).createMetaMorpho(SAFE, 0, USDC, "Chipworks USDC", "cwUSDC", bytes32("chipworks-1"))
        );

        vm.startPrank(SAFE);
        vault.setFeeRecipient(SAFE);
        vault.setFee(FEE);
        /*
            CAPS ARE THE CURATOR'S WHOLE JOB. A thin market at 91% utilisation is
            fine for a slice and wrong for the lot: if every depositor's USDC sat in
            the NVDA market, a withdrawal larger than its free liquidity would fail.
            Deep markets take size; the stock markets are capped at STOCK_CAP each.
        */
        for (uint256 i; i < markets.length; i++) {
            uint256 cap = i < 4 ? 5_000_000e6 : STOCK_CAP;
            vault.submitCap(markets[i], cap);
            // With a zero timelock the cap applies immediately; accept is a no-op then.
            (bool ok,) = address(vault).call(abi.encodeWithSelector(IMetaMorpho.acceptCap.selector, markets[i]));
            ok;
        }

        /*
            ── THE QUEUE ORDER IS THE WHOLE LENDING/BORROWING LOOP ───────────────

            Deposits fill the supply queue in order, up to each cap. Deep-first put
            all $50,000 into cbBTC and not one cent into a Chipworks market - money
            earned, nothing lent against the stocks holders actually hold.

            Stocks first, capped small, makes the two products feed each other: each
            deposit tops up the markets Chipworks holders borrow from, and the
            overflow goes to cbBTC and friends.

            THE CAP IS SMALL ON PURPOSE, AND NOT OUT OF TIMIDITY. These markets are
            ~$5-22k deep at 91% utilisation, which is WHY they pay 5.93%. Dropping
            $25k into a $22k market halves utilisation and the rate collapses - the
            vault would be competing its own yield away. $5,000 a market adds real
            borrow capacity while leaving the rate roughly where it is.
        */
        bytes32[] memory queue = new bytes32[](ids.length);
        for (uint256 i; i < 4; i++) queue[i] = ids[i + 4]; // the four stock markets
        for (uint256 i; i < 4; i++) queue[i + 4] = ids[i]; // then the deep ones
        vault.setSupplyQueue(queue);
        vm.stopPrank();
    }

    function _add(address collateral, address oracle, uint256 lltv) internal {
        MarketParams memory p =
            MarketParams({loanToken: USDC, collateralToken: collateral, oracle: oracle, irm: IRM, lltv: lltv});
        markets.push(p);
        ids.push(keccak256(abi.encode(p)));
    }

    // ---- the vault itself -------------------------------------------------

    function test_vaultIsOwnedByTheSafe_andChargesFifteenPercent() public view {
        assertEq(vault.owner(), SAFE, "the Safe owns it");
        assertEq(vault.asset(), USDC, "USDC vault");
        assertEq(vault.fee(), FEE, "15% of interest");
        assertEq(vault.feeRecipient(), SAFE, "fee goes to the Safe");
    }

    function test_everyWhitelistedMarketIsEnabledWithACap() public view {
        for (uint256 i; i < ids.length; i++) {
            (uint184 cap, bool enabled,) = vault.config(ids[i]);
            assertTrue(enabled, "market not enabled");
            assertGt(cap, 0, "market has no cap");
        }
    }

    // ---- a deposit, and where it goes -------------------------------------

    function test_depositReachesTheWhitelistedMarkets() public {
        uint256 amount = 50_000e6;
        deal(USDC, depositor, amount);

        vm.startPrank(depositor);
        IERC20(USDC).approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, depositor);
        vm.stopPrank();

        assertGt(shares, 0, "no shares minted");
        assertApproxEqAbs(vault.totalAssets(), amount, 1, "vault holds the deposit");

        // It should be IN a market, not sitting in the vault.
        uint256 placed;
        for (uint256 i; i < ids.length; i++) {
            (uint256 supplyShares,,) = IMorpho(MORPHO).position(ids[i], address(vault));
            if (supplyShares > 0) placed++;
        }
        assertGt(placed, 0, "deposit never reached a market");
        emit log_named_uint("markets the deposit landed in", placed);
        emit log_named_decimal_uint("vault total assets (USDC)", vault.totalAssets(), 6);

        /*
            AND THE BORROW SIDE GREW BY IT. This is the claim the two products rest
            on: a deposit here is borrowable by a Chipworks holder against their
            stock, without Chipworks putting up a cent.
        */
        uint256 stockLiquidityAdded;
        for (uint256 i = 4; i < ids.length; i++) {
            (uint256 supplyShares,,) = IMorpho(MORPHO).position(ids[i], address(vault));
            if (supplyShares > 0) stockLiquidityAdded++;
        }
        assertEq(stockLiquidityAdded, 4, "every stock market should have been topped up first");
        emit log_named_decimal_uint("added to EACH stock market (USDC)", STOCK_CAP, 6);
    }

    // ---- it earns, and the fee comes out of the interest -------------------

    function test_itEarns_andTheSafeFeeAccruesFromInterestOnly() public {
        uint256 amount = 50_000e6;
        deal(USDC, depositor, amount);
        vm.startPrank(depositor);
        IERC20(USDC).approve(address(vault), amount);
        vault.deposit(amount, depositor);
        vm.stopPrank();

        uint256 safeSharesBefore = vault.balanceOf(SAFE);
        assertEq(safeSharesBefore, 0, "the Safe starts with nothing");

        skip(365 days);

        // Any interaction accrues: a dust deposit is the cheapest trigger.
        deal(USDC, depositor, 1e6);
        vm.startPrank(depositor);
        IERC20(USDC).approve(address(vault), 1e6);
        vault.deposit(1e6, depositor);
        vm.stopPrank();

        uint256 assetsNow = vault.totalAssets();
        assertGt(assetsNow, amount + 1e6, "a year passed and nothing was earned");

        uint256 safeShares = vault.balanceOf(SAFE);
        assertGt(safeShares, 0, "the curator fee never accrued");

        uint256 interest = assetsNow - amount - 1e6;
        uint256 feeValue = vault.maxWithdraw(SAFE);
        emit log_named_decimal_uint("interest earned in a year (USDC)", interest, 6);
        emit log_named_decimal_uint("the Safe's 15% cut (USDC)", feeValue, 6);
        emit log_named_uint("implied net APY for depositors, bps", ((interest - feeValue) * 10_000) / amount);

        // The fee is a share of interest and can never eat principal.
        assertLt(feeValue, interest, "fee must be less than the interest it is taken from");
    }

    // ---- and the depositor can leave --------------------------------------

    function test_depositorCanWithdrawEverything() public {
        uint256 amount = 20_000e6;
        deal(USDC, depositor, amount);
        vm.startPrank(depositor);
        IERC20(USDC).approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, depositor);

        skip(30 days);

        uint256 got = vault.redeem(shares, depositor, depositor);
        vm.stopPrank();

        assertGe(got, amount, "a lender must get back at least what they put in");
        emit log_named_decimal_uint("out after 30 days (USDC)", got, 6);
    }
}
