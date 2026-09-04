# SITE_LOAN_API.md — the loan deadline UX, exactly as the contract exposes it

Everything the site needs to show a borrower when their loan matures, when it becomes
seizable, and what it costs to repay. **`GRACE_PERIOD` no longer exists** — it was a flat
`7 days` constant and the site must not assume one, because grace is now derived per term and
snapshotted per loan. Read it from the calls below.

Contract: `NounLoans`, `launch-candidate-8`. Terms at launch are 7 / 14 / 30 / 90 / 180 days
(`termIndex` 0–4) with fees of 0.5 / 1 / 2 / 5 / 9 %, a 2% liquidation bounty and a 1% late
fee.

---

## The five calls

```solidity
// ---- before borrowing -------------------------------------------------------
function graceFor(uint8 termIndex) external view returns (uint64 gracePeriodSeconds);
function quote(uint8 termIndex, uint256 principal)
    external view returns (uint256 fee, uint256 payout, uint64 dueAt, uint64 deadline);

// ---- after borrowing --------------------------------------------------------
function deadlineOf(uint256 loanId) external view returns (uint64 deadline);
function repayAmount(uint256 loanId) external view returns (uint256 principal, uint256 lateFee);
function isLiquidatable(uint256 loanId) external view returns (bool);
```

`getLoan(loanId)` returns the whole `Loan` struct, including `dueAt`, `gracePeriod`,
`lateFeeBps`, `principal`, `feePaid`, `termIndex`, `closed` and `liquidated`, if you would
rather read one struct than call four views.

## What each value means

| Value | Meaning | Units |
|---|---|---|
| `gracePeriodSeconds` | `min(7 days, term / 2)`. **3.5 days on the 7-day term**, 7 days on everything from 14 days up | seconds |
| `fee` | Origination fee, deducted from the disbursement | $CHIP wei |
| `payout` | What the borrower actually receives: `principal - fee` | $CHIP wei |
| `dueAt` | Maturity. **Not** the last moment to repay | unix seconds |
| `deadline` | `dueAt + gracePeriod`. Past this the loan is seizable **and** a late fee applies | unix seconds |
| `principal` | What repayment costs before any late fee — repayment is principal-only | $CHIP wei |
| `lateFee` | `0` before the deadline; `principal × lateFeeBps / 10000` after | $CHIP wei |

## The one behaviour that drives the UI

**Passing the deadline does not end the borrower's right to repay.** It opens liquidation and
starts a late fee. The loan ends when somebody actually calls `liquidate`, and until then the
borrower can still repay and get their Noun back. So a loan past its deadline is *a race, not
a loss* — show it as urgent, not as over.

`repayAmount` is the single call to drive the repay button: it returns `(principal, lateFee)`
and the sum is what the user must approve. `lateFee` flips from zero to its full value the
second the deadline passes; it is flat, not accruing, so it does not need re-polling for the
number to stay correct.

Three states worth rendering differently:

- **`now < deadline`** — normal. Show `dueAt` and `deadline` separately; on a 7-day loan they
  are only 3.5 days apart, so a single date is actively misleading.
- **`now >= deadline` and `isLiquidatable(loanId)`** — urgent. Still repayable, now costs
  `principal + lateFee`, and anyone may seize the Noun at any moment.
- **`getLoan(loanId).liquidated`** — over. The Noun is gone and the activation reset with it.

## Worked example, 7-day term, 1,000 $CHIP

```
quote(0, 1000e18)  -> fee 5e18, payout 995e18, dueAt T+7d, deadline T+10.5d
graceFor(0)        -> 302400          (3.5 days)

repayAmount(id) at T+6d     -> (1000e18, 0)          total 1000e18
repayAmount(id) at T+11d    -> (1000e18, 10e18)      total 1010e18
isLiquidatable(id) at T+11d -> true                  someone may seize it
```

## Don'ts

- **Don't hardcode 7 days of grace.** It is 3.5 on the shortest term, and every value is
  configurable behind a 48-hour timelock — read `graceFor` / `deadlineOf`.
- **Don't show `dueAt` as "repay by".** That is `deadline`.
- **Don't treat a past-deadline loan as closed.** Check `getLoan(loanId).liquidated`.
- **Don't compute the late fee client-side from `lateFeeBps`.** A live loan keeps the rate it
  was written with, so a terms change makes a client-side calculation wrong for existing
  loans. `repayAmount` already accounts for it.
