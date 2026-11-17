# Database routines demonstration

This is a repeatable PostgreSQL demonstration of stored procedures and
triggers. It uses the versioned [migration 007](../db/007_routines.sql)
and the rollback-based [demo script](../db/demo_routines.sql). The fixture
dates are fixed, so fine results do not depend on the day of the presentation.

## Run

Use a new, empty test database. From the repository root, with `psql`
configured to connect to the intended local PostgreSQL instance:

```powershell
psql -X -v ON_ERROR_STOP=1 -d postgres -c "CREATE DATABASE shelfsense_routines_test"
Get-ChildItem db/00[1-7]_*.sql | Sort-Object Name | ForEach-Object {
    psql -X -v ON_ERROR_STOP=1 -d shelfsense_routines_test -f $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "Migration failed: $($_.Name)" }
}
psql -X -v ON_ERROR_STOP=1 -d shelfsense_routines_test -f db/demo_routines.sql
```

The demo opens a transaction, inserts its own policy, staff, copy, member,
loan, and sessions, checks the expected results, then runs `ROLLBACK`.
Use this database separately from the six verification scripts: identity
sequence values are not rolled back even though fixture rows are.

## What to show

1. `CALL save_circulation_policy(...)` changes the seven policy values.
   The administrator-write trigger rejects the same call when no active
   administrator identity is set in the transaction.
2. The `staff_session_active_user` trigger rejects a session inserted for
   inactive staff or reassigned to them, including direct SQL outside the
   web interface.
3. `CALL purge_expired_staff_sessions(...)` returns `p_deleted = 1` and
   leaves the one session whose expiry is later than the stated timestamp.
4. The existing loan-event triggers record an `issued` and a `returned`
   event, both attributed to the fixture administrator. The returned
   loan's fine is 100 minor units, displayed as INR 1.00.

`issue_copy` and `return_copy` remain functions because they return loan
rows to their callers; the two new procedures are invoked with `CALL`.

## Observed output

The following rows were produced by running the demo against PostgreSQL
17.5. Identity numbers can differ between runs.

```text
 loan_limit | loan_days | grace_days | fine_minor_per_day | max_fine_minor | currency_code | currency_minor_digits
------------+-----------+------------+--------------------+----------------+---------------+----------------------
          4 |        14 |          1 |                100 |           1000 | INR           |                     2

 p_deleted
-----------
         1

 sessions_remaining
--------------------
                  1

          check_name          |      result
------------------------------+------------------
 policy without administrator | rejected (SS016)
 reassign to inactive staff   | rejected (SS017)
 session for inactive staff   | rejected (SS017)

 event_type | effective_on | recorded_by
------------+--------------+-------------
 issued     | 2026-01-10   | demo.admin
 returned   | 2026-01-26   | demo.admin

   barcode   | fine_minor | fine_display
-------------+------------+--------------
 ROUTINE-001 |        100 | INR 1.00

ROLLBACK
```

The `DO` block at the end raises an error if any of those assertions
fail. `ON_ERROR_STOP=1` makes that failure visible as a nonzero `psql`
exit status.
