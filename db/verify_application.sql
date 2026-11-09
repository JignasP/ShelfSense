-- Run against a clean test database after all migrations. All fixtures roll back.
BEGIN;

INSERT INTO circulation_policy (loan_limit, loan_days, grace_days, fine_minor_per_day, max_fine_minor)
VALUES (3, 14, 1, 25, 200);
INSERT INTO staff_user (username, display_name, password_hash, role)
VALUES ('test.admin', 'Test Admin', 'scrypt$fixture', 'admin');
DO $$
BEGIN
    BEGIN
        INSERT INTO staff_user (username, display_name, password_hash, role)
        VALUES ('test.librarian', 'Test Librarian', 'scrypt$fixture', 'librarian');
        RAISE EXCEPTION 'staff write without admin context was accepted';
    EXCEPTION WHEN SQLSTATE 'SS016' THEN NULL;
    END;
    BEGIN
        UPDATE circulation_policy SET loan_limit = 4 WHERE policy_id = 1;
        RAISE EXCEPTION 'policy write without admin context was accepted';
    EXCEPTION WHEN SQLSTATE 'SS016' THEN NULL;
    END;
END;
$$;
INSERT INTO book (title) VALUES ('Audit Fixture');
INSERT INTO copy (book_id, barcode)
SELECT book_id, 'APP-001' FROM book WHERE title = 'Audit Fixture';
INSERT INTO member (member_number, full_name) VALUES ('APP-M1', 'Test Member');

SELECT set_config('shelfsense.actor_user_id', (
    SELECT staff_user_id::text FROM staff_user WHERE username = 'test.admin'
), true);
INSERT INTO staff_user (username, display_name, password_hash, role)
VALUES ('test.librarian', 'Test Librarian', 'scrypt$fixture', 'librarian');
UPDATE circulation_policy SET loan_limit = 4 WHERE policy_id = 1;
SELECT set_config('shelfsense.actor_user_id', (
    SELECT staff_user_id::text FROM staff_user WHERE username = 'test.librarian'
), true);
DO $$
BEGIN
    BEGIN
        UPDATE circulation_policy SET loan_limit = 5 WHERE policy_id = 1;
        RAISE EXCEPTION 'librarian policy write was accepted';
    EXCEPTION WHEN SQLSTATE 'SS016' THEN NULL;
    END;
END;
$$;
SELECT set_config('shelfsense.actor_user_id', (
    SELECT staff_user_id::text FROM staff_user WHERE username = 'test.admin'
), true);
SELECT issue_copy('APP-M1', 'APP-001', DATE '2026-01-02');
SELECT return_copy('APP-001', DATE '2026-01-04');

DO $$
DECLARE
    v_loan_id bigint;
    v_staff_id bigint;
BEGIN
    SELECT l.loan_id INTO v_loan_id FROM loan l JOIN copy c USING (copy_id)
    WHERE c.barcode = 'APP-001';
    SELECT staff_user_id INTO v_staff_id FROM staff_user WHERE username = 'test.admin';
    IF (SELECT count(*) FROM loan_event WHERE loan_id = v_loan_id) <> 2 THEN
        RAISE EXCEPTION 'expected issue and return audit events';
    END IF;
    IF (SELECT string_agg(event_type, ',' ORDER BY loan_event_id)
        FROM loan_event WHERE loan_id = v_loan_id) <> 'issued,returned' THEN
        RAISE EXCEPTION 'audit event order is wrong';
    END IF;
    IF (SELECT count(*) FROM loan_event WHERE staff_user_id = v_staff_id) <> 2 THEN
        RAISE EXCEPTION 'audit actor is missing';
    END IF;
    IF (SELECT string_agg(loans_issued::text, ',' ORDER BY report_date)
        FROM daily_issues(DATE '2026-01-01', DATE '2026-01-04')) <> '0,1,0,0' THEN
        RAISE EXCEPTION 'recursive daily report is wrong';
    END IF;
    IF EXISTS (SELECT 1 FROM daily_issues(DATE '2026-01-05', DATE '2026-01-01')) THEN
        RAISE EXCEPTION 'reversed report period accepted';
    END IF;
END;
$$;

ROLLBACK;
