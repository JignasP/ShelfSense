-- Run with psql -X -v ON_ERROR_STOP=1 against a clean, migrated test database.
-- All fixture rows and procedure effects are rolled back at the end.
BEGIN;

CREATE TEMP TABLE demo_checks (check_name text PRIMARY KEY, result text NOT NULL);

-- Bootstrap is permitted only before the first staff account exists.
INSERT INTO circulation_policy (loan_limit, loan_days, grace_days, fine_minor_per_day, max_fine_minor)
VALUES (3, 14, 1, 50, 500);
INSERT INTO staff_user (username, display_name, password_hash, role)
VALUES ('demo.admin', 'Demo Administrator', 'scrypt$fixture', 'admin');
SELECT set_config('shelfsense.actor_user_id', staff_user_id::text, true)
FROM staff_user WHERE username = 'demo.admin';

-- Procedure 1: save a policy. The existing administrator trigger authorizes it.
CALL save_circulation_policy(4, 14, 1, 100, 1000, 'INR', 2);
SELECT loan_limit, loan_days, grace_days, fine_minor_per_day,
       max_fine_minor, currency_code, currency_minor_digits
FROM circulation_policy WHERE policy_id = 1;

-- A missing administrator identity must fail even through the procedure.
SELECT set_config('shelfsense.actor_user_id', '', true);
DO $$
BEGIN
    BEGIN
        CALL save_circulation_policy(5, 14, 1, 100, 1000, 'INR', 2);
        RAISE EXCEPTION 'policy procedure accepted a missing administrator';
    EXCEPTION WHEN SQLSTATE 'SS016' THEN
        INSERT INTO demo_checks VALUES ('policy without administrator', 'rejected (SS016)');
    END;
END;
$$;
SELECT set_config('shelfsense.actor_user_id', staff_user_id::text, true)
FROM staff_user WHERE username = 'demo.admin';

-- The new session trigger rejects a direct SQL write for inactive staff.
INSERT INTO staff_user (username, display_name, password_hash, role, active)
VALUES ('demo.inactive', 'Inactive Librarian', 'scrypt$fixture', 'librarian', false);
DO $$
BEGIN
    BEGIN
        INSERT INTO staff_session (token_hash, staff_user_id, created_at, expires_at)
        SELECT repeat('c', 64), staff_user_id,
               TIMESTAMPTZ '2026-01-01 00:00:00+00', TIMESTAMPTZ '2026-01-01 08:00:00+00'
        FROM staff_user WHERE username = 'demo.inactive';
        RAISE EXCEPTION 'inactive staff received a session';
    EXCEPTION WHEN SQLSTATE 'SS017' THEN
        INSERT INTO demo_checks VALUES ('session for inactive staff', 'rejected (SS017)');
    END;
END;
$$;

-- Procedure 2: purge only sessions expired at the stated timestamp.
INSERT INTO staff_session (token_hash, staff_user_id, created_at, expires_at)
SELECT repeat('a', 64), staff_user_id,
       TIMESTAMPTZ '2026-01-01 00:00:00+00', TIMESTAMPTZ '2026-01-01 08:00:00+00'
FROM staff_user WHERE username = 'demo.admin';
INSERT INTO staff_session (token_hash, staff_user_id, created_at, expires_at)
SELECT repeat('b', 64), staff_user_id,
       TIMESTAMPTZ '2026-01-31 00:00:00+00', TIMESTAMPTZ '2026-02-01 08:00:00+00'
FROM staff_user WHERE username = 'demo.admin';
DO $$
BEGIN
    BEGIN
        UPDATE staff_session
        SET staff_user_id = (SELECT staff_user_id FROM staff_user WHERE username = 'demo.inactive')
        WHERE token_hash = repeat('b', 64);
        RAISE EXCEPTION 'session was reassigned to inactive staff';
    EXCEPTION WHEN SQLSTATE 'SS017' THEN
        INSERT INTO demo_checks VALUES ('reassign to inactive staff', 'rejected (SS017)');
    END;
END;
$$;
CALL purge_expired_staff_sessions(TIMESTAMPTZ '2026-02-01 00:00:00+00', NULL::bigint);
SELECT count(*) AS sessions_remaining FROM staff_session;

-- The existing loan-event triggers log issue and return.
INSERT INTO book (title) VALUES ('Routines demonstration');
INSERT INTO copy (book_id, barcode, acquired_on)
SELECT book_id, 'ROUTINE-001', DATE '2026-01-01'
FROM book WHERE title = 'Routines demonstration';
INSERT INTO member (member_number, full_name)
VALUES ('ROUTINE-M1', 'Procedure Demo Reader');
SELECT loan_id, issued_on, due_on FROM issue_copy('ROUTINE-M1', 'ROUTINE-001', DATE '2026-01-10');
SELECT loan_id, returned_on FROM return_copy('ROUTINE-001', DATE '2026-01-26');

SELECT check_name, result FROM demo_checks ORDER BY check_name;
SELECT e.event_type, e.effective_on, u.username AS recorded_by
FROM loan_event AS e
JOIN loan AS l USING (loan_id)
JOIN copy AS c USING (copy_id)
LEFT JOIN staff_user AS u USING (staff_user_id)
WHERE c.barcode = 'ROUTINE-001'
ORDER BY e.loan_event_id;
SELECT c.barcode, f.fine_minor, f.fine_display
FROM copy AS c
JOIN loan AS l USING (copy_id)
CROSS JOIN LATERAL loan_fine_as_of(l.loan_id, DATE '2026-01-27') AS f
WHERE c.barcode = 'ROUTINE-001';

DO $$
BEGIN
    IF (SELECT loan_limit FROM circulation_policy WHERE policy_id = 1) <> 4
       OR (SELECT count(*) FROM staff_session) <> 1
       OR (SELECT count(*) FROM demo_checks) <> 3
       OR (SELECT count(*) FROM loan_event) <> 2
       OR (SELECT fine_minor FROM loan_fine_statement) <> 100 THEN
        RAISE EXCEPTION 'routine demonstration assertions failed';
    END IF;
END;
$$;

ROLLBACK;
