"""Mutation testing for src/raffle/Raffle.sol (v2: the system buys the prize stock).  Optional range: mutation.py <first> <last> (1-based).

Each mutant is one targeted change to the source. For every mutant the raffle unit +
invariant suites must FAIL (mutant killed). A surviving mutant is a gap in the tests.
The original file is always restored, even on Ctrl-C.

    python tools/raffle/mutation.py            # all mutants
"""
import pathlib, shutil, subprocess, sys, time

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "src" / "raffle" / "Raffle.sol"
CMD = ["forge", "test", "--match-path", "test/raffle/*.sol"]

MUTANTS = [
    # ---------------- tickets, buy, draw, settle, credits (carried from v1.2) ----------------
    ("fee tickets round DOWN instead of up",
     "return base + uint64((uint256(base) * fee + BPS - 1) / BPS);",
     "return base + uint64((uint256(base) * fee) / BPS);"),
    ("buy: cannot buy the exact remainder",
     "if (quantity > remaining) revert NotEnoughTickets",
     "if (quantity >= remaining) revert NotEnoughTickets"),
    ("buy: liability not increased",
     "        usdcLiability += cost;\n",
     "\n"),
    ("binary search boundary > -> >=",
     "if (p[mid].endExclusive > ticket) hi = mid;",
     "if (p[mid].endExclusive >= ticket) hi = mid;"),
    ("winning index modulo N-1",
     "uint64 winningTicket = uint64(uint256(randomNumber) % r.totalTickets);",
     "uint64 winningTicket = uint64(uint256(randomNumber) % (r.totalTickets - 1));"),
    ("callback: anyone can call it",
     "        if (msg.sender != entropy) revert OnlyEntropy();\n        bytes32 key",
     "        bytes32 key"),
    # EQUIVALENT by construction: _raffleOfRequest[key] exists only while that raffle is Drawing
    # with that (provider, sequence) — it is deleted on delivery and on retry — so a stale or
    # duplicate delivery already returns as an orphan before this defensive check runs.
    ("EQUIVALENT callback: stale/duplicate delivery not ignored",
     "if (r.state != State.Drawing || r.sequence != sequence || r.provider != provider) {",
     "if (r.sequence != sequence || r.provider != provider) {"),
    ("retryDraw: allowed after a FAILED callback (re-roll)",
     "if (req.sequenceNumber != r.sequence || req.callbackStatus != CALLBACK_NOT_STARTED) {",
     "if (req.sequenceNumber != r.sequence) {"),
    ("retryDraw: timeout boundary < -> <=",
     "if (block.timestamp < readyAt) revert RedrawNotReady",
     "if (block.timestamp <= readyAt) revert RedrawNotReady"),
    ("settle: USDC prize not released from liability",
     "usdcLiability -= potAmount + (prize.kind == PrizeKind.Usdc ? prize.amount : 0);",
     "usdcLiability -= potAmount;"),
    ("settle: can settle twice",
     "        r.state = State.Settled;\n\n        address winner",
     "\n        address winner"),
    ("settle: Pot gets the prize budget instead of the fee",
     "uint256 potAmount = (uint256(r.totalTickets) - r.base) * TICKET_PRICE;",
     "uint256 potAmount = uint256(r.base) * TICKET_PRICE;"),
    ("credit: liability not re-added",
     "        usdcOwed[to] += amount;\n        usdcLiability += amount;",
     "        usdcOwed[to] += amount;"),
    ("refused prize: escrow not restored",
     "        erc20PrizeEscrow[prize.token] += prize.amount;\n        prizeOwedTo[raffleId] = winner;",
     "        prizeOwedTo[raffleId] = winner;"),
    ("tryRequest: ETH liability not reduced",
     "            r.ethReserve -= fee;\n            ethLiability -= fee;\n            _recordRequest",
     "            r.ethReserve -= fee;\n            _recordRequest"),
    ("create: not owner-only",
     "function createRaffle(address stock, uint64 base) external payable onlyOwner nonReentrant",
     "function createRaffle(address stock, uint64 base) external payable nonReentrant"),
    ("withdrawUsdc: credit not zeroed (double pay)",
     "        usdcOwed[account] = 0;\n",
     "\n"),
    ("withdrawEth: credit not zeroed (double pay)",
     "        ethOwed[account] = 0;\n",
     "\n"),
    ("fee cap removed",
     "        if (newFeeBps > MAX_FEE_BPS) revert BadConfig();\n",
     "\n"),
    ("leftover reserve not credited to the creator",
     "            ethOwed[r.creator] += leftover; // liability unchanged: reserve becomes a credit\n",
     "\n"),
    # ---------------- Entropy seed / retry access (review round 1) ----------------
    ("seed: non-reverting request WITHOUT the user seed",
     "try e.requestV2{value: fee}(provider, seed, gasLimit)",
     "try e.requestV2{value: fee}(provider, gasLimit)"),
    ("seed: requestDraw/retry request WITHOUT the user seed",
     "uint64 sequence = e.requestV2{value: fee}(provider, seed, gasLimit);",
     "uint64 sequence = e.requestV2{value: fee}(provider, gasLimit);"),
    ("seed: nonce not advanced",
     "                ++_drawNonce,",
     "                _drawNonce,"),
    ("seed: last buyer not mixed in",
     "                p[p.length - 1].buyer,",
     "                address(0),"),
    ("acquirePrize: open to anyone",
     "function acquirePrize(uint256 raffleId) external onlyOwnerOrKeeper nonReentrant {",
     "function acquirePrize(uint256 raffleId) external nonReentrant {"),
    ("retryDraw: open to anyone",
     "function retryDraw(uint256 raffleId) external payable onlyOwnerOrKeeper nonReentrant {",
     "function retryDraw(uint256 raffleId) external payable nonReentrant {"),
    ("owner/keeper gate: keeper not allowed",
     "if (msg.sender != owner() && msg.sender != keeper) revert NotAuthorized",
     "if (msg.sender != owner()) revert NotAuthorized"),
    ("setKeeper: not owner-only",
     "    function setKeeper(address newKeeper) external onlyOwner {",
     "    function setKeeper(address newKeeper) external {"),
    ("redraw timeout: not snapshotted at creation",
     "        r.redrawTimeout = redrawTimeout;\n",
     "\n"),
    ("redraw timeout: retry reads the live global",
     "uint64 readyAt = r.drawRequestedAt + r.redrawTimeout;",
     "uint64 readyAt = r.drawRequestedAt + redrawTimeout;"),
    ("tryTransfer: back to '>= 32 bytes and decode bool'",
     "        if (ret.length == 32) return abi.decode(ret, (uint256)) == 1;\n        return false;",
     "        return ret.length >= 32 && abi.decode(ret, (bool));"),
    ("tryTransfer: any non-zero word counts as success",
     "return abi.decode(ret, (uint256)) == 1;",
     "return abi.decode(ret, (uint256)) != 0;"),
    # EQUIVALENT by construction: setBaseLimits refuses minBase == 0 and the default is 10.
    ("EQUIVALENT create: explicit base == 0 check removed",
     "if (base == 0 || base < minBase || base > maxBase)",
     "if (base < minBase || base > maxBase)"),
    # ---------------- v2: create-time stock validation ----------------
    ("create: TWAP availability not checked",
     "        if (!twapOk) revert StockNotBuyable(stock, Refusal.TwapUnavailable);\n",
     "\n"),
    ("create: pool-share cap not checked",
     "        if (uint256(base) * TICKET_PRICE > _poolCap(pool, g.maxPoolShareBps)) {",
     "        if (false) {"),
    ("poolFor: registry pool not checked against the router's factory",
     "if (pool == address(0) || ISlipstreamFactory(factory).getPool(address(usdc), stock, spacing) != pool) {",
     "if (pool == address(0)) {"),
    ("poolFor: token pair not checked",
     "if (!((t0 == address(usdc) && t1 == stock) || (t0 == stock && t1 == address(usdc)))) {",
     "if (false) {"),
    ("poolFor: tick spacing not checked",
     "if (ISlipstreamPool(pool).tickSpacing() != spacing) return (Refusal.PoolMismatch, address(0), 0);",
     "if (false) return (Refusal.PoolMismatch, address(0), 0);"),
    ("poolFor: disabled stocks accepted",
     "if (!s.registered || !s.enabled) return (Refusal.StockDisabled, address(0), 0);",
     "if (!s.registered) return (Refusal.StockDisabled, address(0), 0);"),
    ("constructor: router factory not checked against the registry",
     "if (factory_ == address(0) || factory_ != IStockRegistry(registry_).slipstreamFactory()) revert BadConfig();",
     "if (factory_ == address(0)) revert BadConfig();"),
    ("constructor: USDC not checked against the registry quote",
     "        if (IStockRegistry(registry_).quoteToken() != usdc_) revert BadConfig();\n",
     "\n"),
    # ---------------- v2: sellout + acquire ----------------
    ("buy: sellout time not recorded",
     "            r.soldOutAt = uint64(block.timestamp);\n",
     "\n"),
    ("acquire: re-pointed pool not refused",
     "        if (pool != r.pool) revert AcquireRefused(raffleId, Refusal.PoolMismatch);\n",
     "\n"),
    ("acquire: pool-share cap not re-checked",
     "if (budget > _poolCap(pool, g.maxPoolShareBps)) revert AcquireRefused(raffleId, Refusal.TooLargeForPool);",
     "if (false) revert AcquireRefused(raffleId, Refusal.TooLargeForPool);"),
    ("acquire: manipulation guard removed",
     "if (_absDiff(spotTick, twapTick) > g.maxDeviationTicks) revert AcquireRefused(raffleId, Refusal.SpotDeviates);",
     "if (false) revert AcquireRefused(raffleId, Refusal.SpotDeviates);"),
    ("acquire: manipulation guard boundary > -> >=",
     "if (_absDiff(spotTick, twapTick) > g.maxDeviationTicks) revert AcquireRefused(raffleId, Refusal.SpotDeviates);",
     "if (_absDiff(spotTick, twapTick) >= g.maxDeviationTicks) revert AcquireRefused(raffleId, Refusal.SpotDeviates);"),
    ("acquire: no slippage margin (floor = reference)",
     "minOut = (refOut * (BPS - g.maxSlippageBps)) / BPS;",
     "minOut = refOut;"),
    ("acquire: floor ignores the TWAP (spot only)",
     "        if (k >= 0) return Math.mulDiv(spotOut, _tickPowWad(uint256(k)), WAD);",
     "        if (k >= 0) return spotOut;"),
    ("TWAP direction flipped",
     "int256 k = int256(twapTick) - int256(spotTick);",
     "int256 k = int256(spotTick) - int256(twapTick);"),
    ("token order ignored (stock as token0)",
     "        if (!usdcIsToken0) k = -k;\n",
     "\n"),
    ("TWAP mean truncates instead of flooring",
     "            if (delta < 0 && delta % w != 0) mean--;\n",
     "\n"),
    ("tick power: base off by one tick step",
     "uint256 internal constant TICK_BASE_WAD = 1.0001e18;",
     "uint256 internal constant TICK_BASE_WAD = 1.0002e18;"),
    ("swap: partial spend accepted",
     "        if (spent != budget) revert AcquireRefused(raffleId, Refusal.PartialSpend);\n",
     "\n"),
    ("swap: under-delivery accepted",
     "        if (received < minOut) revert AcquireRefused(raffleId, Refusal.UnderDelivered);\n",
     "\n"),
    # EQUIVALENT by construction: the approval is exactly `budget`, the router's transferFrom of
    # exactly `budget` brings it to zero, and every other outcome (partial spend, router revert,
    # under-delivery) reverts the whole call, approval included. The reset is defence in depth.
    ("EQUIVALENT swap: approval not reset",
     "        usdc.forceApprove(address(router), 0);\n",
     "\n"),
    ("acquire: liability not reduced by the spend",
     "        usdcLiability -= spent;\n",
     "\n"),
    ("acquire: bought stock not escrowed",
     "        erc20PrizeEscrow[r.stock] += received;\n",
     "\n"),
    ("acquire: no PrizeReady when the draw can't be requested",
     "        r.state = State.PrizeReady;\n        emit PrizeAcquired",
     "        emit PrizeAcquired"),
    # ---------------- v2: fallback ----------------
    ("fallback: acquire timeout not snapshotted",
     "        r.acquireTimeout = acquireTimeout;\n",
     "\n"),
    ("fallback: reads the live global timeout",
     "uint64 readyAt = r.soldOutAt + r.acquireTimeout;",
     "uint64 readyAt = r.soldOutAt + acquireTimeout;"),
    ("fallback: timeout boundary < -> <=",
     "if (block.timestamp < readyAt) revert AcquireTimeoutNotReached",
     "if (block.timestamp <= readyAt) revert AcquireTimeoutNotReached"),
    ("fallback: USDC prize is the whole ticket take",
     "        uint256 prize = uint256(r.base) * TICKET_PRICE;\n        r.prize = Prize",
     "        uint256 prize = uint256(r.totalTickets) * TICKET_PRICE;\n        r.prize = Prize"),
    ("fallback: no PrizeReady when the draw can't be requested",
     "        r.state = State.PrizeReady;\n        emit PrizeFellBackToUsdc",
     "        emit PrizeFellBackToUsdc"),
    # ---------------- v2: owner bounds ----------------
    ("price guard: deviation bound removed",
     "|| g.maxDeviationTicks > MAX_DEVIATION_TICKS",
     ""),
    ("price guard: zero slippage allowed",
     "|| g.maxSlippageBps == 0",
     ""),
    ("acquire timeout: upper bound removed",
     "if (timeout < MIN_ACQUIRE_TIMEOUT || timeout > MAX_ACQUIRE_TIMEOUT) revert BadConfig();\n        acquireTimeout",
     "if (timeout < MIN_ACQUIRE_TIMEOUT) revert BadConfig();\n        acquireTimeout"),
]

def main():
    original = SRC.read_bytes().decode("utf8")
    backup = SRC.with_suffix(".sol.orig")
    shutil.copy(SRC, backup)
    results = []
    try:
        lo = int(sys.argv[1]) if len(sys.argv) > 1 else 1
        hi = int(sys.argv[2]) if len(sys.argv) > 2 else len(MUTANTS)
        for i, (name, a, b) in enumerate(MUTANTS, 1):
            if i < lo or i > hi:
                continue
            if original.count(a) != 1:
                results.append((name, "SKIPPED: pattern not unique (%d)" % original.count(a)))
                print(f"[{i}/{len(MUTANTS)}] {name}: pattern not found", flush=True)
                continue
            SRC.write_bytes(original.replace(a, b).encode("utf8"))
            t = time.time()
            p = subprocess.run(CMD, cwd=ROOT, capture_output=True, text=True, encoding="utf8", errors="replace")
            out = p.stdout + p.stderr
            if "Compiler run failed" in out or "Error (" in out:
                verdict = "COMPILE ERROR (invalid mutant)"
            elif p.returncode != 0:
                verdict = "KILLED"
            else:
                verdict = "SURVIVED"
            results.append((name, verdict))
            print(f"[{i}/{len(MUTANTS)}] {verdict:9s} {name} ({time.time() - t:.0f}s)", flush=True)
    finally:
        SRC.write_bytes(original.encode("utf8"))
        backup.unlink(missing_ok=True)
    equivalent = [n for n, v in results if n.startswith("EQUIVALENT") and v == "SURVIVED"]
    results = [(n, v) for n, v in results if not (n.startswith("EQUIVALENT") and v == "SURVIVED")]
    killed = sum(1 for _, v in results if v == "KILLED")
    ran = sum(1 for _, v in results if v in ("KILLED", "SURVIVED"))
    for n in equivalent:
        print(f"  equivalent (survives by construction, documented): {n}")
    print(f"\nRESULT: {killed}/{ran} mutants killed")
    for n, v in results:
        if v != "KILLED":
            print(f"  NOT KILLED: {n}: {v}")
    sys.exit(0 if killed == ran else 1)

if __name__ == "__main__":
    main()
