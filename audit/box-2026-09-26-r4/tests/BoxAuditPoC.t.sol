// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Box} from "../../src/box/Box.sol";
import {PrizeVault} from "../../src/box/PrizeVault.sol";
import {ChipConverter} from "../../src/box/ChipConverter.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {IEntropyV2} from "../../src/interfaces/IEntropyV2.sol";
import {IPrizeVault} from "../../src/interfaces/IPrizeVault.sol";
import {Venue} from "../../src/interfaces/IStockRegistry.sol";
import {PoolKey} from "../../src/interfaces/IUniswapV4.sol";
import {BoxTestBase} from "./BoxTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStockRegistry} from "../mocks/MockStockRegistry.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";

/// @notice PoC suite for Box audit Highs H-01–H-05 and Medium M-08, ported to the rebuild.
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
        bool fallbackStock,
        bool usdcFallback
    );
    event PrizeOwed(
        address indexed opener, uint256 indexed tokenId, uint8 tierId, uint256 prizeUsd, bool capped
    );

    /* ------------------------------------------------------------------ */
    /*  H-04  no payment/open into an unwired vault; failed settle -> OWED  */
    /* ------------------------------------------------------------------ */

    function test_H04_BuyRevertsIfVaultBoxUnset_NoPaymentTaken() public {
        (PrizeVault unwired, ChipConverter c) = _freshVaultAndConverter(address(chip));
        Box b = _newBox(address(unwired), address(chip), address(c));
        vm.prank(multisig);
        c.setBox(address(b)); // converter wired, VAULT not: the vault check must still stop the buy
        (uint256 w25, uint256 c25) = _chipQuote(USD25);
        assertEq(unwired.box(), address(0));
        usdc.mint(address(unwired), 200e6);

        uint256 usdc0 = usdc.balanceOf(alice);
        uint256 chip0 = chip.balanceOf(alice);

        vm.startPrank(alice);
        usdc.approve(address(b), type(uint256).max);
        chip.approve(address(b), type(uint256).max);
        vm.expectRevert(Box.VaultNotWired.selector);
        b.buyWithUsdc(SKU1, alice);
        vm.expectRevert(Box.VaultNotWired.selector);
        b.buyWithChip(SKU25, alice, w25, c25 * 2, block.timestamp);
        (uint256 w2, uint256 c2) = _chipQuote(2 * USD1);
        vm.expectRevert(Box.VaultNotWired.selector);
        b.buyWithChipBatch(SKU1, alice, 2, w2, c2 * 2, block.timestamp);
        vm.expectRevert(Box.VaultNotWired.selector);
        b.buyWithUsdcBatch(SKU1, alice, 2);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), usdc0, "unwired buy: USDC not taken");
        assertEq(chip.balanceOf(alice), chip0, "unwired buy: CHIP not taken");
        assertEq(chip.balanceOf(address(c)), 0, "unwired buy: converter got nothing");
        assertEq(b.nextId(), 1);
    }

    function test_H04_OpenRevertsIfVaultUnwiredAfterMint() public {
        SettleReverter hostile = _hostileVault();
        Box b2 = _newBox(address(hostile), address(chip), address(converter));
        hostile.setBox(address(b2));
        vm.startPrank(alice);
        usdc.approve(address(b2), type(uint256).max);
        uint256 id = b2.buyWithUsdc(SKU1, alice);
        vm.stopPrank();

        hostile.setBox(address(0));
        uint128 fee = b2.quoteOpenFee();
        uint256 eth0 = alice.balance;
        vm.prank(alice);
        vm.expectRevert(Box.VaultNotWired.selector);
        b2.open{value: fee}(id);
        assertEq(alice.balance, eth0, "no Entropy fee spent");
        assertEq(b2.boxInfo(id).state, b2.STATE_SEALED());
    }

    /// @notice A wired-but-reverting vault: the callback must not revert, must not silently
    ///         burn, and must not re-roll. The drawn prize is fixed as OWED.
    function test_H04_FailedSettleLeavesBoxOwed_NoSilentBurn() public {
        SettleReverter hostile = _hostileVault();
        Box b2 = _newBox(address(hostile), address(chip), address(converter));
        hostile.setBox(address(b2));
        vm.startPrank(alice);
        usdc.approve(address(b2), type(uint256).max);
        uint256 id2 = b2.buyWithUsdc(SKU1, alice);
        uint128 fee2 = b2.quoteOpenFee();
        b2.open{value: fee2}(id2);
        vm.stopPrank();
        uint64 seq = b2.boxInfo(id2).sequence;

        vm.expectEmit(true, true, true, true);
        emit PrizeOwed(alice, id2, 0, 200_000, false); // roll 0 -> Dust 0.20x of $1
        entropy.fulfill(seq, bytes32(uint256(0)));

        assertEq(b2.ownerOf(id2), alice, "failed settle: ownerOf unchanged");
        IBox.BoxView memory v = b2.boxInfo(id2);
        assertEq(v.state, b2.STATE_OWED());
        assertEq(v.owedUsd, 200_000);
        assertEq(b2.sealedSupply(SKU1), 1, "not retired");
        assertEq(b2.outstandingLiabilityUsd(), 200_000, "liability is now the exact owed prize");
        assertEq(b2.tokenIdOfRequest(address(entropy), seq), 0, "the sequence is spent: no second draw");

        // A late duplicate callback is an orphan, not a re-roll.
        entropy.fulfill(seq, bytes32(uint256(9_999)));
        assertEq(b2.boxInfo(id2).owedUsd, 200_000);

        // Owed boxes are bound to the opener.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.BoxLocked.selector, id2));
        b2.transferFrom(alice, bob, id2);

        // Claim still fails while the vault does; nothing changes.
        vm.expectRevert(bytes("settle down"));
        b2.claimOwed(id2);
        assertEq(b2.boxInfo(id2).state, b2.STATE_OWED());
    }

    /* ------------------------------------------------------------------ */
    /*  H-03  failed liability cannot zero surplus; cannot retire sealed SKU */
    /* ------------------------------------------------------------------ */

    function test_H03_CannotRetireSkuWithSealedSupply() public {
        uint256 id = _buy1(alice);
        vm.prank(multisig);
        boxes.queueSku(SKU1, false, 0, false);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(Box.SealedSupplyOutstanding.selector, SKU1));
        boxes.executeSku();
        assertEq(boxes.ownerOf(id), alice);
        assertEq(boxes.sealedSupply(SKU1), 1);
        assertTrue(boxes.sku(SKU1).exists);
        assertGt(boxes.outstandingLiabilityUsd(), 0);

        // Once the ticket is opened and paid, the SKU can be retired.
        _openAndFulfill(alice, id, _rollForTier(2));
        assertEq(boxes.sealedSupply(SKU1), 0);
        vm.prank(multisig);
        boxes.queueSku(SKU1, false, 0, false);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        boxes.executeSku();
        assertFalse(boxes.sku(SKU1).exists);
    }

    /// @notice An OWED box still counts as sealed supply, so its SKU cannot be retired either.
    function test_H03_OwedBoxBlocksSkuRetirement() public {
        SettleReverter hostile = _hostileVault();
        Box b2 = _newBox(address(hostile), address(chip), address(converter));
        hostile.setBox(address(b2));
        vm.startPrank(alice);
        usdc.approve(address(b2), type(uint256).max);
        uint256 id = b2.buyWithUsdc(SKU1, alice);
        uint128 fee = b2.quoteOpenFee();
        b2.open{value: fee}(id);
        vm.stopPrank();
        entropy.fulfill(b2.boxInfo(id).sequence, bytes32(uint256(0)));
        assertEq(b2.boxInfo(id).state, b2.STATE_OWED());

        vm.prank(multisig);
        b2.queueSku(SKU1, false, 0, false);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(Box.SealedSupplyOutstanding.selector, SKU1));
        b2.executeSku();
    }

    function test_H03_FailedLiabilityCannotZeroSurplusRequirement() public {
        (PrizeVault v,) = _freshVaultAndConverter(address(0));
        LiabilityReverter hostile = new LiabilityReverter(address(usdc), address(0), address(v));
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

        // The permissionless sweep fails closed too.
        assertEq(v.sweepableUsdc(), 0);
        vm.expectRevert(PrizeVault.NothingToSweep.selector);
        v.sweepSurplus();
        assertEq(usdc.balanceOf(address(v)), usdc0);
    }

    /* ------------------------------------------------------------------ */
    /*  H-02  an over-marked stock cannot bypass the USDC liability floor   */
    /* ------------------------------------------------------------------ */

    function test_H02_FakeStockMarkCannotBypassSurplusFloor() public {
        _buy1(alice);
        uint256 required = boxes.outstandingLiabilityUsd() * 11_000 / 10_000;
        assertGt(required, 0);

        // Marks now come from the registry, not the vault owner. Even a registry stock marked
        // at $1e9 cannot stand in for the USDC floor.
        MockERC20 fake = new MockERC20("Fake", "FAKE", 8);
        registry.setStock(address(fake), Venue.Slipstream, 0, 10, 8, true);
        registry.setPrice(address(fake), 1_000_000_000e18);
        vm.prank(multisig);
        vault.addStock(address(fake));
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
    /*  H-01  (redone) $CHIP never reaches the vault; never stock           */
    /* ------------------------------------------------------------------ */

    /// @notice Was `test_H01_ChipBuyNeverReachesVault` (whole payment parked on the converter).
    ///         Swap-at-buy: a $CHIP buy funds the vault with 95% of face in USDC and the fee
    ///         recipient with 5% in USDC, in the same transaction. No CHIP lands anywhere.
    function test_H01_ChipBuyFundsVaultInUsdcNeverChip() public {
        uint256 vaultUsdc0 = usdc.balanceOf(address(vault));
        uint256 tre0 = usdc.balanceOf(treasury);
        uint256 inv0 = vault.inventoryUsd();
        uint256 alice0 = chip.balanceOf(alice);
        uint8[3] memory skus = [SKU1, SKU10, SKU25];
        uint256 face;
        uint256 cost;
        for (uint256 i; i < skus.length; ++i) {
            (, uint256 c) = _chipQuote(_skuUsd(skus[i]));
            cost += c;
            face += _skuUsd(skus[i]);
            _buyChip(alice, skus[i]);
        }
        (uint256 w3, uint256 c3) = _chipQuote(3 * USD10);
        vm.prank(alice);
        boxes.buyWithChipBatch(SKU10, alice, 3, w3, c3 * 101 / 100, block.timestamp);
        face += 3 * USD10;
        cost += c3;

        uint256 fee = face * 500 / 10_000;
        assertEq(usdc.balanceOf(address(vault)) - vaultUsdc0, face - fee, "95% of face in USDC, at once");
        assertEq(usdc.balanceOf(treasury) - tre0, fee, "5% fee in USDC, at once");
        assertEq(vault.inventoryUsd() - inv0, face - fee);
        assertEq(alice0 - chip.balanceOf(alice), cost, "buyer paid the swap cost, the rest refunded");
        assertEq(chip.balanceOf(address(vault)), 0, "vault never receives CHIP");
        assertEq(chip.balanceOf(address(boxes)), 0);
        assertEq(chip.balanceOf(treasury), 0);
        (uint256 cc, uint256 cw, uint256 cu) = converter.sweepZero();
        assertEq(cc + cw + cu, 0, "converter holds nothing between calls");
        assertEq(usdc.balanceOf(address(boxes)), 0);
    }

    function test_H01_ChipBuyRevertsIfConverterUnwired() public {
        (PrizeVault v, ChipConverter c) = _freshVaultAndConverter(address(chip));
        Box b = _newBox(address(v), address(chip), address(c));
        vm.prank(multisig);
        v.setBox(address(b)); // converter deliberately NOT wired
        usdc.mint(address(v), 200e6);

        (uint256 w1, uint256 c1) = _chipQuote(USD1);
        vm.startPrank(alice);
        usdc.approve(address(b), type(uint256).max);
        chip.approve(address(b), type(uint256).max);
        uint256 chip0 = chip.balanceOf(alice);
        vm.expectRevert(Box.ConverterNotWired.selector);
        b.buyWithChip(SKU1, alice, w1, c1 * 2, block.timestamp);
        assertEq(chip.balanceOf(alice), chip0);
        b.buyWithUsdc(SKU1, alice); // USDC path unaffected
        vm.stopPrank();
    }

    function test_H01_ChipSymmetryRequired_MismatchCannotLeaveChipUnprotected() public {
        // Vault built without CHIP, Box with CHIP.
        (PrizeVault v0,) = _freshVaultAndConverter(address(0));
        vm.expectRevert(Box.BadConfig.selector);
        _newBox(address(v0), address(chip), address(converter));

        // Vault and Box disagree on which token is CHIP.
        (PrizeVault v1, ChipConverter c1) = _freshVaultAndConverter(address(chip));
        MockERC20 other = new MockERC20("OtherChip", "OCHP", 18);
        vm.expectRevert(Box.BadConfig.selector);
        _newBox(address(v1), address(other), address(c1));

        // CHIP without a converter, or a converter without CHIP.
        vm.expectRevert(Box.BadConfig.selector);
        _newBox(address(v1), address(chip), address(0));
        vm.expectRevert(Box.BadConfig.selector);
        _newBox(address(v0), address(0), address(c1));

        // A converter for a different CHIP.
        ChipConverter otherConv = _converterFor(address(other));
        vm.expectRevert(Box.BadConfig.selector);
        _newBox(address(v1), address(chip), address(otherConv));

        // setBox refuses a Box-shaped contract whose chip() differs from vault.chip.
        // Built first: expectRevert binds to the NEXT call, and an inline `new` would be it.
        address zeroChipBox = address(new LiabilityReverter(address(usdc), address(0), address(v1)));
        vm.prank(multisig);
        vm.expectRevert(PrizeVault.BadConfig.selector);
        v1.setBox(zeroChipBox);
        assertEq(v1.box(), address(0));

        // The converter refuses a Box that does not name it.
        Box b1 = _newBox(address(v1), address(chip), address(c1));
        ChipConverter c2 = _converterFor(address(chip));
        vm.prank(multisig);
        vm.expectRevert(ChipConverter.BadConfig.selector);
        c2.setBox(address(b1)); // b1.converter() == c1, not c2
    }

    function test_H01_AddStockChipForbidden() public {
        // Even if the registry listed CHIP, the vault refuses it.
        registry.setStock(address(chip), Venue.Slipstream, 0, 10, 18, true);
        registry.setPrice(address(chip), 1e18);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, address(chip)));
        vault.addStock(address(chip));
        assertEq(vault.stockCount(), 2, "CHIP never entered the prize catalog");

        // Live Base CHIP address is always refused, even on a vault constructed with chip=0.
        (PrizeVault v0,) = _freshVaultAndConverter(address(0));
        address liveChip = v0.DEFAULT_CHIP();
        assertEq(liveChip, boxes.DEFAULT_CHIP());
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, liveChip));
        v0.addStock(liveChip);
        assertEq(v0.stockCount(), 0);

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, liveChip));
        vault.addStock(liveChip);
    }

    function test_H01_SurplusWithdrawChipForbidden() public {
        chip.mint(address(vault), 11 ether);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.NotRegistered.selector, address(chip)));
        vault.queueSurplusWithdraw(address(chip), alice, 11 ether);

        address liveChip = boxes.DEFAULT_CHIP();
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.NotRegistered.selector, liveChip));
        vault.queueSurplusWithdraw(liveChip, alice, 1);
        assertEq(chip.balanceOf(address(vault)), 11 ether);
    }

    function test_H01_SettleDoesNotPayChip() public {
        chip.mint(address(vault), 1_000_000 ether); // stray CHIP, e.g. a mistaken transfer
        uint256 chip0 = chip.balanceOf(address(vault));

        vm.startPrank(multisig);
        vault.setStockEnabled(address(nvda), false);
        vault.setStockEnabled(address(tsla), false);
        vm.stopPrank();

        vm.prank(alice);
        uint256 id = boxes.buyWithUsdc(SKU10, alice);
        uint256 aliceChip0 = chip.balanceOf(alice);
        uint256 aliceUsdc0 = usdc.balanceOf(alice);
        _openAndFulfill(alice, id, _rollForTier(2)); // 1.00x of $10 -> $10 USDC
        assertEq(usdc.balanceOf(alice) - aliceUsdc0, USD10);
        assertEq(chip.balanceOf(alice), aliceChip0, "no CHIP paid from the vault");
        assertEq(chip.balanceOf(address(vault)), chip0, "settle never spends vault CHIP");
        assertEq(vault.inventoryUsd(), usdc.balanceOf(address(vault)), "CHIP is not prize inventory");

        // Dust and Common pay like every other tier: here the USDC fallback, never CHIP.
        vm.prank(alice);
        uint256 id2 = boxes.buyWithUsdc(SKU10, alice);
        uint256 aliceUsdc1 = usdc.balanceOf(alice);
        _openAndFulfill(alice, id2, _rollForTier(0)); // Dust: $2
        assertEq(usdc.balanceOf(alice) - aliceUsdc1, 2e6, "Dust paid at its exact USD value");
        assertEq(chip.balanceOf(address(vault)), chip0);
        assertEq(chip.balanceOf(alice), aliceChip0);
        assertEq(usdc.balanceOf(address(converter)), 0, "nothing escrowed on the converter");
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

        // Raise SKU 0 to $25 and invert the table so the same roll is a 36x jackpot live.
        vm.startPrank(multisig);
        boxes.queueSku(SKU1, true, uint96(25_000_000), true);
        boxes.queueOdds(_inverted());
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
        uint64 seq = _open(alice, id);

        vm.expectEmit(true, true, true, true);
        emit BoxOpened(alice, id, seq, SKU1, mintTier, mintBps, mintPrize, address(0), 0, mintPrize, false, true);
        entropy.fulfill(seq, roll0);

        // Paid the mint-time Dust prize, $0.20, at once (stocks off -> USDC fallback), not $900.
        uint256 paid = usdc.balanceOf(alice) - usdc0;
        assertEq(paid, mintPrize, "$1 ticket pays mint dust, not live $25 jackpot");
        assertTrue(paid != livePrize, "$1 ticket never pays $25-tier for the same roll");
    }

    function test_H05_TenAndTwentyFiveOpenUsesMintSnapshot() public {
        vm.prank(alice);
        uint256 id10 = boxes.buyWithUsdc(SKU10, alice);
        uint256 id25 = _buyChip(alice, SKU25);

        IBox.BoxView memory m10 = boxes.boxInfo(id10);
        IBox.BoxView memory m25 = boxes.boxInfo(id25);
        assertEq(m10.faceUsd, USD10);
        assertEq(m25.faceUsd, USD25);
        assertEq(m10.mintEvUsd, 9_100_000);
        assertEq(m25.mintEvUsd, 22_750_000);
        assertEq(boxes.outstandingLiabilityUsd(), m10.mintEvUsd + m25.mintEvUsd);

        bytes32 roll0 = bytes32(uint256(0));
        uint256 dust10 = USD10 * 2_000 / 10_000; // $2.00
        uint256 dust25 = USD25 * 2_000 / 10_000; // $5.00

        vm.startPrank(multisig);
        boxes.queueSku(SKU10, true, uint96(USD1), true);
        boxes.queueOdds(_inverted());
        vm.stopPrank();
        vm.warp(block.timestamp + 48 hours);
        vm.startPrank(multisig);
        boxes.executeSku();
        boxes.executeOdds();
        vault.setStockEnabled(address(nvda), false);
        vault.setStockEnabled(address(tsla), false);
        vm.stopPrank();

        uint256 live10Jackpot = USD1 * 360_000 / 10_000;
        (,,, uint256 livePreview) = boxes.previewDraw(roll0, SKU10);
        assertEq(livePreview, live10Jackpot);
        assertEq(boxes.outstandingLiabilityUsd(), m10.mintEvUsd + m25.mintEvUsd, "SKU rewrite does not move mint EV");

        uint256 usdc0 = usdc.balanceOf(alice);
        _openAndFulfill(alice, id10, roll0);
        uint256 paid10 = usdc.balanceOf(alice) - usdc0;
        assertEq(paid10, dust10, "$10 ticket pays mint 0.20x ($2), not live $1 jackpot");
        assertTrue(paid10 != live10Jackpot);

        uint256 usdc1 = usdc.balanceOf(alice);
        _openAndFulfill(alice, id25, roll0);
        uint256 paid25 = usdc.balanceOf(alice) - usdc1;
        assertEq(paid25, dust25, "$25 ticket pays mint 0.20x ($5), not inverted live table");
        assertLt(paid25, 25_000_000 * 360_000 / 10_000);
        assertEq(usdc.balanceOf(address(converter)), 0, "nothing escrowed on the converter");
        assertEq(boxes.outstandingLiabilityUsd(), 0);
    }

    function test_H05_VaultCannotOverpaySnapshotPrize_AllSkus() public {
        uint8[3] memory skus = [SKU1, SKU10, SKU25];
        vm.startPrank(multisig);
        vault.setStockEnabled(address(nvda), false);
        vault.setStockEnabled(address(tsla), false);
        vm.stopPrank();

        bytes32 par = _rollForTier(2); // 1.00x, a stock tier -> USDC fallback here

        for (uint256 i; i < skus.length; ++i) {
            uint8 skuId = skus[i];
            uint256 face = _skuUsd(skuId);
            vm.prank(alice);
            uint256 id = boxes.buyWithUsdc(skuId, alice);
            IBox.BoxView memory minted = boxes.boxInfo(id);
            assertEq(minted.faceUsd, face);
            assertEq(minted.mintEvUsd, face * 9_100 / 10_000);

            uint256 aliceUsdc = usdc.balanceOf(alice);
            uint256 vaultUsdc = usdc.balanceOf(address(vault));
            _openAndFulfill(alice, id, par);
            uint256 paid = usdc.balanceOf(alice) - aliceUsdc;
            assertEq(paid, face, "par tier pays exactly mint face, never more");
            assertEq(vaultUsdc - usdc.balanceOf(address(vault)), face);
            assertLe(paid, minted.faceUsd);
            assertEq(chip.balanceOf(address(vault)), 0, "vault holds no CHIP");
        }
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
        assertEq(address(boxes).balance, 0, "Box keeps no ETH");
        assertEq(boxes.boxInfo(id).state, boxes.STATE_OPENING());
    }

    function test_M08_RetryOpenForwardsExactFeeAndRefunds() public {
        uint256 id = _buy1(alice);
        _open(alice, id);
        vm.warp(block.timestamp + boxes.REVEAL_TIMEOUT());
        entropy.setFee(0.002 ether);
        uint128 fee = boxes.quoteOpenFee();
        assertEq(fee, 0.002 ether);
        uint256 eth0 = alice.balance;
        uint256 entropy0 = address(entropy).balance;
        vm.prank(alice);
        boxes.retryOpen{value: 1 ether}(id);
        assertEq(alice.balance, eth0 - fee);
        assertEq(address(entropy).balance, entropy0 + fee);
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
        // USDC-only Box on fresh mocks (no CHIP path, so no converter / v4 pool needed).
        MockERC20 forkUsdc = new MockERC20("USD Coin", "USDC", 6);
        MockStockRegistry forkReg = new MockStockRegistry(address(forkUsdc));
        MockSwapRouter forkRouter = new MockSwapRouter();
        PrizeVault forkVault = new PrizeVault(
            multisig, address(forkUsdc), address(0), address(forkReg), address(forkRouter), address(forkRouter), 2_500
        );
        Box forkBox = new Box(
            multisig,
            address(forkUsdc),
            address(0),
            treasury,
            address(forkVault),
            address(0),
            realEntropy
        );
        vm.prank(multisig);
        forkVault.setBox(address(forkBox));
        forkUsdc.mint(address(forkVault), 200e6); // covers SKU1's $36 top prize
        // The fee at the Box's own callback gas limit, not an assumed one.
        uint128 fee = IEntropyV2(realEntropy).getFeeV2(forkBox.callbackGasLimit());
        assertGt(fee, 0, "live Entropy quotes a fee");
        assertEq(fee, forkBox.quoteOpenFee());

        // Forge's well-known `alice` key has code on Base mainnet (an EIP-7702 delegation), which
        // makes _safeMint's receiver check fail. Clear it: this test is about the Entropy fee.
        vm.etch(alice, "");
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

    /* ------------------------------------------------------------------ */
    /*                              HELPERS                                 */
    /* ------------------------------------------------------------------ */

    function _inverted() internal pure returns (IBox.PrizeTier[] memory t) {
        t = new IBox.PrizeTier[](6);
        t[0] = IBox.PrizeTier({weight: 4_500, prizeBps: 360_000});
        t[1] = IBox.PrizeTier({weight: 3_000, prizeBps: 80_000});
        t[2] = IBox.PrizeTier({weight: 1_500, prizeBps: 20_000});
        t[3] = IBox.PrizeTier({weight: 700, prizeBps: 10_000});
        t[4] = IBox.PrizeTier({weight: 250, prizeBps: 5_000});
        t[5] = IBox.PrizeTier({weight: 50, prizeBps: 2_000});
    }

    function _hostileVault() internal returns (SettleReverter hostile) {
        hostile = new SettleReverter();
        hostile.setTokens(address(usdc), address(chip));
    }

    function _converterFor(address chip_) internal returns (ChipConverter) {
        (address c0, address c1) = chip_ < address(weth) ? (chip_, address(weth)) : (address(weth), chip_);
        return new ChipConverter(
            multisig,
            chip_,
            address(weth),
            address(usdc),
            address(pm),
            address(v3),
            500,
            PoolKey({currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 200, hooks: address(0)})
        );
    }
}

/// @dev Vault double: reports the Box as wired and a huge cap, then reverts on settle (H-04).
contract SettleReverter {
    address public box;
    address public usdc;
    address public chip;

    function setBox(address v) external {
        box = v;
    }

    function setTokens(address usdc_, address chip_) external {
        usdc = usdc_;
        chip = chip_;
    }

    function prizeCapUsd() external pure returns (uint256) {
        return type(uint128).max;
    }

    function settle(address, uint256, bytes32, bool) external pure returns (IPrizeVault.Payout memory) {
        revert("settle down");
    }
}

/// @dev Box double: liability query reverts so surplus must fail closed (H-03).
contract LiabilityReverter {
    address public usdc;
    address public chip;
    address public vault;

    constructor(address usdc_, address chip_, address vault_) {
        usdc = usdc_;
        chip = chip_;
        vault = vault_;
    }

    function outstandingLiabilityUsd() external pure returns (uint256) {
        revert("liability down");
    }

    function maxLivePrizeUsd() external pure returns (uint256) {
        return 0;
    }
}
