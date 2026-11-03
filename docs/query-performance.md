# Query performance

**Project:** ShelfSense
**Status:** Measured against the representative dataset
**Covers:** FR-08, FR-09, FR-10, FR-11, and the deferred indexing decision in QR-05

This document records what the discovery, hold, and reporting queries
actually cost, and which indexes earned their place. Section 5 of the
[Software Requirements Specification](software-requirements-specification.md)
declines to assert a response-time target before a representative dataset
exists, and section 5 of the
[Database Design Description](database-design-description.md) defers
search indexes until that workload is defined. This is that measurement.

Every number here was produced by
[scripts/measure_query_plans.sh](../scripts/measure_query_plans.sh) and
can be reproduced; none of it is estimated.

## 1. What was measured, and on what

The dataset is [db/perf_dataset.sql](../db/perf_dataset.sql). It contains
no random values: every row comes from arithmetic on `generate_series`,
so the same database is rebuilt each time.

| Relation | Rows |
| --- | --- |
| Titles (`book`) | 20,000 |
| Authors (`author`) | 8,000 |
| Title-author links (`book_author`) | 29,995 |
| Copies (`copy`) | 45,000, of which 900 withdrawn |
| Members (`member`) | 6,000 |
| Loans (`loan`) | 150,000, of which 5,000 open |
| Holds (`hold`) | 4,000, of which 3,000 active |
| Database size | 44 MB |

This is one library's scale over roughly three years of circulation, not
a stress test. Numbers from it do not support any claim about a larger
deployment.

Measurements were taken on PostgreSQL 17.6 (x86_64-windows) with the
default `shared_buffers` of 128MB and `work_mem` of 4MB, on one
developer machine. Absolute timings depend on that machine and should be
read as relative, not as a service-level target. Buffer counts are the
more portable figure, so both are reported.

Three things about the method matter:

- Each query runs twice and the second run is the one reported. The
  first run warms the shared buffers; without it the numbers describe
  reading the dataset from disk for the first time.
- Where an index is the point of the comparison, the alternative was
  measured by dropping **that one index** inside a transaction that is
  then rolled back, rather than by switching off index scans in general.
  Otherwise the comparison also removes every other index the query
  uses, and overstates the one being judged. One index the project
  decided *not* to add is measured the same way in reverse: it is
  created inside a transaction that is rolled back, so the decision to
  leave it out stays reproducible.
- **Buffer counts are the evidence; timings are indicative.** Repeating
  the whole run on an otherwise idle machine reproduced every buffer
  count exactly, while timings moved by a few per cent on short queries
  and by considerably more on longer ones: one comparison measured
  42 ms, 45 ms and 66 ms across three runs of the identical query and
  dataset. Conclusions below rest on buffers and on which plan the
  planner chose, not on a stopwatch.

## 2. Results

Buffers are the root node's shared-buffer hits. Rows are the rows
returned.

| Query | Rows | Buffers | Time |
| --- | --- | --- | --- |
| Availability of one copy by barcode | 1 | 5 | 0.16 ms |
| Queue for one title | 3 | 26 | 0.16 ms |
| ISBN search, exact match | 1 | 54 | 0.55 ms |
| Author search, one rare author | 2 | 72 | 0.55 ms |
| Title search, selective term | 4 | 107 | 0.65 ms |
| Availability of one title | 1 | 150 | 2.54 ms |
| The hold rule for one issue decision | 1 | 448 | 11.21 ms |
| Overdue worklist at a stated date | 4,391 | 687 | 20.19 ms |
| Catalog browse, one page of 50 titles | 50 | 931 | 4.74 ms |
| Circulation by month, full history with ROLLUP | 35 | 1,900 | 182.47 ms |
| Circulation by title, one month | 5,171 | 2,375 | 38.05 ms |
| Circulation by title, full history | 20,000 | 2,375 | 209.44 ms |
| Title search, two prefix tokens | 50 | 2,239 | 3.47 ms |
| Title search, unselective term (a tenth of the catalog) | 50 | 18,551 | 22.07 ms |
| Catalog browse, every title at once | 20,000 | 340,343 | 204.43 ms |

Staff-facing lookups — a barcode, one title's availability, one title's
queue, a selective search — read at most a few hundred buffers. The
reports read thousands, because they aggregate three years of
circulation; that is inherent to what they answer, not a missing index.

Two entries deserve a word. A search for a term carried by a tenth of
the catalog reads 18,551 buffers to return fifty rows, because the GIN
index still has to produce every match before the ranking can choose
between them; a prefix search over two tokens narrows that to 2,239. And
`title_availability` without a `LIMIT` reads 340,343 buffers, which is
the cost of counting every copy of every title. It is a view meant to be
paginated, and the row above it shows what one page costs.

## 3. Index decisions

Four indexes were added in migration 003 and 004. Three were kept
because a measurement justified them; the one that was not is recorded
here as a decision rather than quietly dropped.

| Index | With | Without | Verdict |
| --- | --- | --- | --- |
| `book_title_fts_idx` (GIN) | 107 buffers, 0.65 ms | 335 buffers, 65.71 ms | Kept |
| `book_title_idx` (btree on `title`) | 931 buffers, 4.74 ms | 180,666 buffers, 115.25 ms | Kept |
| `author_display_name_fts_idx` (GIN) | 72 buffers, 0.55 ms | 123 buffers, 9.88 ms | Kept |
| `book_author_author_id_idx` | 72 buffers, 0.55 ms | 254 buffers, 2.85 ms | Kept |
| `hold_active_queue_idx` (proposed) | 20 buffers, 0.17 ms | 26 buffers, 0.16 ms | **Not added** |

The first four each drop the query onto a sequential scan when removed,
which is why removing them costs so much more than their buffer counts
alone suggest. The fifth changes almost nothing, which is the point.

### The two that need explaining

**`book_title_idx` was not obvious.** `title_availability` counts copies
per title through a lateral join, so sorting the catalog by title with
no ordered index on `title` forces every title's copies to be counted
before the first page can be cut. One page of fifty titles read 180,666
buffers that way. With the index the scan stops after fifty rows and
reads 931. The index exists for pagination, not for search.

**`hold_active_queue_idx` was proposed and rejected.** An index on
`hold(book_id, placed_at, hold_id) WHERE status = 'active'` looked like
the natural support for reading a queue in request order. Measured, it
read one title's queue in 20 buffers against 26 without it, and was no
faster. `hold_one_active_per_member_title_idx` is already partial on
active holds and leads with `book_id`, so it serves the same lookup;
dropping *that* index instead takes the same query to 57 buffers, which
is what a queue read actually depends on. Six buffers did not justify a
second index to maintain on every hold written, so it was left out. The
measurement is still run by `measure_query_plans.sh`, which creates the
proposed index inside a transaction and rolls it back, so the decision
can be rechecked. A library whose queues grow long enough for the
ordering to matter should do exactly that rather than trust this
result.

### An index this dataset cannot judge

`loan_open_due_on_idx` comes from the baseline migration, and the
overdue worklist is the query it was meant for. Dropping it changed
almost nothing: 697 buffers against 687, and the same time to within
run-to-run noise. The planner fell back to
`loan_one_open_per_copy_idx`, which is also partial on open loans, and
both restrict the scan to 5,000 open loans instead of all 150,000.

That result does not vindicate the index and does not condemn it. The
dataset leaves 88% of open loans overdue, so ordering by `due_on` has
almost nothing to exclude. A real library has a small overdue fraction,
where the ordered index should separate the few overdue loans from the
many current ones. The index is kept, and this is recorded as a question
the dataset is the wrong shape to answer.

## 4. Two plans that were fixed because they were measured

Both of these were written, measured, and then rewritten. They are
recorded because the first version looked perfectly reasonable in
review.

### The catalog search read every title

`search_titles` originally resolved the matched titles with a single
join to `book` after the three match branches. PostgreSQL estimates the
selectivity of a `@@` match from a fixed default rather than from
statistics, so that join was planned for roughly 200 rows no matter what
was typed, and a search matching four titles still read all 20,000 rows
of `book` through a hash join. Having each branch carry the title
columns it found lets the planner choose per branch. The selective
search went from 340 buffers to 107, and is now served entirely by index
scans (the plan below is from an earlier run, whose timings differ from
the table above; its shape and buffer counts are what matters):

```
 Limit (actual time=0.452..0.492 rows=4 loops=1)
   Buffers: shared hit=107
   ...
         ->  Bitmap Heap Scan on book b_1 (actual time=0.035..0.037 rows=4 loops=1)
               Recheck Cond: (to_tsvector('simple'::regconfig, title) @@ i_1.tsq)
               Heap Blocks: exact=2
               Buffers: shared hit=5
               ->  Bitmap Index Scan on book_title_fts_idx (actual time=0.027..0.027 rows=4 loops=1)
                     Index Cond: (to_tsvector('simple'::regconfig, title) @@ i_1.tsq)
                     Buffers: shared hit=3
```

### Two reports did work per row that belonged in one pass

`overdue_loans_as_of` first called `loan_fine_as_of` once per overdue
loan. That function reads the loan by its id, so the report read the
`loan` table a second time to report rows it already had: a full extra
scan of 150,000 loans to produce 4,391. Computing the fine columns from
the loan row already in hand, through the same `calculate_fine_minor`
and `format_minor_amount` functions, took the report from 2,234 buffers
to 687. The fine rule still has one definition.

`circulation_summary_by_title` called `title_authors()` for each row of
output, which is one index lookup per title. On the full-history report
that was 162,237 buffers for 20,000 rows. Replacing it with one grouped
pass over the credits of the titles in the report brought the same query
to 2,375 buffers, a 68× reduction, with identical results.

## 5. Reproducing this

```sh
psql -X -v ON_ERROR_STOP=1 -d shelfsense_perf -f db/001_baseline.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_perf -f db/002_circulation.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_perf -f db/003_discovery.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_perf -f db/004_holds.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_perf -f db/005_reports.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_perf -f db/perf_dataset.sql
sh scripts/measure_query_plans.sh shelfsense_perf
```

`perf_dataset.sql` commits its rows and must be given a disposable
database with no existing records.

It finishes with `VACUUM ANALYZE`, not `ANALYZE`, and the difference is
not cosmetic. A GIN index buffers newly inserted entries in a pending
list that every search reads in full until something flushes it. Before
the vacuum a selective title search read 289 buffers in its index scan;
after it, 3. A running library reaches the flushed state through
autovacuum, so measuring before the flush would report the cost of
having just bulk-loaded the catalog rather than the cost of searching
it.
