# Discovery and reporting

**Project:** ShelfSense
**Status:** Implemented in [db/003_discovery.sql](../db/003_discovery.sql), [db/004_holds.sql](../db/004_holds.sql), and [db/005_reports.sql](../db/005_reports.sql), and verified
**Covers:** FR-08, FR-09, FR-10, FR-11

This document describes the catalog search, copy availability, hold
queue, and operational reports added in migrations 003 to 005. It
records behavior that was implemented and checked, not a plan. The
circulation operations it builds on are in the
[Circulation workflow](circulation-workflow.md), and the measured cost
of everything here is in [Query performance](query-performance.md).

## 1. Operations

| Function or view | Purpose |
| --- | --- |
| `copy_availability` | One row per copy: available, on loan, or withdrawn |
| `title_availability` | One row per title with its authors and copy counts |
| `title_copy_counts(book_id)` | Copy counts by availability for one title |
| `title_authors(book_id)` | Credited authors of one title as a display string |
| `search_titles(query, limit, offset)` | Titles matching a query by ISBN, title, or author |
| `search_isbn13(query)` | The ISBN a query denotes, or NULL |
| `search_tsquery(query)` | The text-search query a staff string denotes |
| `place_hold(member_number, book_id)` | Adds one active hold on a title |
| `cancel_hold(hold_id)` | Marks one active hold cancelled, keeping the row |
| `hold_queue` | Active holds with their position in each title's queue |
| `hold_permits_issue(copy_id, member_id)` | The hold rule evaluated during an issue |
| `overdue_loans_as_of(as_of)` | Open loans past due at a stated date |
| `overdue_loans` | The same, as of the current date |
| `circulation_summary_by_title(from, to)` | Loans per title in a period |
| `circulation_summary_by_month(from, to)` | Loans per month, plus the period total |

Everything in this phase reads, except `place_hold`, `cancel_hold`, and
the fulfillment step added to `issue_copy`. The server layer still owns
authentication and authorization (QR-03), which are not part of this
phase.

## 2. Availability and search

### Availability is derived

A copy is **withdrawn** if it has a withdrawal date, **on loan** if it
has an open loan, and **available** otherwise. The states are checked in
that order, the same order `issue_copy` checks them, so a copy withdrawn
while a borrower still has it reads as withdrawn rather than as
lendable. `copy_availability` still exposes `open_loan_id` for that
case, so the loan is not hidden, and the overdue report reads `loan`
directly and still lists it.

Nothing is stored. Section 6 of the
[Architecture Description](architecture-description.md) rejects a second
mutable status column that could disagree with loan history, so every
answer is computed from `copy` and `loan` at read time.
`title_availability` adds up those states per title and reports
`next_due_on`, the earliest due date among the title's open loans, which
is the date staff quote to somebody asking when a copy will be back.

### What a search does

`search_titles` runs three indexed lookups and merges them:

1. **ISBN.** An exact match on `isbn13`. A query counts as an ISBN only
   when it contains nothing but digits, spaces, and hyphens and carries
   exactly thirteen digits, so `978-0-13-235088-4` works and a title
   that happens to contain digits is never mistaken for one.
2. **Title.** A full-text match on the title.
3. **Author.** A full-text match on a credited author's name, which then
   returns that author's titles.

A title found more than one way appears once, labelled with the
strongest reason it matched: `matched_on` is `isbn`, then `title`, then
`author`. Results carry the same availability columns as
`title_availability`, because the question behind a catalog search is
usually whether a copy is on the shelf.

### Search behavior, stated exactly

These are the answers the acceptance criteria for FR-09 asked to have
written down, and each one is checked in
[db/verify_discovery.sql](../db/verify_discovery.sql).

- **Blank input matches nothing.** An empty string, whitespace, or
  punctuation alone produces no searchable token and therefore no rows.
  It deliberately does not fall back to listing the catalog: staff
  browse through `title_availability`, so a mis-keyed search cannot
  quietly return twenty thousand rows.
- **Partial input matches by prefix.** Every token is a prefix term, so
  `algor` finds *Introduction to Algorithms* and `clean cod` finds
  *Clean Code*.
- **Every token must match.** `database concepts` finds *Database System
  Concepts*; `database algorithms` finds nothing rather than falling
  back to either word. Token order does not matter.
- **Case does not matter**, in either a title or an author search.
- **A partial ISBN is not an ISBN.** `978013235` has no exact match to
  make, so it returns nothing rather than guessing at a prefix.
- **Stop words are searchable.** The `simple` text-search configuration
  is used rather than `english`, so nothing is discarded as too common
  and nothing is stemmed. *The Idiot* and *It* stay findable, which an
  `english` configuration would not guarantee, and prefix matching
  covers most of what stemming would have given: `algorithm` still
  finds *Algorithms*. The cost is that `run` does not find *running*.

## 3. The hold queue

A hold is placed on a **title**, not a copy. A member waits for the
work, and any copy of it satisfies the wait.

### States

A hold is `active`, `canceled`, or `fulfilled`, and rows are never
deleted, so the queue keeps its history. A check constraint ties each
state to exactly the columns that belong to it: an active hold cannot
carry a cancellation time, and a fulfilled hold cannot exist without
naming the loan that fulfilled it. `fulfilled_loan_id` is what makes
fulfillment auditable after the fact.

A member cannot hold the same title twice at once. That is
`hold_one_active_per_member_title_idx`, a partial unique index on
`(book_id, member_id) WHERE status = 'active'` — the same idiom as the
one-open-loan-per-copy rule, and authoritative in the same way, so a
race between two staff ends as a business failure rather than as a
duplicate row. Because the index is partial, a cancelled or fulfilled
hold does not prevent the member from queueing again.

### Request order

Queue position is `ORDER BY placed_at, hold_id`, with `hold_id` breaking
any tie so the order is total and stable. `placed_at` defaults to
`clock_timestamp()` rather than `now()`, so two holds placed inside one
transaction still differ. Both values are assigned when the row is
inserted, not when it commits, so the order is the order the holds were
made, which is what a member would expect.

### The rule

A hold reserves one available copy for the member waiting. The rule is
therefore a comparison of counts, not a veto by any hold at all:

> An issue is permitted when `copies_available > holds_ahead`.

`holds_ahead` counts the active holds in front of this member, or every
active hold when the member has no place in the queue.
`copies_available` counts the title's copies that are neither withdrawn
nor on an open loan, which still includes the copy about to be issued,
because its loan does not exist yet.

Two consequences are deliberate:

- **A walk-in borrower is refused only when taking the copy would leave
  somebody in the queue without one.** Three copies free and one member
  waiting still serves a walk-in. One copy free and one member waiting
  does not, and the walk-in is told so with `SS007`.
- **A hold becomes fulfillable only once a copy remains for every hold
  ahead of it**, so no hold loses its place to a later one. The second
  member in a queue may legitimately borrow while the first is still
  waiting, but only when a copy is left over for the first.

A copy is handed to the member at the front of the queue by issuing it
to them in the ordinary way. `issue_copy` then marks their active hold
for that title `fulfilled` and points it at the new loan.

### Returns do not fulfill holds

Returning a copy makes it available, and the hold rule then reserves it
for whoever is waiting, but no hold changes state on a return. The
project has no way to notify a member that a copy is ready, so
automatically assigning a returned copy to a hold would record a
fulfillment nobody acted on. Fulfillment happens at issue, where a real
copy changes hands. `return_copy` is unchanged by this phase.

### Locking

Migration 004 adds one lock to `issue_copy`: the title's `book` row,
taken between the member row and the copy row. The hold rule compares
two counts, so without it two staff could both read "there is a copy to
spare" and between them leave a queued member with nothing.

The resulting order across every circulation operation is

> `member` → `book` → `copy` → `loan` → `hold`

and each operation takes a prefix or subset of it in that order:
`issue_copy` takes all five, `place_hold` takes the member row and then
the book row, `cancel_hold` takes the book row and then the hold row,
and `return_copy` takes the copy row and then the loan row. No two can
therefore acquire locks in opposite orders, which was checked in both
directions for each pair.

`place_hold` takes only a share lock on the member row, because it reads
that row and does not depend on counting the member's own activity.
`issue_copy` needs an exclusive lock there because it counts that
member's open loans against the loan limit.

Holding the `book` row also means the fulfillment step does not need to
lock the hold row separately: every operation that changes a title's
queue already holds that title's book row.

### What the database does not guarantee

The locking above protects the queue against anything that goes through
`issue_copy`. It does not protect it against a writer that does not.

This is weaker than the guarantee the one-open-loan rule has, and the
difference is worth being explicit about. A direct `INSERT` into `loan`
that bypasses `issue_copy` still cannot create a second open loan for a
copy, because `loan_one_open_per_copy_idx` rejects it — that is what
QR-02 asks the database to enforce independently of the interface, and
[scripts/verify_concurrency.sh](../scripts/verify_concurrency.sh)
measures it. The hold rule has no such backstop. It compares a count of
free copies against a count of waiting members, and no unique index or
check constraint can express a rule about two aggregates over two
tables, so a writer that inserts a loan directly can take the copy a
queued member was waiting for, and nothing in the schema will stop it.

Both partial unique indexes on `hold` keep working in that situation: a
member still cannot end up with two active holds on one title, and the
history stays consistent. What is lost is only the allocation rule.

That places the hold rule on the same footing as the open-loan limit,
which is also enforced by `issue_copy` rather than by a constraint. The
consequence for the application phase is the one already recorded in the
[Architecture Description](architecture-description.md): the server layer
writes circulation through these functions and does not write to `loan`
itself.

### What migration 002 reserved, and what changed

Migration 002 created `hold_permits_issue` as the point where the hold
rule would be evaluated, reserved `SS007` for its rejection, and said
the holds phase would replace the function body without changing
`issue_copy`. The rule did land in that function, and `SS007` is now
reachable, but `issue_copy` did change, in two ways that the earlier
note did not anticipate:

- It takes the `book` row lock described above.
- It marks the member's hold fulfilled after inserting the loan. The
  rule function could not do this: it is `STABLE`, and it runs before
  the loan it would have to point at exists.

The decision point did not move. The fulfillment step is new.

## 4. Reports

Every report takes its dates as arguments so a result can be
reproduced, and the views that wrap them state `CURRENT_DATE` — the same
pairing as `loan_fine_as_of` and `loan_fine_statement` in migration 002.

### The overdue worklist

`overdue_loans_as_of(as_of)` lists the open loans whose due date is past
the stated date, oldest first, with the borrower, the title, and the
fine so far. The grace period is not part of the overdue test, so a loan
can appear owing nothing; `days_past_due` and `chargeable_days` are
reported separately for exactly that reason.

One limit is worth stating plainly. This is a worklist of loans that are
**still open now** and were already past due at the stated date. It is
not a reconstruction of what was overdue on a past date: a loan that was
overdue in September and has since come back does not appear, whatever
date is asked for. Asking for an earlier date narrows today's worklist;
it does not rewind it.

### Circulation summaries

A loan belongs to the period in which it was issued. Both summaries
select on `issued_on`, so a loan is counted once, in the period it left
the shelf.

`circulation_summary_by_title(from, to)` gives one row per title: loans
issued, distinct borrowers, how many came back, how many are still out,
the average days held among those returned, the fines, and that title's
share of the period's loans. The share is a window aggregate over the
grouped rows, so it divides by the report's own total without a second
pass over `loan`.

`circulation_summary_by_month(from, to)` groups by issue month and adds
the period total as one extra row, through `GROUP BY ROLLUP`.
`GROUPING()` marks that row as `is_period_total` with a NULL
`period_month`, so staff and tests can tell it from a month without
summing the report by hand. Its `distinct_members` and `distinct_titles`
count across the whole period rather than adding up the months, which is
the answer the question actually wants.

A period with no loans returns no rows from either report. ROLLUP would
otherwise produce its grand-total group regardless, reporting a quiet
month as one row of zeroes.

A fine on a loan still open at the end of the period is computed as of
the period's end date, which is what keeps a closed period's report
stable.

## 5. Business failure codes

This phase adds four codes to the class `SS` scheme described in the
[Circulation workflow](circulation-workflow.md), section 3, and makes
`SS007` reachable. `place_hold` reuses `SS001` and `SS002` rather than
inventing its own codes for the same two conditions.

| Code | Meaning | Raised by |
| --- | --- | --- |
| `SS001` | No member with that member number | `issue_copy`, `place_hold` |
| `SS002` | Member is not active | `issue_copy`, `place_hold` |
| `SS007` | An active hold prevents the issue | `issue_copy` |
| `SS012` | No title with that `book_id` | `place_hold` |
| `SS013` | Member already has an active hold on that title | `place_hold` |
| `SS014` | No hold with that id | `cancel_hold` |
| `SS015` | Hold is not active | `cancel_hold` |

`place_hold` identifies a title by `book_id` rather than by ISBN,
because `isbn13` is optional in the baseline schema and a title without
one still needs to be holdable.

## 6. Running the checks

Apply the migrations to a disposable database, then run the checks:

```sh
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/001_baseline.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/002_circulation.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/003_discovery.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/004_holds.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/005_reports.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/verify_discovery.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/verify_holds.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/verify_reports.sql
sh scripts/verify_hold_concurrency.sh shelfsense_test
```

The three SQL files insert fixtures in a transaction and roll them back,
so they succeed quietly and print nothing. They assume a fresh test
database with no existing records. The concurrency script needs
committed rows for two sessions to share; it cleans them up when it
passes and leaves them in place when it fails.

`verify_reports.sql` is built on six loans with fixed dates, listed in a
table at the top of the file, so every total it checks is a
hand-computed number rather than whatever the query returned.

Query plans are measured separately, against a much larger dataset:

```sh
psql -X -v ON_ERROR_STOP=1 -d shelfsense_perf -f db/perf_dataset.sql
sh scripts/measure_query_plans.sh shelfsense_perf
```

## 7. Requirement coverage

| Requirement | Evidence |
| --- | --- |
| FR-08 availability from copies, withdrawal, and open loans | `copy_availability`, `title_availability`; state table and the issue/return/withdraw sequence in `verify_discovery.sql` |
| FR-09 search by title, author, or ISBN | `search_titles`; title, author, ISBN, blank, partial, and multi-token cases in `verify_discovery.sql` |
| FR-09 indexes justified by query plans | Four indexes measured with and without, and one proposed index rejected, in [Query performance](query-performance.md), section 3 |
| FR-10 overdue list and circulation summaries | `overdue_loans_as_of`, `circulation_summary_by_title`, `circulation_summary_by_month` |
| FR-10 totals match fixture data | Six-loan fixture in `verify_reports.sql`; every count, average, share, and ROLLUP total asserted against a hand-computed value |
| FR-10 joins, grouping, and an advanced feature | `FILTER` aggregates, `count(DISTINCT …)`, a window aggregate for the per-title share, and `GROUP BY ROLLUP` with `GROUPING()` for the period total |
| FR-10 measured plans with dataset size | [Query performance](query-performance.md), sections 1 and 2 |
| FR-11 hold states and duplicate prevention | `hold` table constraints and `hold_one_active_per_member_title_idx`; `SS013` and the constraint checks in `verify_holds.sql` |
| FR-11 fulfillment in request order | `hold_permits_issue` and the fulfillment step in `issue_copy`; queue-order and front-of-queue checks in `verify_holds.sql` |
| FR-11 request order under concurrent activity | Two scenarios in [scripts/verify_hold_concurrency.sh](../scripts/verify_hold_concurrency.sh): competing walk-ins cannot over-allocate a queued title, and a walk-in racing a queued member is refused |
| FR-11 cancellation and fulfillment preserve history | Hold rows are updated, never deleted; status counts, `fulfilled_loan_id` cross-checks, and re-queueing after cancellation in `verify_holds.sql` |

QR-03 (server-side authorization) belongs to the application phase and
is not addressed here.
