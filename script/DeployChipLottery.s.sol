// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ChipLottery} from "../src/lottery/ChipLottery.sol";
import {PoolKey} from "../src/interfaces/IUniswapV4.sol";

interface IJackpotCheck {
    function usdc() external view returns (address);
    function ticketPrice() external view returns (uint256);
}

interface IStateView {
    function getSlot0(bytes32 poolId) external view returns (uint160 sqrtPriceX96, int24, uint24, uint24);
    function getLiquidity(bytes32 poolId) external view returns (uint128);
}

/**
 * Deploy ChipLottery.
 *
 * -- EVERY ARGUMENT IS CHECKED AGAINST THE CHAIN BEFORE IT IS USED ---------
 *
 * Nine of the ten constructor arguments are addresses, and all of them are
 * `immutable`: a wrong one cannot be corrected, only redeployed around. Worse,
 * most wrong values do not fail loudly - a plausible-but-wrong pool key produces
 * a contract that reverts on the first buy, and a wrong referrer produces one
 * that works perfectly while paying the fee to somebody else for ever.
 *
 * So this script asks the chain to confirm each one before broadcasting:
 *
 *   - the Jackpot agrees its quote token is this USDC, and prices a ticket at $1
 *   - the pool named by the key actually exists and holds liquidity
 *   - the referrer is not a plain contract (it must be able to claim its fees)
 *   - the Safe is a contract, the tokens all have code
 *
 * It reverts before `vm.startBroadcast()` if any of that is untrue, so a bad
 * argument costs nothing.
 *
 * -- RUNNING IT -----------------------------------------------------------
 *
 *   forge script script/DeployChipLottery.s.sol:DeployChipLottery \
 *     --rpc-url $BASE_RPC_URL --account <your-keystore-account> --broadcast --verify
 *
 * Dry run first WITHOUT --broadcast: every check below still runs, and the
 * console prints the address the deploy would produce.
 */
contract DeployChipLottery is Script {
    // ---- Base mainnet -------------------------------------------------------
    address constant CHIP = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant STATE_VIEW = 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71;
    address constant V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant JACKPOT = 0x3bAe643002069dBCbcd62B1A4eb4C4A397d042a2;
    address constant HOOK = 0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544;

    /// @dev BasedMining's EOA. MUST stay an account with a key: `referralScheme` is
    ///      baked into each ticket at mint and only this address can claim the fee.
    address constant REFERRER = 0x70D3a9aA7e10070d3F528e91c9bCf5158c922C66;

    /// @dev The Safe. Owns the contract; its only power is {rescue}.
    address constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;

    uint24 constant V3_FEE = 500; // 0.05%
    uint24 constant DYNAMIC_FEE_FLAG = 8_388_608; // 0x800000
    int24 constant TICK_SPACING = 200;

    function run() external returns (address lottery) {
        PoolKey memory key = PoolKey({
            currency0: WETH,
            currency1: CHIP,
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: HOOK
        });

        _check(key);

        vm.startBroadcast();
        ChipLottery l = new ChipLottery(SAFE, CHIP, WETH, USDC, POOL_MANAGER, V3_ROUTER, JACKPOT, REFERRER, key, V3_FEE);
        vm.stopBroadcast();

        // Read the immutables back off the deployed code rather than trusting the
        // arguments we just passed.
        require(l.owner() == SAFE, "owner is not the Safe");
        require(address(l.chip()) == CHIP, "chip wrong");
        require(address(l.weth()) == WETH, "weth wrong");
        require(address(l.usdc()) == USDC, "usdc wrong");
        require(address(l.jackpot()) == JACKPOT, "jackpot wrong");
        require(l.referrer() == REFERRER, "referrer wrong");
        require(l.v3Fee() == V3_FEE, "v3Fee wrong");
        require(l.currency0() == WETH && l.currency1() == CHIP, "pool key wrong");
        require(l.hooks() == HOOK, "hook wrong");
        require(l.tickSpacing() == TICK_SPACING, "tickSpacing wrong");
        require(l.poolFee() == DYNAMIC_FEE_FLAG, "pool fee flag wrong");
        require(!l.chipIsCurrency0(), "ordering derived wrongly - WETH sorts below CHIP on Base");

        /*
          OPENING BALANCES ARE REPORTED, NOT REQUIRED TO BE ZERO.

          This asserted (0,0,0) and the dry run rightly failed it: the address a
          deploy lands on can already hold tokens. Anyone may send to an address
          before a contract exists there, and the first candidate address here turned
          out to hold 0.000016485 WETH with no code and nonce 0.

          That is harmless - the Safe can {rescue} it - and blocking a deploy over it
          would be blocking on somebody else's dust. The invariant this contract
          actually claims is that NO BUY LEAVES A BALANCE BEHIND, which is a property
          of buyWithChip and is asserted at the end of every fork test. A non-zero
          opening balance does not touch it.

          Worth printing, though: it is the one number a reviewer would otherwise
          misread later as the contract having accumulated something.
        */
        (uint256 c, uint256 w, uint256 u) = l.sweepZero();
        if (c != 0 || w != 0 || u != 0) {
            console2.log("NOTE: this address already held tokens before deployment.");
            console2.log("  CHIP %s   WETH %s   USDC %s", c, w, u);
            console2.log("  Harmless - recoverable with rescue(). Not accumulated by any buy.");
        } else {
            console2.log("opening balances: 0 / 0 / 0");
        }

        console2.log("");
        console2.log("=== ChipLottery DEPLOYED ===");
        console2.log("address        %s", address(l));
        console2.log("owner (Safe)   %s", l.owner());
        console2.log("referrer       %s", l.referrer());
        console2.log("chipIsCurrency0 %s", l.chipIsCurrency0());
        console2.log("");
        console2.log("NEXT: run the post-deploy fork test against this address:");
        console2.log("  CHIP_LOTTERY=%s BASE_RPC_URL=... \\", address(l));
        console2.log("  forge test --match-contract ChipLotteryDeployedTest -vv");
        console2.log("");

        return address(l);
    }

    /// @dev Everything that can be known before spending gas.
    function _check(PoolKey memory key) internal view {
        // --- code where code must be ---------------------------------------
        require(SAFE.code.length > 0, "SAFE has no code - is it really the Safe?");
        require(CHIP.code.length > 0, "CHIP has no code");
        require(WETH.code.length > 0, "WETH has no code");
        require(USDC.code.length > 0, "USDC has no code");
        require(POOL_MANAGER.code.length > 0, "PoolManager has no code");
        require(V3_ROUTER.code.length > 0, "v3 router has no code");
        require(JACKPOT.code.length > 0, "Jackpot has no code");
        require(HOOK.code.length > 0, "hook has no code");

        /*
          THE REFERRER MUST BE ABLE TO CLAIM. A plain contract cannot - the fee
          accrues to the address and only that address can withdraw it, so naming a
          contract strands every fee for ever.

          It is not required to be bare, though: this address carries an EIP-7702
          delegation (23 bytes, 0xef0100 || implementation). That is still an account
          with a key behind it. Anything longer is a real contract and is refused.
        */
        uint256 refCode = REFERRER.code.length;
        require(refCode == 0 || refCode == 23, "referrer looks like a contract - fees would strand");

        // --- the Jackpot agrees with us ------------------------------------
        require(IJackpotCheck(JACKPOT).usdc() == USDC, "Jackpot quote token is not this USDC");
        uint256 price = IJackpotCheck(JACKPOT).ticketPrice();
        require(price == 1_000_000, "ticket is not $1 - re-read before deploying");

        // --- the pool named by the key is real and tradeable ---------------
        bytes32 poolId = keccak256(abi.encode(key));
        (uint160 sqrtPriceX96,,,) = IStateView(STATE_VIEW).getSlot0(poolId);
        require(sqrtPriceX96 != 0, "pool from this key is not initialised - the key is wrong");
        uint128 liq = IStateView(STATE_VIEW).getLiquidity(poolId);
        require(liq > 0, "pool has no liquidity");

        // --- key sanity -----------------------------------------------------
        require(key.currency0 < key.currency1, "v4 requires currency0 < currency1");
        require(key.currency0 == WETH && key.currency1 == CHIP, "key is not WETH/CHIP in order");

        console2.log("pre-flight OK: pool live, jackpot agrees, referrer claimable");
        console2.log("  poolId");
        console2.logBytes32(poolId);
        console2.log("  liquidity  %s", uint256(liq));
        console2.log("  ticket     %s micro-USDC", price);
    }
}
