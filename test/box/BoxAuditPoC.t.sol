// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Box} from "../../src/box/Box.sol";
import {PrizeVault} from "../../src/box/PrizeVault.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {IEntropyV2} from "../../src/interfaces/IEntropyV2.sol";
import {IPrizeVault} from "../../src/interfaces/IPrizeVault.sol";
import {BoxTestBase} from "./BoxTestBase.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice PoC suite for Box audit Highs H-01–H-05 and Medium M-08.
/// @dev UNAUDITED. Isolated from Anvil. No mainnet broadcast.
contract BoxAuditPoCTest is BoxTestBase {
    event BoxOpened(
        address indexed opener,
        uint256 indexed tokenId,
        uint64 indexed sequence,
        uint8 skuId,
        uint8 tierId,
        uint32 prizeBps,
        uint256 prizeUsd,
        address stock,
        uint256 stockAmount,
        uint256 usdcAmount,
        uint256 paidUsd,
        bool capped,
        bool shortfall,
        bool emptyStockFallback
    );
    event SettleFailed(address indexed opener, uint256 indexed tokenId, uint64 indexed sequence, uint256 prizeUsd);

    /* ------------------------------------------------------------------ */
    /*  H-04  open reverts if vault.box unset; failed settle does not burn  */
    /* ------------------------------------------------------------------ */

    function test_H04_OpenRevertsIfVaultBoxUnset_NoSilentBurn() public {
        PrizeVault unwired = new PrizeVault(multisig, address(usdc), address(chip), 2_500);
        Box b = _newBox(address(unwired), address(chip), CHIP1, CHIP10, CHIP25);
        assertEq(unwired.box(), address(0));

        vm.startPrank(alice);
        usdc.approve(address(b), type(uint256).max);
        uint256 id = b.buyWithUsdc(SKU1, alice);
        vm.stopPrank();
        assertEq(b.ownerOf(id), alice);
        assertEq(b.boxInfo(id).state, b.STATE_SEALED());

        uint128 fee = b.quoteOpenFee();
        vm.prank(alice);
        vm.expectRevert(Box.VaultNotWired.selector);
        b.open{value: fee}(id);

        assertEq(b.ownerOf(id), alice, "open revert: ownerOf unchanged");
        assertEq(b.sealedSupply(SKU1), 1);

        // Failed settle after a wired-but-reverting vault: callback must not silently burn.
        SettleReverter hostile = new SettleReverter();
        Box b2 = _newBox(address(hostile), address(chip), CHIP1, CHIP10, CHIP25);
        hostile.setBox(address(b2));
        vm.startPrank(alice);
        usdc.approve(address(b2), type(uint256).max);
        uint256 id2 = b2.buyWithUsdc(SKU1, alice);
        uint128 fee2 = b2.quoteOpenFee();
        b2.open{value: fee2}(id2);
        vm.stopPrank();
        uint64 seq = b2.boxInfo(id2).sequence;

        vm.expectEmit(true, true, true, true);
        emit SettleFailed(alice, id2, seq, 200_000); // roll 0 → dust 0.20× of $1
        entropy.fulfill(seq, bytes32(uint256(0)));

        assertEq(b2.ownerOf(id2), alice, "failed settle: ownerOf unchanged");
        assertEq(b2.boxInfo(id2).state, b2.STATE_OPENING());
        assertEq(b2.sealedSupply(SKU1), 1);
    }

    /* ------------------------------------------------------------------ */
    /*  H-03  failed liability cannot zero surplus; cannot retire sealed SKU */
    /* ------------------------------------------------------------------ */

    function test_H03_FailedLiabilityCannotZeroSurplusRequirement() public {
        uint256 id = _buy1(alice);
        vm.prank(multisig);
        boxes.queueSku(SKU1, false, 0, 0);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(Box.SealedSupplyOutstanding.selector, SKU1));
        boxes.executeSku();
        assertEq(boxes.ownerOf(id), alice);
        assertEq(boxes.sealedSupply(SKU1), 1);
        assertGt(boxes.outstandingLiabilityUsd(), 0);

        PrizeVault v = new PrizeVault(multisig, address(usdc), address(chip), 2_500);
        LiabilityReverter hostile = new LiabilityReverter();
        vm.prank(multisig);
        v.setBox(address(hostile));
        usdc.mint(address(v), 100 * 1e6);
        uint256 usdc0 = usdc.balanceOf(address(v));

        vm.prank(multisig);
        v.queueSurplusWithdraw(address(usdc), alice, 50 * 1e6);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        vm.expectRevert(bytes("liability down"));
        v.executeSurplusWithdraw();
        assertEq(usdc.balanceOf(address(v)), usdc0, "USDC unchanged when liability query fails");
    }

    /* ------------------------------------------------------------------ */
    /*  H-02  fake stock feed cannot bypass surplus floor                   */
    /* ------------------------------------------------------------------ */

    function test_H02_FakeStockFeedCannotBypassSurplusFloor() public {
        _buy1(alice);
        uint256 required = boxes.outstandingLiabilityUsd() * 11_000 / 10_000;
        assertGt(required, 0);

        MockERC20 fake = new MockERC20("Fake", "FAKE", 8);
        // $1e9 / token — enough MTM to look like it covers any USDC drain.
        MockAggregatorV3 fakeFeed = new MockAggregatorV3(8, int256(1_000_000_000e8), "FAKE");
        vm.prank(multisig);
        vault.addStock(address(fake), address(fakeFeed), 8);
        fake.mint(address(this), 1e8);
        fake.approve(address(vault), 1e8);
        vault.deposit(address(fake), 1e8);
        assertGt(vault.inventoryUsd(), 1_000_000_000 * 1e6);

        uint256 usdc0 = usdc.balanceOf(address(vault));
        vm.prank(multisig);
        vault.queueSurplusWithdraw(address(usdc), alice, usdc0);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.InsufficientSurplus.selector, 0, required));
        vault.executeSurplusWithdraw();

        assertEq(usdc.balanceOf(address(vault)), usdc0, "USDC unchanged");
    }

    /* ------------------------------------------------------------------ */
    /*  H-01  rescue / addStock / surplus cannot drain CHIP working capital */
    /* ------------------------------------------------------------------ */

    function test_H01_RescueCannotDrainChipWorkingCapital() public {
        vm.prank(alice);
        boxes.buyWithChip(SKU1, alice);
        uint256 chip0 = chip.balanceOf(address(vault));
        assertGt(chip0, 0);

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, address(chip)));
        vault.rescue(address(chip), alice, chip0);
        assertEq(chip.balanceOf(address(vault)), chip0, "CHIP balance unchanged");

        // Constructor CHIP=0, Box later wired with CHIP: still protected via Box.chip().
        PrizeVault v0 = new PrizeVault(multisig, address(usdc), address(0), 2_500);
        Box b = _newBox(address(v0), address(chip), CHIP1, CHIP10, CHIP25);
        vm.prank(multisig);
        v0.setBox(address(b));
        chip.mint(address(v0), 7 ether);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, address(chip)));
        v0.rescue(address(chip), alice, 7 ether);
        assertEq(chip.balanceOf(address(v0)), 7 ether);
    }

    function test_H01_AddStockChipForbidden() public {
        MockAggregatorV3 chipFeed = new MockAggregatorV3(8, int256(1e8), "CHIP");
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, address(chip)));
        vault.addStock(address(chip), address(chipFeed), 18);
        assertEq(vault.stockCount(), 2, "CHIP never entered the prize catalog");

        // Live Base CHIP address is always refused, even on a vault constructed with chip=0.
        PrizeVault v0 = new PrizeVault(multisig, address(usdc), address(0), 2_500);
        address liveChip = v0.DEFAULT_CHIP();
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, liveChip));
        v0.addStock(liveChip, address(chipFeed), 18);
        assertEq(v0.stockCount(), 0);
    }

    function test_H01_SurplusWithdrawChipForbidden() public {
        vm.prank(alice);
        boxes.buyWithChip(SKU25, alice);
        uint256 chip0 = chip.balanceOf(address(vault));
        assertGt(chip0, 0);

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, address(chip)));
        vault.queueSurplusWithdraw(address(chip), alice, chip0);
        assertEq(chip.balanceOf(address(vault)), chip0, "CHIP not queued as surplus");

        // Constructor CHIP=0 + Box.chip() after wire: surplus still refuses CHIP.
        PrizeVault v0 = new PrizeVault(multisig, address(usdc), address(0), 2_500);
        Box b = _newBox(address(v0), address(chip), CHIP1, CHIP10, CHIP25);
        vm.prank(multisig);
        v0.setBox(address(b));
        chip.mint(address(v0), 11 ether);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, address(chip)));
        v0.queueSurplusWithdraw(address(chip), alice, 11 ether);
        assertEq(chip.balanceOf(address(v0)), 11 ether);
    }

    function test_H01_CannotRegisterChipThenWireBox() public {
        PrizeVault v0 = new PrizeVault(multisig, address(usdc), address(0), 2_500);
        MockAggregatorV3 chipFeed = new MockAggregatorV3(8, int256(1e8), "CHIP");
        vm.prank(multisig);
        v0.addStock(address(chip), address(chipFeed), 18);
        assertEq(v0.stockCount(), 1);

        Box b = _newBox(address(v0), address(chip), CHIP1, CHIP10, CHIP25);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, address(chip)));
        v0.setBox(address(b));
        assertEq(v0.box(), address(0), "Box not wired when CHIP is already prize stock");
    }

    function test_H01_LiveChipAddressCannotBeRescuedOrSurplused() public {
        address liveChip = boxes.DEFAULT_CHIP();
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, liveChip));
        vault.rescue(liveChip, alice, 1);

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, liveChip));
        vault.queueSurplusWithdraw(liveChip, alice, 1);
    }

    /* ------------------------------------------------------------------ */
    /*  H-05  open uses mint snapshot, not live SKU or odds                 */
    /* ------------------------------------------------------------------ */

    function test_H05_OpenUsesMintSnapshotNotLiveSkuOrOdds() public {
        uint256 id = _buy1(alice);
        IBox.BoxView memory minted = boxes.boxInfo(id);
        assertEq(minted.faceUsd, USD1);
        assertEq(minted.oddsVersion, 0);

        bytes32 roll0 = bytes32(uint256(0));
        (uint8 mintTier,, uint32 mintBps, uint256 mintPrize) = boxes.previewDraw(roll0, SKU1);
        assertEq(mintTier, 0, "roll 0 is dust on the 6-tier launch table");
        assertEq(mintPrize, 200_000); // $0.20

        // Raise SKU 0 to $25 and invert the table so the same roll is a 36× jackpot live.
        IBox.PrizeTier[] memory inverted = new IBox.PrizeTier[](6);
        inverted[0] = IBox.PrizeTier({weight: 4_500, prizeBps: 360_000});
        inverted[1] = IBox.PrizeTier({weight: 3_000, prizeBps: 80_000});
        inverted[2] = IBox.PrizeTier({weight: 1_500, prizeBps: 20_000});
        inverted[3] = IBox.PrizeTier({weight: 700, prizeBps: 10_000});
        inverted[4] = IBox.PrizeTier({weight: 250, prizeBps: 5_000});
        inverted[5] = IBox.PrizeTier({weight: 50, prizeBps: 2_000});

        vm.startPrank(multisig);
        boxes.queueSku(SKU1, true, uint96(25_000_000), CHIP1);
        boxes.queueOdds(inverted);
        vm.stopPrank();
        vm.warp(block.timestamp + 48 hours);
        vm.startPrank(multisig);
        boxes.executeSku();
        boxes.executeOdds();
        vault.setStockEnabled(address(nvda), false);
        vault.setStockEnabled(address(tsla), false);
        vm.stopPrank();

        (,,, uint256 livePrize) = boxes.previewDraw(roll0, SKU1);
        assertEq(livePrize, 25_000_000 * 360_000 / 10_000, "live $25 x 36x = $900");
        assertEq(boxes.sku(SKU1).usdcPrice, 25_000_000);
        assertEq(boxes.oddsTable().length, 6, "still six tiers");

        uint256 usdc0 = usdc.balanceOf(alice);
        uint128 fee = boxes.quoteOpenFee();
        vm.prank(alice);
        boxes.open{value: fee}(id);
        uint64 seq = boxes.boxInfo(id).sequence;

        vm.expectEmit(true, true, true, false);
        emit BoxOpened(alice, id, seq, SKU1, mintTier, mintBps, mintPrize, address(0), 0, 0, 0, false, false, false);
        entropy.fulfill(seq, roll0);

        uint256 paid = usdc.balanceOf(alice) - usdc0;
        assertEq(paid, mintPrize, "$1 ticket pays mint dust, not live $25 jackpot");
        assertTrue(paid != livePrize, "$1 ticket never pays $25-tier for the same roll");
    }

    /* ------------------------------------------------------------------ */
    /*  M-08  open forwards exact Entropy fee and refunds excess            */
    /* ------------------------------------------------------------------ */

    function test_M08_OpenForwardsExactEntropyFee_RefundsExcess() public {
        uint256 id = _buy1(alice);
        uint128 fee = boxes.quoteOpenFee();
        assertGt(fee, 0);
        uint256 eth0 = alice.balance;
        uint256 entropy0 = address(entropy).balance;

        vm.prank(alice);
        boxes.open{value: uint256(fee) + 0.05 ether}(id);

        assertEq(alice.balance, eth0 - fee, "excess ETH refunded");
        assertEq(address(entropy).balance, entropy0 + fee, "exact fee forwarded");
        assertEq(boxes.boxInfo(id).state, boxes.STATE_OPENING());
    }

    /// @notice Optional Base fork against live Pyth Entropy v2. Skips without BASE_RPC_URL.
    function test_M08_OpenForwardsExactEntropyFee_RefundsExcess_BaseFork() public {
        string memory url = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);

        address realEntropy = 0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb;
        uint128 fee = IEntropyV2(realEntropy).getFeeV2(500_000);
        assertGt(fee, 0, "live Entropy quotes a fee");

        MockERC20 forkUsdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 forkChip = new MockERC20("Chipworks", "CHIP", 18);
        PrizeVault forkVault = new PrizeVault(multisig, address(forkUsdc), address(forkChip), 2_500);
        Box forkBox = new Box(
            multisig,
            address(forkUsdc),
            address(forkChip),
            treasury,
            address(forkVault),
            realEntropy,
            CHIP1,
            CHIP10,
            CHIP25
        );
        vm.prank(multisig);
        forkVault.setBox(address(forkBox));

        vm.deal(alice, 10 ether);
        forkUsdc.mint(alice, 1_000 * 1e6);
        vm.startPrank(alice);
        forkUsdc.approve(address(forkBox), type(uint256).max);
        uint256 id = forkBox.buyWithUsdc(SKU1, alice);
        uint256 eth0 = alice.balance;
        uint256 entropy0 = realEntropy.balance;
        forkBox.open{value: uint256(fee) + 0.05 ether}(id);
        vm.stopPrank();

        assertEq(alice.balance, eth0 - fee, "fork: excess refunded");
        assertEq(realEntropy.balance, entropy0 + fee, "fork: exact fee forwarded");
        assertEq(forkBox.boxInfo(id).state, forkBox.STATE_OPENING());
    }
}

/// @dev Vault double: reports the Box as wired, then reverts on settle (H-04).
contract SettleReverter {
    address public box;

    function setBox(address v) external {
        box = v;
    }

    function settle(address, uint256, bytes32) external pure returns (IPrizeVault.Payout memory) {
        revert("settle down");
    }
}

/// @dev Box double: liability query reverts so surplus must fail closed (H-03).
contract LiabilityReverter {
    function outstandingLiabilityUsd() external pure returns (uint256) {
        revert("liability down");
    }

    function chip() external pure returns (address) {
        return address(0);
    }
}
