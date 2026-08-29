// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Pot} from "../src/Pot.sol";
import {ClutchVaultAdapter} from "../src/adapters/ClutchVaultAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNoun, GasBombNoun} from "./mocks/MockNoun.sol";
import {MockSoftStakingVault} from "./mocks/MockSoftStakingVault.sol";

contract PotTest is Test {
    Pot internal pot;
    MockERC20 internal usdc;
    MockERC20 internal junk;

    address internal multisig = makeAddr("multisig");
    address internal rewards = makeAddr("rewards");
    address internal randomer = makeAddr("randomer");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        junk = new MockERC20("Junk", "JUNK", 18);
        pot = new Pot(multisig, address(usdc));
        vm.prank(multisig);
        pot.setRewards(rewards);
    }

    function test_availableCountsOnlyTheRoundCurrency() public {
        usdc.mint(address(pot), 1_000e6);
        junk.mint(address(pot), 5_000 ether);
        vm.deal(address(pot), 3 ether);

        assertEq(pot.available(), 1_000e6, "ETH and junk do not count toward the round gate");
    }

    function test_pullBudget_onlyRewards() public {
        usdc.mint(address(pot), 1_000e6);

        vm.prank(randomer);
        vm.expectRevert(abi.encodeWithSelector(Pot.NotRewards.selector, randomer));
        pot.pullBudget(100e6);

        vm.prank(multisig); // not even the owner
        vm.expectRevert(abi.encodeWithSelector(Pot.NotRewards.selector, multisig));
        pot.pullBudget(100e6);

        vm.prank(rewards);
        assertEq(pot.pullBudget(400e6), 400e6);
        assertEq(usdc.balanceOf(rewards), 400e6);
    }

    function test_pullBudget_clampsToBalance() public {
        usdc.mint(address(pot), 100e6);
        vm.prank(rewards);
        assertEq(pot.pullBudget(999_999e6), 100e6, "clamped, not reverted");
    }

    function test_sweepNonQuote_cannotTouchTheRoundCurrency() public {
        usdc.mint(address(pot), 1_000e6);
        vm.prank(multisig);
        vm.expectRevert(Pot.CannotSweepQuoteToken.selector);
        pot.sweepNonQuote(address(usdc), multisig);
    }

    function test_sweepNonQuote_movesOtherAssetsForConversion() public {
        junk.mint(address(pot), 500 ether);
        vm.prank(multisig);
        pot.sweepNonQuote(address(junk), multisig);
        assertEq(junk.balanceOf(multisig), 500 ether);
    }

    function test_sweepNonQuote_onlyMultisig() public {
        junk.mint(address(pot), 500 ether);
        vm.prank(randomer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomer));
        pot.sweepNonQuote(address(junk), randomer);
    }

    function test_sweepEth() public {
        vm.deal(address(pot), 4 ether);
        vm.prank(multisig);
        pot.sweepEth(multisig);
        assertEq(multisig.balance, 4 ether);
    }

    function test_receivesEthCheaply() public {
        vm.deal(randomer, 1 ether);
        vm.prank(randomer);
        (bool ok,) = address(pot).call{value: 1 ether, gas: 2_300}("");
        assertTrue(ok);
    }
}

contract ClutchVaultAdapterTest is Test {
    ClutchVaultAdapter internal adapter;
    MockNoun internal nouns;
    MockSoftStakingVault internal vault;

    address internal multisig = makeAddr("multisig");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        adapter = new ClutchVaultAdapter(multisig, [uint32(10_000), 12_500, 16_000, 20_000, 33_300]);
        nouns = new MockNoun("Based Nouns", "BASED");
        vault = new MockSoftStakingVault(IERC721(address(nouns)));
        vm.prank(multisig);
        adapter.setVault(address(nouns), address(vault));
    }

    function test_reportsTierAndOwner() public {
        nouns.mint(alice, 1);
        vm.prank(alice);
        vault.activate(1, 2);

        (bool active, uint32 tierBps, address owner) = adapter.activation(address(nouns), 1);
        assertTrue(active);
        assertEq(tierBps, 16_000, "tier 2 == 1.60x");
        assertEq(owner, alice);
    }

    function test_unregisteredCollectionIsInactiveNotARevert() public view {
        (bool active,, address owner) = adapter.activation(address(0x1234), 1);
        assertFalse(active);
        assertEq(owner, address(0));
    }

    function test_unactivatedTokenIsInactive() public {
        nouns.mint(alice, 1);
        (bool active,,) = adapter.activation(address(nouns), 1);
        assertFalse(active);
    }

    /// @notice The A-8 mitigation. The vault still says active; the adapter must not.
    function test_transferredNounReportsInactiveWithoutAKick() public {
        nouns.mint(alice, 1);
        vm.prank(alice);
        vault.activate(1, 3);

        vm.prank(alice);
        nouns.transferFrom(alice, bob, 1);

        assertTrue(vault.isActive(1), "vault has not been kicked");
        (bool active,, address owner) = adapter.activation(address(nouns), 1);
        assertFalse(active, "adapter refuses to trust it");
        assertEq(owner, address(0));
    }

    function test_afterKickAndReactivationTheNewOwnerEarns() public {
        nouns.mint(alice, 1);
        vm.prank(alice);
        vault.activate(1, 1);
        vm.prank(alice);
        nouns.transferFrom(alice, bob, 1);

        vault.kick(1);
        vm.prank(bob);
        vault.activate(1, 1);

        (bool active, uint32 tierBps, address owner) = adapter.activation(address(nouns), 1);
        assertTrue(active);
        assertEq(tierBps, 12_500);
        assertEq(owner, bob);
    }

    function test_tierTableIsConfigurable() public {
        nouns.mint(alice, 1);
        vm.prank(alice);
        vault.activate(1, 4);

        (, uint32 before,) = adapter.activation(address(nouns), 1);
        assertEq(before, 33_300);

        vm.prank(multisig);
        adapter.setTierBps(4, 40_000);

        (, uint32 nowBps,) = adapter.activation(address(nouns), 1);
        assertEq(nowBps, 40_000, "corrected without a redeploy");
    }

    function test_setTierBps_onlyMultisigAndBounded() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        adapter.setTierBps(0, 1);

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ClutchVaultAdapter.BadTier.selector, uint256(5)));
        adapter.setTierBps(5, 10_000);
    }

    /// @notice De-registering a vault is the emergency switch: everything in that
    ///         collection scores zero rather than reverting.
    function test_deregisteringAVaultZeroesTheCollection() public {
        nouns.mint(alice, 1);
        vm.prank(alice);
        vault.activate(1, 0);

        vm.prank(multisig);
        adapter.setVault(address(nouns), address(0));

        (bool active,,) = adapter.activation(address(nouns), 1);
        assertFalse(active);
        assertFalse(adapter.isSupportedCollection(address(nouns)));
    }

    /// @notice A vault or collection that burns all gas must degrade to "inactive", never
    ///         revert. ASSUMPTIONS A-17 at the adapter boundary.
    function test_gasBombCollectionDegradesToInactive() public {
        GasBombNoun bomb = new GasBombNoun();
        vm.prank(multisig);
        adapter.setVault(address(bomb), address(vault));

        (bool active,,) = adapter.activation(address(bomb), 1);
        assertFalse(active);
    }

    function test_vaultThatIsNotAContractDegradesToInactive() public {
        vm.prank(multisig);
        adapter.setVault(address(nouns), address(0xDEAD));
        (bool active,,) = adapter.activation(address(nouns), 1);
        assertFalse(active);
    }

    /// @notice A tier the table has no entry for must not silently pay 1.00x.
    function test_zeroTierBpsMeansNoWeight() public {
        nouns.mint(alice, 1);
        vm.prank(alice);
        vault.activate(1, 0);

        vm.prank(multisig);
        adapter.setTierBps(0, 0);

        (bool active,,) = adapter.activation(address(nouns), 1);
        assertFalse(active, "tier worth nothing is treated as inactive");
    }
}
