#!/bin/sh
# Measures the discovery and reporting queries against the representative
# dataset, so the claims in docs/query-performance.md are reported rather
# than assumed (FR-08, FR-09, FR-10, FR-11).
#
# Each query is run twice: the first run warms the shared buffers and its
# output is discarded, the second is the one reported. Without that, the
# numbers describe reading the dataset off disk for the first time rather
# than running the query.
#
# Where an index is the point of the measurement, the same query is run
# again with that one index dropped inside a transaction that is then
# rolled back, so the comparison isolates the index instead of turning
# off index access in general. That is what makes an index justified by
# a result rather than by an argument: the alternative plan is measured
# too.
#
# Usage: scripts/measure_query_plans.sh [database]
#
# Requires a disposable database with every migration in db/ applied and
# db/perf_dataset.sql loaded, and psql on PATH. The usual PG*
# environment variables select the server. On Windows, run it from Git
# Bash. Output is plain text, intended to be read or pasted into the
# performance document.
set -eu

DB="${1:-shelfsense_perf}"
PSQL="psql -X -q -v ON_ERROR_STOP=1 -d $DB"

EXPLAIN_OPTS='ANALYZE, BUFFERS, COSTS OFF'

# measure <label> <sql>
measure() {
    echo
    echo '----------------------------------------------------------------'
    echo "$1"
    echo '----------------------------------------------------------------'
    $PSQL -c "$2" >/dev/null
    $PSQL -c "EXPLAIN ($EXPLAIN_OPTS) $2"
}

# measure_without <label> <index to drop> <sql>
# The DROP is rolled back, so the index is restored whatever the result.
measure_without() {
    echo
    echo '----------------------------------------------------------------'
    echo "$1"
    echo '----------------------------------------------------------------'
    $PSQL -c "$3" >/dev/null
    $PSQL <<SQL
BEGIN;
DROP INDEX $2;
EXPLAIN ($EXPLAIN_OPTS) $3;
ROLLBACK;
SQL
}

# measure_with <label> <CREATE INDEX statement> <sql>
# Measures an index the project does not ship, so that a decision not to
# add one stays reproducible. The index is created and analysed inside a
# transaction that is then rolled back.
measure_with() {
    echo
    echo '----------------------------------------------------------------'
    echo "$1"
    echo '----------------------------------------------------------------'
    $PSQL -c "$3" >/dev/null
    $PSQL <<SQL
BEGIN;
$2;
ANALYZE hold;
EXPLAIN ($EXPLAIN_OPTS) $3;
ROLLBACK;
SQL
}

# Report the dataset the numbers belong to. A plan without its row
# counts is not evidence of anything.
echo '================================================================'
echo 'Dataset'
echo '================================================================'
$PSQL -c "
SELECT 'titles' AS relation, count(*) AS rows FROM book
UNION ALL SELECT 'authors', count(*) FROM author
UNION ALL SELECT 'title-author links', count(*) FROM book_author
UNION ALL SELECT 'copies', count(*) FROM copy
UNION ALL SELECT 'copies withdrawn', count(*) FROM copy WHERE withdrawn_on IS NOT NULL
UNION ALL SELECT 'members', count(*) FROM member
UNION ALL SELECT 'loans', count(*) FROM loan
UNION ALL SELECT 'loans open', count(*) FROM loan WHERE returned_on IS NULL
UNION ALL SELECT 'holds', count(*) FROM hold
UNION ALL SELECT 'holds active', count(*) FROM hold WHERE status = 'active'
ORDER BY 1;"
$PSQL -c "SELECT version();"
$PSQL -c "SELECT current_setting('shared_buffers') AS shared_buffers,
                 current_setting('work_mem') AS work_mem,
                 pg_size_pretty(pg_database_size(current_database())) AS database_size;"

echo
echo '================================================================'
echo 'FR-09 catalog search'
echo '================================================================'

measure 'Title search, selective term (4 of 20,000 titles)' \
    "SELECT * FROM search_titles('Palimpsest');"

measure_without 'Title search, selective term, without book_title_fts_idx' \
    'book_title_fts_idx' \
    "SELECT * FROM search_titles('Palimpsest');"

measure 'Title search, unselective term (a tenth of the catalog)' \
    "SELECT * FROM search_titles('Compilers');"

measure 'Title search, two prefix tokens' \
    "SELECT * FROM search_titles('compil prim');"

measure 'Author search, one rare author' \
    "SELECT * FROM search_titles('Quenneville');"

measure_without 'Author search, without author_display_name_fts_idx' \
    'author_display_name_fts_idx' \
    "SELECT * FROM search_titles('Quenneville');"

measure_without 'Author search, without book_author_author_id_idx' \
    'book_author_author_id_idx' \
    "SELECT * FROM search_titles('Quenneville');"

measure 'ISBN search, exact match' \
    "SELECT * FROM search_titles('9780000012345');"

echo
echo '================================================================'
echo 'FR-08 availability'
echo '================================================================'

measure 'Availability of one title' \
    "SELECT * FROM title_availability WHERE book_id = 11;"

measure 'Availability of one copy by barcode' \
    "SELECT * FROM copy_availability WHERE barcode = 'BC-004242';"

measure 'Catalog browse, one page of 50 titles' \
    "SELECT * FROM title_availability ORDER BY title LIMIT 50;"

measure_without 'Catalog browse, one page of 50 titles, without book_title_idx' \
    'book_title_idx' \
    "SELECT * FROM title_availability ORDER BY title LIMIT 50;"

measure 'Catalog browse, every title at once' \
    "SELECT * FROM title_availability;"

echo
echo '================================================================'
echo 'FR-10 reports'
echo '================================================================'

measure 'Overdue worklist at a stated date' \
    "SELECT * FROM overdue_loans_as_of(DATE '2026-10-31');"

measure_without 'Overdue worklist, without loan_open_due_on_idx' \
    'loan_open_due_on_idx' \
    "SELECT * FROM overdue_loans_as_of(DATE '2026-10-31');"

measure 'Circulation by title, one month' \
    "SELECT * FROM circulation_summary_by_title(DATE '2026-09-01', DATE '2026-09-30');"

measure 'Circulation by title, full history' \
    "SELECT * FROM circulation_summary_by_title(DATE '2024-01-01', DATE '2026-10-31');"

measure 'Circulation by month, full history with ROLLUP total' \
    "SELECT * FROM circulation_summary_by_month(DATE '2024-01-01', DATE '2026-10-31');"

echo
echo '================================================================'
echo 'FR-11 hold queue'
echo '================================================================'

measure 'Queue for one title' \
    "SELECT * FROM hold_queue WHERE book_id = 500;"

measure_without 'Queue for one title, without the partial index on active holds' \
    'hold_one_active_per_member_title_idx' \
    "SELECT * FROM hold_queue WHERE book_id = 500;"

# This index is not part of the schema. It is measured here because the
# decision not to add it is recorded in docs/query-performance.md, and a
# decision based on a measurement should stay reproducible.
measure_with 'Queue for one title, with a proposed hold_active_queue_idx' \
    "CREATE INDEX hold_active_queue_idx ON hold(book_id, placed_at, hold_id) WHERE status = 'active'" \
    "SELECT * FROM hold_queue WHERE book_id = 500;"

measure 'The hold rule for one issue decision' \
    "SELECT hold_permits_issue(
         (SELECT copy_id FROM copy WHERE book_id = 500 LIMIT 1),
         (SELECT member_id FROM member WHERE member_number = 'MB-00001'));"

echo
echo 'Done.'
