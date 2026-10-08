"""Mutation testing for src/raffle/Raffle.sol.

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
    ("settle: payee and Pot amounts swapped",
     "        _pushOrCreditUsdc(r.payee, payeeAmount);\n        _pushOrCreditUsdc(pot, potAmount);",
     "        _pushOrCreditUsdc(r.payee, potAmount);\n        _pushOrCreditUsdc(pot, payeeAmount);"),
    ("settle: liability not released",
     "        usdcLiability -= proceeds;\n",
     "\n"),
    ("settle: can settle twice",
     "        r.state = State.Settled;\n\n        address winner",
     "\n        address winner"),
    ("credit: liability not re-added",
     "        usdcOwed[to] += amount;\n        usdcLiability += amount;",
     "        usdcOwed[to] += amount;"),
    ("refused prize: escrow not restored",
     "            erc20PrizeEscrow[prize.token] += prize.amountOrId;\n            prizeOwedTo[raffleId] = winner;",
     "            prizeOwedTo[raffleId] = winner;"),
    ("tryRequest: ETH liability not reduced",
     "            r.ethReserve -= fee;\n            ethLiability -= fee;\n            _recordRequest",
     "            r.ethReserve -= fee;\n            _recordRequest"),
    ("create: not owner-only",
     "        onlyOwner\n        nonReentrant\n        returns (uint256 raffleId)",
     "        nonReentrant\n        returns (uint256 raffleId)"),
    ("prize: registry check removed",
     "            if (!registry.isEnabled(prize.token)) revert PrizeNotAllowed(prize.token);\n",
     "\n"),
    ("escrow: received amount not checked",
     "            if (received != prize.amountOrId) revert PrizeNotReceived(prize.amountOrId, received);\n",
     "\n"),
    ("withdrawUsdc: credit not zeroed (double pay)",
     "        usdcOwed[account] = 0;\n",
     "\n"),
    ("withdrawEth: credit not zeroed (double pay)",
     "        ethOwed[account] = 0;\n",
     "\n"),
    ("NFT kill switch ignored",
     "            if (!nftPrizesEnabled) revert NftPrizesDisabled();\n",
     "\n"),
    ("fee cap removed",
     "        if (newFeeBps > MAX_FEE_BPS) revert BadConfig();\n",
     "\n"),
    ("leftover reserve not credited",
     "            ethOwed[r.payee] += leftover; // liability unchanged: reserve becomes a credit\n",
     "\n"),
]

def main():
    original = SRC.read_bytes().decode("utf8")
    backup = SRC.with_suffix(".sol.orig")
    shutil.copy(SRC, backup)
    results = []
    try:
        for i, (name, a, b) in enumerate(MUTANTS, 1):
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
