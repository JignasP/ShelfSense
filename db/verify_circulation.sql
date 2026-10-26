-- Deterministic checks for the circulation workflow in db/002_circulation.sql.
-- Assumes a disposable database with 001_baseline.sql and 002_circulation.sql
-- applied and no existing records. Every fixture is rolled back at the end.
--
-- Concurrency is not checked here; one psql session cannot race itself.
-- See scripts/verify_concurrency.sh for the two-session check of FR-04.
BEGIN;

INSERT INTO circulation_policy (
    loan_limit, loan_days, grace_days, fine_minor_per_day, max_fine_minor,
    currency_code, currency_minor_digits
) VALUES (2, 14, 2, 25, 200, 'INR', 2);

INSERT INTO book (title, isbn13) VALUES ('Database Systems', '9780133970777');

INSERT INTO copy (book_id, barcode)
SELECT book_id, barcode
FROM book, (VALUES ('COPY-A'), ('COPY-B'), ('COPY-C')) AS b(barcode)
WHERE book.isbn13 = '9780133970777';

INSERT INTO copy (book_id, barcode, acquired_on, withdrawn_on)
SELECT book_id, 'COPY-W', DATE '2020-01-01', DATE '2026-01-01'
FROM book WHERE book.isbn13 = '9780133970777';

INSERT INTO member (member_number, full_name, active) VALUES
    ('M-ACTIVE',   'Active Member',   true),
    ('M-INACTIVE', 'Inactive Member', false),
    ('M-OTHER',    'Other Member',    true);

-- FR-03: an issue records the dates and a snapshot of the current policy.
DO $$
DECLARE
    v_loan loan%ROWTYPE;
BEGIN
    SELECT * INTO v_loan FROM issue_copy('M-ACTIVE', 'COPY-A', DATE '2026-10-01');

    IF v_loan.issued_on <> DATE '2026-10-01' THEN
        RAISE EXCEPTION 'issue date not recorded: %', v_loan.issued_on;
    END IF;
    IF v_loan.due_on <> DATE '2026-10-15' THEN
        RAISE EXCEPTION 'due date not derived from loan_days: %', v_loan.due_on;
    END IF;
    IF v_loan.returned_on IS NOT NULL THEN
        RAISE EXCEPTION 'a new loan must be open';
    END IF;
    IF (v_loan.grace_days, v_loan.fine_minor_per_day, v_loan.max_fine_minor)
            IS DISTINCT FROM (2, 25, 200) THEN
        RAISE EXCEPTION 'policy snapshot not copied onto the loan';
    END IF;
END;
$$;

-- FR-03: a later policy change must not rewrite an existing loan.
DO $$
DECLARE
    v_fine integer;
BEGIN
    UPDATE circulation_policy SET fine_minor_per_day = 500 WHERE policy_id = 1;

    SELECT fine_minor_per_day INTO v_fine
    FROM loan WHERE issued_on = DATE '2026-10-01';
    IF v_fine <> 25 THEN
        RAISE EXCEPTION 'policy change leaked into an existing loan: %', v_fine;
    END IF;

    UPDATE circulation_policy SET fine_minor_per_day = 25 WHERE policy_id = 1;
END;
$$;

-- FR-03, FR-04, QR-01: rejected issues raise their code and write nothing.
DO $$
DECLARE
    v_loans_before bigint;
    v_loans_after  bigint;
BEGIN
    SELECT count(*) INTO v_loans_before FROM loan;

    BEGIN
        PERFORM issue_copy('M-MISSING', 'COPY-B', DATE '2026-10-01');
        RAISE EXCEPTION 'unknown member number was accepted';
    EXCEPTION WHEN SQLSTATE 'SS001' THEN NULL;
    END;

    BEGIN
        PERFORM issue_copy('M-INACTIVE', 'COPY-B', DATE '2026-10-01');
        RAISE EXCEPTION 'inactive member was allowed to borrow';
    EXCEPTION WHEN SQLSTATE 'SS002' THEN NULL;
    END;

    BEGIN
        PERFORM issue_copy('M-ACTIVE', 'COPY-MISSING', DATE '2026-10-01');
        RAISE EXCEPTION 'unknown barcode was accepted';
    EXCEPTION WHEN SQLSTATE 'SS003' THEN NULL;
    END;

    BEGIN
        PERFORM issue_copy('M-ACTIVE', 'COPY-W', DATE '2026-10-01');
        RAISE EXCEPTION 'withdrawn copy was issued';
    EXCEPTION WHEN SQLSTATE 'SS004' THEN NULL;
    END;

    BEGIN
        PERFORM issue_copy('M-OTHER', 'COPY-A', DATE '2026-10-02');
        RAISE EXCEPTION 'copy with an open loan was issued again';
    EXCEPTION WHEN SQLSTATE 'SS005' THEN NULL;
    END;

    SELECT count(*) INTO v_loans_after FROM loan;
    IF v_loans_after <> v_loans_before THEN
        RAISE EXCEPTION 'a rejected issue created % loan row(s)',
            v_loans_after - v_loans_before;
    END IF;
END;
$$;

-- FR-05: the open-loan limit is enforced against the configured value.
DO $$
DECLARE
    v_open bigint;
BEGIN
    PERFORM issue_copy('M-ACTIVE', 'COPY-B', DATE '2026-10-02');

    BEGIN
        PERFORM issue_copy('M-ACTIVE', 'COPY-C', DATE '2026-10-03');
        RAISE EXCEPTION 'issue accepted beyond the open-loan limit';
    EXCEPTION WHEN SQLSTATE 'SS006' THEN NULL;
    END;

    SELECT count(*) INTO v_open
    FROM loan AS l JOIN member AS m USING (member_id)
    WHERE m.member_number = 'M-ACTIVE' AND l.returned_on IS NULL;
    IF v_open <> 2 THEN
        RAISE EXCEPTION 'expected 2 open loans at the limit, found %', v_open;
    END IF;
END;
$$;

-- FR-07: grace-day and fine-cap boundaries on an open loan.
-- COPY-A is due 2026-10-15 with 2 grace days, 25 minor units per day,
-- and a 200 minor unit cap, so the cap is reached on the eighth
-- chargeable day, 2026-10-25.
DO $$
DECLARE
    v_loan_id bigint;
    v_case    record;
    v_actual  record;
BEGIN
    SELECT l.loan_id INTO v_loan_id
    FROM loan AS l JOIN copy AS c USING (copy_id)
    WHERE c.barcode = 'COPY-A';

    FOR v_case IN
        SELECT * FROM (VALUES
            (DATE '2026-10-14', 0, 0,   0),  -- before the due date
            (DATE '2026-10-15', 0, 0,   0),  -- the due date itself
            (DATE '2026-10-16', 1, 0,   0),  -- inside the grace period
            (DATE '2026-10-17', 2, 0,   0),  -- last free day
            (DATE '2026-10-18', 3, 1,  25),  -- first chargeable day
            (DATE '2026-10-24', 9, 7, 175),  -- last day below the cap
            (DATE '2026-10-25', 10, 8, 200), -- cap reached exactly
            (DATE '2026-12-31', 77, 75, 200) -- cap holds afterwards
        ) AS t(as_of, days_past_due, chargeable_days, fine_minor)
    LOOP
        SELECT * INTO v_actual FROM loan_fine_as_of(v_loan_id, v_case.as_of);

        IF v_actual.is_final THEN
            RAISE EXCEPTION 'open loan reported as final at %', v_case.as_of;
        END IF;
        IF v_actual.as_of_date <> v_case.as_of THEN
            RAISE EXCEPTION 'as-of date % not reported, got %',
                v_case.as_of, v_actual.as_of_date;
        END IF;
        IF v_actual.days_past_due <> v_case.days_past_due THEN
            RAISE EXCEPTION 'days past due at %: expected %, got %',
                v_case.as_of, v_case.days_past_due, v_actual.days_past_due;
        END IF;
        IF v_actual.chargeable_days <> v_case.chargeable_days THEN
            RAISE EXCEPTION 'chargeable days at %: expected %, got %',
                v_case.as_of, v_case.chargeable_days, v_actual.chargeable_days;
        END IF;
        IF v_actual.fine_minor <> v_case.fine_minor THEN
            RAISE EXCEPTION 'fine at %: expected %, got %',
                v_case.as_of, v_case.fine_minor, v_actual.fine_minor;
        END IF;
    END LOOP;
END;
$$;

-- QR-04: amounts are displayed with the configured currency.
DO $$
DECLARE
    v_loan_id bigint;
    v_display text;
BEGIN
    SELECT l.loan_id INTO v_loan_id
    FROM loan AS l JOIN copy AS c USING (copy_id)
    WHERE c.barcode = 'COPY-A';

    SELECT fine_display INTO v_display FROM loan_fine_as_of(v_loan_id, DATE '2026-10-18');
    IF v_display <> 'INR 0.25' THEN
        RAISE EXCEPTION 'fine display for 25 minor units was %', v_display;
    END IF;

    SELECT fine_display INTO v_display FROM loan_fine_as_of(v_loan_id, DATE '2026-10-25');
    IF v_display <> 'INR 2.00' THEN
        RAISE EXCEPTION 'fine display for 200 minor units was %', v_display;
    END IF;

    IF format_minor_amount(1500, 'JPY', 0) <> 'JPY 1500' THEN
        RAISE EXCEPTION 'zero-decimal currency display was %',
            format_minor_amount(1500, 'JPY', 0);
    END IF;
END;
$$;

-- FR-06: the return date is recorded once and the fine then stops moving.
DO $$
DECLARE
    v_loan    loan%ROWTYPE;
    v_loan_id bigint;
    v_actual  record;
BEGIN
    SELECT * INTO v_loan FROM return_copy('COPY-A', DATE '2026-10-25');
    v_loan_id := v_loan.loan_id;

    IF v_loan.returned_on <> DATE '2026-10-25' THEN
        RAISE EXCEPTION 'return date not recorded: %', v_loan.returned_on;
    END IF;

    BEGIN
        PERFORM return_copy('COPY-A', DATE '2026-10-28');
        RAISE EXCEPTION 'the same loan was returned twice';
    EXCEPTION WHEN SQLSTATE 'SS009' THEN NULL;
    END;

    IF (SELECT returned_on FROM loan WHERE loan_id = v_loan_id) <> DATE '2026-10-25' THEN
        RAISE EXCEPTION 'a rejected second return changed the return date';
    END IF;

    -- The final fine is read from the return date, not from the requested
    -- date, so asking much later gives the same answer.
    FOR v_actual IN
        SELECT * FROM loan_fine_as_of(v_loan_id, DATE '2026-10-26')
        UNION ALL
        SELECT * FROM loan_fine_as_of(v_loan_id, DATE '2027-06-01')
    LOOP
        IF NOT v_actual.is_final THEN
            RAISE EXCEPTION 'returned loan not reported as final';
        END IF;
        IF v_actual.as_of_date <> DATE '2026-10-25' THEN
            RAISE EXCEPTION 'final fine as-of date was %', v_actual.as_of_date;
        END IF;
        IF v_actual.fine_minor <> 200 THEN
            RAISE EXCEPTION 'final fine moved after return: %', v_actual.fine_minor;
        END IF;
    END LOOP;
END;
$$;

-- FR-06: returns that cannot apply are rejected with their own codes.
DO $$
BEGIN
    BEGIN
        PERFORM return_copy('COPY-C', DATE '2026-10-25');
        RAISE EXCEPTION 'a copy that was never issued was returned';
    EXCEPTION WHEN SQLSTATE 'SS008' THEN NULL;
    END;

    BEGIN
        PERFORM return_copy('COPY-MISSING', DATE '2026-10-25');
        RAISE EXCEPTION 'an unknown barcode was returned';
    EXCEPTION WHEN SQLSTATE 'SS003' THEN NULL;
    END;

    BEGIN
        PERFORM return_copy('COPY-B', DATE '2026-09-30');
        RAISE EXCEPTION 'a return before the issue date was accepted';
    EXCEPTION WHEN SQLSTATE 'SS011' THEN NULL;
    END;
END;
$$;

-- FR-04: returning a copy makes it issuable again.
DO $$
DECLARE
    v_open bigint;
BEGIN
    PERFORM issue_copy('M-OTHER', 'COPY-A', DATE '2026-10-26');

    SELECT count(*) INTO v_open
    FROM loan AS l JOIN copy AS c USING (copy_id)
    WHERE c.barcode = 'COPY-A' AND l.returned_on IS NULL;
    IF v_open <> 1 THEN
        RAISE EXCEPTION 'expected one open loan for the reissued copy, found %', v_open;
    END IF;
END;
$$;

-- QR-04: the statement view carries the borrower, dates, and currency.
DO $$
DECLARE
    v_row record;
BEGIN
    SELECT * INTO v_row FROM loan_fine_statement
    WHERE barcode = 'COPY-A' AND returned_on IS NULL;

    IF v_row.member_number <> 'M-OTHER' THEN
        RAISE EXCEPTION 'statement borrower was %', v_row.member_number;
    END IF;
    IF v_row.title <> 'Database Systems' THEN
        RAISE EXCEPTION 'statement title was %', v_row.title;
    END IF;
    IF v_row.currency_code <> 'INR' THEN
        RAISE EXCEPTION 'statement currency was %', v_row.currency_code;
    END IF;
    IF v_row.as_of_date <> CURRENT_DATE THEN
        RAISE EXCEPTION 'open statement as-of date was %', v_row.as_of_date;
    END IF;
    IF v_row.fine_display IS NULL THEN
        RAISE EXCEPTION 'statement fine display is missing';
    END IF;
END;
$$;

-- SS010: issuing without a configured policy is refused.
DO $$
DECLARE
    v_saved circulation_policy%ROWTYPE;
BEGIN
    SELECT * INTO v_saved FROM circulation_policy WHERE policy_id = 1;
    DELETE FROM loan;
    DELETE FROM circulation_policy WHERE policy_id = 1;

    BEGIN
        PERFORM issue_copy('M-ACTIVE', 'COPY-C', DATE '2026-10-01');
        RAISE EXCEPTION 'issue accepted without a circulation policy';
    EXCEPTION WHEN SQLSTATE 'SS010' THEN NULL;
    END;

    INSERT INTO circulation_policy VALUES (v_saved.*);
END;
$$;

ROLLBACK;
