# Circulation workflow

**Project:** ShelfSense
**Status:** Implemented in [db/002_circulation.sql](../db/002_circulation.sql) and verified
**Covers:** FR-03, FR-04, FR-05, FR-06, FR-07, QR-01, QR-02, QR-04

This document describes the issue and return operations added in migration
002. It records the behavior that was implemented and checked, not a plan.
The design it follows is section 4 of the
[Architecture Description](architecture-description.md).

## 1. Operations

Both operations are database functions. Each one does its whole job in the
caller's transaction, so a failure leaves no partial change (QR-01).

| Function | Purpose |
| --- | --- |
| `issue_copy(member_number, barcode, issued_on DEFAULT CURRENT_DATE)` | Issues one copy to one member. Returns the new `loan` row. |
| `return_copy(barcode, returned_on DEFAULT CURRENT_DATE)` | Records the return date on the open loan for a copy. Returns the closed `loan` row. |
| `loan_fine_as_of(loan_id, as_of_date DEFAULT CURRENT_DATE)` | Fine for one loan at a stated date, with currency and display text. |
| `format_minor_amount(amount_minor, currency_code, minor_digits)` | Renders a minor-unit amount for display. |
| `hold_permits_issue(copy_id, member_id)` | Hold rule evaluated during an issue. See section 5. |

`loan_fine_statement` is a view with one row per loan: borrower, title,
barcode, the three dates, the as-of date, the fine in minor units, and the
fine rendered with its currency.

The server layer calls these functions rather than writing to `loan`
directly. It still owns authentication and authorization (QR-03), which are
not part of this phase.

### Issuing

`issue_copy` runs these steps in one transaction:

1. Read the configured policy, failing if an administrator has not created it.
2. Lock the member row, then confirm the member exists and is active.
3. Lock the copy row, then confirm the copy exists and is not withdrawn.
4. Reject the issue if the copy already has an open loan.
5. Reject the issue if the member is at the configured open-loan limit.
6. Reject the issue if the hold rule does not permit it.
7. Insert the loan with `due_on = issued_on + loan_days` and a copy of the
   current `grace_days`, `fine_minor_per_day`, and `max_fine_minor`.

Step 7 is why a later policy change does not alter the fine owed on a loan
that already exists. The checked behavior is in
[db/verify_circulation.sql](../db/verify_circulation.sql).

### Returning

`return_copy` locks the copy row, then selects and locks that copy's open
loan. If no open loan exists it distinguishes a copy that was never issued
from one that has already been returned, so staff get a useful message. It
then sets `returned_on` once. The loan row is never deleted, so history
survives the return (FR-02, FR-06).

## 2. Locking and concurrency

Both functions take the copy row first among the rows they share, and only
`issue_copy` touches the member row. No pair of circulation transactions can
therefore acquire these locks in opposite orders, so they cannot deadlock
against each other.

Two consequences are worth stating plainly, because they were measured
rather than assumed:

- When two staff issue the same copy at once, the second transaction blocks
  on the copy row lock. Once the first commits, the second sees the
  committed open loan and reports `SS005` from its explicit check. It does
  not reach the unique index.
- A writer that bypasses `issue_copy` still cannot create a second open
  loan. `loan_one_open_per_copy_idx` rejects it with a unique violation.
  This is the guarantee QR-02 asks the database to make independently of the
  interface.

`issue_copy` therefore keeps a `unique_violation` handler that reports the
same `SS005` business failure. It is a backstop for any path that does not
take the copy row lock, not the usual route.

Both scenarios are checked by
[scripts/verify_concurrency.sh](../scripts/verify_concurrency.sh), which
runs two real psql sessions against one copy.

## 3. Business failure codes

Business failures use project SQLSTATE codes in class `SS`, so the server
layer can map a failure to a staff-readable message without parsing error
text. Anything outside class `SS` is a defect or an infrastructure fault,
not an expected outcome.

| Code | Meaning | Raised by |
| --- | --- | --- |
| `SS001` | No member with that member number | `issue_copy` |
| `SS002` | Member is not active | `issue_copy` |
| `SS003` | No copy with that barcode | `issue_copy`, `return_copy` |
| `SS004` | Copy has been withdrawn | `issue_copy` |
| `SS005` | Copy already has an open loan | `issue_copy` |
| `SS006` | Member is at the open-loan limit | `issue_copy` |
| `SS007` | An active hold prevents the issue | `issue_copy` |
| `SS008` | Copy is not on loan | `return_copy` |
| `SS009` | Copy has already been returned | `return_copy` |
| `SS010` | No circulation policy is configured | `issue_copy` |
| `SS011` | Return date precedes the issue date | `return_copy` |

## 4. Fines and their presentation

The fine rule itself is unchanged from the
[Database Design Description](database-design-description.md), section 4.
This phase adds how a fine is presented (QR-04).

- An **open** loan has no final answer, so every result carries the
  `as_of_date` it was computed for. `loan_fine_statement` states the current
  date; `loan_fine_as_of` takes the date as an argument, which also makes
  tests deterministic.
- A **returned** loan ignores the requested date and reports its return
  date, with `is_final` set. A final fine does not move afterwards.
- `days_past_due` and `chargeable_days` are reported separately, because a
  loan can be past due while still inside the grace period and owing
  nothing.
- Amounts are stored and compared as integer minor units. `fine_display`
  renders them with the configured currency, for example `INR 2.00`.

### Currency configuration

Migration 002 adds `currency_code` and `currency_minor_digits` to
`circulation_policy`. `currency_code` defaults to `XXX`, which ISO 4217
reserves for "no currency", because the library's currency is a deployment
decision and the project does not make it on their behalf. Set it with the
policy row:

```sql
UPDATE circulation_policy
SET currency_code = 'INR', currency_minor_digits = 2
WHERE policy_id = 1;
```

Mixed currencies are outside the first release (SRS section 4), so the code
lives on the single policy row rather than on every loan.

## 5. The hold rule

FR-11 places holds in a later phase, and no hold table exists yet.
`hold_permits_issue` is the point where that rule is evaluated: `issue_copy`
calls it inside its own transaction, after it has taken its row locks, and
it currently returns true for every caller. The holds phase replaces the
function body without moving where the rule runs or changing `issue_copy`.
`SS007` is reserved for that rejection and is unreachable today.

No speculative hold columns were added, in keeping with section 5 of the
Database Design Description.

## 6. Running the checks

Apply both migrations to a disposable database, then run the checks:

```sh
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/001_baseline.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/002_circulation.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/verify_baseline.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/verify_circulation.sql
sh scripts/verify_concurrency.sh shelfsense_test
```

`verify_circulation.sql` inserts its fixtures in a transaction and rolls
them back, so it prints nothing and succeeds quietly. The concurrency script
needs committed rows for two sessions to share; it cleans them up when it
passes and leaves them behind when it fails.

## 7. Requirement coverage

| Requirement | Evidence |
| --- | --- |
| FR-03 issue with policy snapshot | `issue_copy`; snapshot and policy-change checks in `verify_circulation.sql` |
| FR-04 reject issue of a copy on loan | `SS005` check, plus both scenarios in `verify_concurrency.sh` |
| FR-05 reject issue at the loan limit | `SS006` check in `verify_circulation.sql` |
| FR-06 return once, keep history | `return_copy`; repeat-return and date-stability checks |
| FR-07 fine from overdue days, grace, and cap | Boundary table in `verify_circulation.sql`: due date, last free day, first chargeable day, last day below the cap, cap reached, cap held |
| QR-01 atomic circulation writes | Rejected issues leave the loan count unchanged |
| QR-02 database-level integrity | Concurrent direct inserts rejected by `loan_one_open_per_copy_idx` |
| QR-04 unambiguous dates and amounts | `as_of_date`, `is_final`, and `fine_display` on `loan_fine_as_of` and `loan_fine_statement` |

QR-03 (server-side authorization) belongs to the application phase and is
not addressed here.
