#!/bin/sh
# Concurrency checks for the hold queue (FR-11).
#
# The hold rule compares two counts, the copies free and the holds ahead
# of the borrower, so two staff acting at once could both read "there is
# a copy to spare" and between them leave somebody in the queue with
# nothing. issue_copy locks the title's book row to stop that, and one
# psql session cannot race itself, so each scenario below runs a pair of
# sessions against one title:
#
#   1. Three copies are free and two members are waiting, so there is
#      exactly one copy to spare. Two walk-in borrowers ask for two
#      different copies at the same time. Exactly one may succeed, and
#      the queue must still have a copy for each of its two members
#      afterwards.
#   2. Two copies are free and two members are waiting. The second
#      member in the queue and a walk-in ask at the same time. The
#      queued member must be served, because a copy still remains for
#      the member ahead of them; the walk-in must be refused with SS007,
#      whichever of the two commits first.
#
# Usage: scripts/verify_hold_concurrency.sh [database]
#
# Requires a disposable database with every migration in db/ applied,
# and psql on PATH. The usual PG* environment variables select the
# server. On Windows, run it from Git Bash.
set -eu

DB="${1:-shelfsense_test}"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# The racing sessions are expected to fail, so they do not set
# ON_ERROR_STOP; their output is inspected instead.
PSQL="psql -X -q -v ON_ERROR_STOP=1 -d $DB"
RACER="psql -X -q -v VERBOSITY=verbose -d $DB"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

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

count() {
    $PSQL -t -A -c "$1"
}

copies_free() {
    count "SELECT count(*)
           FROM copy_availability AS ca
           JOIN book AS b ON b.book_id = ca.book_id
           WHERE b.isbn13 = '9780596007126'
             AND ca.availability_status = 'available';"
}

active_holds() {
    count "SELECT count(*)
           FROM hold AS h
           JOIN book AS b ON b.book_id = h.book_id
           WHERE b.isbn13 = '9780596007126' AND h.status = 'active';"
}

hold_status() {
    count "SELECT h.status
           FROM hold AS h
           JOIN book AS b ON b.book_id = h.book_id
           JOIN member AS m ON m.member_id = h.member_id
           WHERE b.isbn13 = '9780596007126' AND m.member_number = '$1';"
}

# Scenario 1: two walk-ins race for the one copy the queue can spare.
$PSQL -f "$ROOT/db/holds_concurrency_fixture.sql" >/dev/null

free_before=$(copies_free)
[ "$free_before" = "3" ] ||
    fail "fixture left $free_before free copies, expected 3"

# Session C issues and holds its open transaction for two seconds.
# Session D starts while C is still uncommitted.
$RACER >"$WORK/c1.out" 2>&1 <<'SESSION_C' &
BEGIN;
SELECT loan_id FROM issue_copy('M-HC-C', 'HC-1');
SELECT pg_sleep(2);
COMMIT;
SESSION_C
c_pid=$!

sleep 0.5
$RACER >"$WORK/d1.out" 2>&1 <<'SESSION_D'
SELECT loan_id FROM issue_copy('M-HC-D', 'HC-2');
SESSION_D
wait "$c_pid" || true

winners=0
loser=""
for s in c d; do
    out="$WORK/${s}1.out"
    if grep -q 'ERROR:' "$out"; then
        grep -q 'SS007' "$out" ||
            fail "walk-in $s was rejected, but not as SS007 (a hold reserves the copy)" "$out"
        loser="$s"
    else
        winners=$((winners + 1))
    fi
done

[ "$winners" -eq 1 ] ||
    fail "expected exactly one walk-in to succeed, counted $winners" \
         "$WORK/c1.out" "$WORK/d1.out"

free_after=$(copies_free)
holds_after=$(active_holds)
[ "$free_after" -ge "$holds_after" ] ||
    fail "the queue was over-allocated: $free_after free copies for $holds_after waiting members" \
         "$WORK/c1.out" "$WORK/d1.out"
[ "$holds_after" = "2" ] ||
    fail "a walk-in resolved a hold: $holds_after active holds remain, expected 2" \
         "$WORK/c1.out" "$WORK/d1.out"

echo "PASS: concurrent walk-ins took only the spare copy;"
echo "      walk-in $loser was rejected with SS007, and $free_after copies"
echo "      remain for the $holds_after members still in the queue."

# Scenario 2: the second member in the queue races a walk-in.
$PSQL -f "$ROOT/db/holds_concurrency_fixture.sql" >/dev/null
$PSQL -c "UPDATE copy SET withdrawn_on = CURRENT_DATE WHERE barcode = 'HC-3';" >/dev/null

free_before=$(copies_free)
[ "$free_before" = "2" ] ||
    fail "scenario 2 setup left $free_before free copies, expected 2"

$RACER >"$WORK/b2.out" 2>&1 <<'SESSION_B' &
BEGIN;
SELECT loan_id FROM issue_copy('M-HC-B', 'HC-1');
SELECT pg_sleep(2);
COMMIT;
SESSION_B
b_pid=$!

sleep 0.5
$RACER >"$WORK/c2.out" 2>&1 <<'SESSION_C2'
SELECT loan_id FROM issue_copy('M-HC-C', 'HC-2');
SESSION_C2
wait "$b_pid" || true

grep -q 'ERROR:' "$WORK/b2.out" &&
    fail "the second member in the queue was refused a copy that was free for them" \
         "$WORK/b2.out"

grep -q 'SS007' "$WORK/c2.out" ||
    fail "the walk-in was not refused with SS007 while a member was still waiting" \
         "$WORK/c2.out"

[ "$(hold_status M-HC-B)" = "fulfilled" ] ||
    fail "the served member's hold was not marked fulfilled" "$WORK/b2.out"
[ "$(hold_status M-HC-A)" = "active" ] ||
    fail "the member at the front of the queue lost their place" "$WORK/b2.out"

free_after=$(copies_free)
[ "$free_after" -ge 1 ] ||
    fail "no copy was left for the member at the front of the queue" \
         "$WORK/b2.out" "$WORK/c2.out"

echo "PASS: the queued member was served and the walk-in was refused with SS007;"
echo "      the member at the front of the queue kept their place and a copy."

# Fixture rows are left behind when a check fails so they can be
# inspected; a passing run cleans up after itself.
$PSQL >/dev/null <<'TEARDOWN'
BEGIN;
DELETE FROM hold
WHERE book_id IN (SELECT book_id FROM book WHERE isbn13 = '9780596007126');
DELETE FROM loan
WHERE copy_id IN (SELECT copy_id FROM copy WHERE barcode LIKE 'HC-%');
DELETE FROM copy WHERE barcode LIKE 'HC-%';
DELETE FROM member WHERE member_number LIKE 'M-HC-%';
DELETE FROM book WHERE isbn13 = '9780596007126';
COMMIT;
TEARDOWN
