#!/bin/sh
# Concurrency checks for the circulation workflow (FR-04, QR-01, QR-02).
# One psql session cannot race itself, so these two scenarios each run a
# pair of sessions against one copy:
#
#   1. Two staff issue the same copy at once through issue_copy. Exactly
#      one open loan must result and the loser must be told the copy is
#      already on loan, as a business failure rather than a raw
#      constraint error.
#   2. Two writers insert loans for the same copy directly, bypassing
#      issue_copy and its row locks. The partial unique index must still
#      allow exactly one open loan, which is what QR-02 asks the database
#      to guarantee independently of the interface.
#
# Usage: scripts/verify_concurrency.sh [database]
#
# Requires a disposable database with db/001_baseline.sql and
# db/002_circulation.sql applied, and psql on PATH. The usual PG*
# environment variables select the server. On Windows, run it from Git Bash.
set -eu

DB="${1:-shelfsense_test}"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# The racing sessions are expected to fail, so they do not set
# ON_ERROR_STOP; their output is inspected instead.
PSQL="psql -X -q -v ON_ERROR_STOP=1 -d $DB"
RACER="psql -X -q -v VERBOSITY=verbose -d $DB"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

DIRECT_INSERT="INSERT INTO loan (
    copy_id, member_id, policy_id, issued_on, due_on,
    grace_days, fine_minor_per_day, max_fine_minor
)
SELECT c.copy_id, m.member_id, p.policy_id,
       CURRENT_DATE, CURRENT_DATE + p.loan_days,
       p.grace_days, p.fine_minor_per_day, p.max_fine_minor
FROM copy AS c, member AS m, circulation_policy AS p
WHERE c.barcode = 'COPY-CONC' AND p.policy_id = 1 AND m.member_number ="

fail() {
    echo "FAIL: $1"
    shift
    for f in "$@"; do
        echo "--- $f ---"
        cat "$f"
    done
    echo "Fixture rows were left in place for inspection."
    exit 1
}

open_loans() {
    $PSQL -t -A -c "SELECT count(*)
                    FROM loan AS l JOIN copy AS c USING (copy_id)
                    WHERE c.barcode = 'COPY-CONC' AND l.returned_on IS NULL;"
}

# Scenario 1: two concurrent issue_copy calls.
$PSQL -f "$ROOT/db/concurrency_fixture.sql" >/dev/null

# Session A issues the copy and holds its open transaction for two
# seconds. Session B starts while A is still uncommitted.
$RACER >"$WORK/a1.out" 2>&1 <<'SESSION_A' &
BEGIN;
SELECT loan_id FROM issue_copy('M-CONC-A', 'COPY-CONC');
SELECT pg_sleep(2);
COMMIT;
SESSION_A
a_pid=$!

sleep 0.5
$RACER >"$WORK/b1.out" 2>&1 <<'SESSION_B'
SELECT loan_id FROM issue_copy('M-CONC-B', 'COPY-CONC');
SESSION_B
wait "$a_pid" || true

winners=0
loser=""
for s in a b; do
    out="$WORK/${s}1.out"
    if grep -q 'ERROR:' "$out"; then
        grep -q 'SS005' "$out" ||
            fail "session $s was rejected, but not as SS005 (copy already on loan)" "$out"
        loser="$s"
    else
        winners=$((winners + 1))
    fi
done

[ "$winners" -eq 1 ] ||
    fail "expected exactly one successful issue, counted $winners" \
         "$WORK/a1.out" "$WORK/b1.out"

count=$(open_loans)
[ "$count" = "1" ] ||
    fail "expected exactly one open loan after concurrent issue, found $count" \
         "$WORK/a1.out" "$WORK/b1.out"

echo "PASS: concurrent issue_copy calls left exactly one open loan;"
echo "      session $loser was rejected with SS005."

# Scenario 2: two concurrent writers that bypass issue_copy entirely.
$PSQL -f "$ROOT/db/concurrency_fixture.sql" >/dev/null

$RACER >"$WORK/a2.out" 2>&1 <<SESSION_A_DIRECT &
BEGIN;
$DIRECT_INSERT 'M-CONC-A';
SELECT pg_sleep(2);
COMMIT;
SESSION_A_DIRECT
a_pid=$!

sleep 0.5
$RACER >"$WORK/b2.out" 2>&1 <<SESSION_B_DIRECT
BEGIN;
$DIRECT_INSERT 'M-CONC-B';
COMMIT;
SESSION_B_DIRECT
wait "$a_pid" || true

winners=0
for s in a b; do
    out="$WORK/${s}2.out"
    if grep -q 'ERROR:' "$out"; then
        grep -q 'loan_one_open_per_copy_idx' "$out" ||
            fail "direct writer $s failed, but not on the open-loan index" "$out"
    else
        winners=$((winners + 1))
    fi
done

[ "$winners" -eq 1 ] ||
    fail "expected the index to admit exactly one direct insert, counted $winners" \
         "$WORK/a2.out" "$WORK/b2.out"

count=$(open_loans)
[ "$count" = "1" ] ||
    fail "expected exactly one open loan after concurrent direct inserts, found $count" \
         "$WORK/a2.out" "$WORK/b2.out"

echo "PASS: concurrent direct inserts left exactly one open loan;"
echo "      loan_one_open_per_copy_idx rejected the other."

# Fixture rows are left behind when a check fails so they can be
# inspected; a passing run cleans up after itself.
$PSQL >/dev/null <<'TEARDOWN'
BEGIN;
DELETE FROM loan
WHERE copy_id IN (SELECT copy_id FROM copy WHERE barcode = 'COPY-CONC');
DELETE FROM copy WHERE barcode = 'COPY-CONC';
DELETE FROM member WHERE member_number IN ('M-CONC-A', 'M-CONC-B');
DELETE FROM book WHERE isbn13 = '9780262033848';
COMMIT;
TEARDOWN
