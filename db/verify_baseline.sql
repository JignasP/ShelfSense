BEGIN;

INSERT INTO circulation_policy (loan_limit, loan_days, grace_days, fine_minor_per_day, max_fine_minor)
VALUES (3, 14, 1, 25, 200);
INSERT INTO book (title, isbn13) VALUES ('Database Systems', '9780133970777');
INSERT INTO copy (book_id, barcode) VALUES (1, 'COPY-001');
INSERT INTO member (member_number, full_name) VALUES ('M-001', 'Test Member');
INSERT INTO loan (copy_id, member_id, policy_id, issued_on, due_on, grace_days, fine_minor_per_day, max_fine_minor)
VALUES (1, 1, 1, DATE '2026-10-01', DATE '2026-10-15', 1, 25, 200);

DO $$
BEGIN
    IF calculate_fine_minor(DATE '2026-10-15', NULL, DATE '2026-10-15', 1, 25, 200) <> 0 THEN
        RAISE EXCEPTION 'due date fine failed';
    END IF;
    IF calculate_fine_minor(DATE '2026-10-15', NULL, DATE '2026-10-16', 1, 25, 200) <> 0 THEN
        RAISE EXCEPTION 'grace date fine failed';
    END IF;
    IF calculate_fine_minor(DATE '2026-10-15', NULL, DATE '2026-10-18', 1, 25, 200) <> 50 THEN
        RAISE EXCEPTION 'open overdue fine failed';
    END IF;
    IF calculate_fine_minor(DATE '2026-10-15', DATE '2026-10-25', DATE '2027-01-01', 1, 25, 200) <> 200 THEN
        RAISE EXCEPTION 'returned capped fine failed';
    END IF;
    BEGIN
        INSERT INTO loan (copy_id, member_id, policy_id, issued_on, due_on, grace_days, fine_minor_per_day, max_fine_minor)
        VALUES (1, 1, 1, DATE '2026-10-02', DATE '2026-10-16', 1, 25, 200);
        RAISE EXCEPTION 'duplicate open loan accepted';
    EXCEPTION WHEN unique_violation THEN
        NULL;
    END;
    BEGIN
        INSERT INTO loan (copy_id, member_id, policy_id, issued_on, due_on, grace_days, fine_minor_per_day, max_fine_minor)
        VALUES (1, 1, 1, DATE '2026-10-02', DATE '2026-10-01', 1, 25, 200);
        RAISE EXCEPTION 'due date before issue accepted';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;
END;
$$;

UPDATE loan SET returned_on = DATE '2026-10-18' WHERE loan_id = 1;
DO $$
BEGIN
    IF (SELECT fine_minor FROM loan_fines WHERE loan_id = 1) <> 50 THEN
        RAISE EXCEPTION 'returned loan view fine failed';
    END IF;
    IF NOT (SELECT is_final FROM loan_fines WHERE loan_id = 1) THEN
        RAISE EXCEPTION 'returned loan view final flag failed';
    END IF;
END;
$$;
INSERT INTO loan (copy_id, member_id, policy_id, issued_on, due_on, grace_days, fine_minor_per_day, max_fine_minor)
VALUES (1, 1, 1, DATE '2026-10-19', DATE '2026-11-02', 1, 25, 200);

ROLLBACK;
