-- Deterministic checks for the reports in db/005_reports.sql. Assumes a
-- disposable database with every migration applied and no existing
-- records. Every fixture is rolled back at the end, so a passing run
-- prints nothing.
--
-- The fixture is six loans with fixed dates, so every total below is a
-- hand-computed number rather than whatever the query happened to
-- return. Policy: 14 loan days, 2 grace days, 25 minor units per day, a
-- 200 minor unit cap.
--
--   loan  copy   member  issued      due         returned    fine
--   L1    RA-1   M-R1    2026-09-02  2026-09-16  2026-09-10    0
--   L2    RA-2   M-R2    2026-09-05  2026-09-19  2026-09-25  100
--   L3    RA-1   M-R3    2026-09-20  2026-10-04  open        200 (capped)
--   L4    RB-1   M-R1    2026-10-01  2026-10-15  2026-10-20   75
--   L5    RC-1   M-R2    2026-10-03  2026-10-17  open        200 (capped)
--   L6    RA-2   M-R1    2026-10-06  2026-10-20  2026-10-08    0
--
-- Fines for the two open loans are stated as of 2026-10-31, the end of
-- the reporting period used throughout this file.
BEGIN;

INSERT INTO circulation_policy (
    loan_limit, loan_days, grace_days, fine_minor_per_day, max_fine_minor,
    currency_code, currency_minor_digits
) VALUES (20, 14, 2, 25, 200, 'INR', 2);

INSERT INTO book (title, isbn13) VALUES
    ('Report Title A', '9780201633610'),
    ('Report Title B', '9780321573513'),
    ('Report Title C', '9781449373320');

INSERT INTO author (display_name) VALUES
    ('Erich Gamma'),
    ('Steven Skiena'),
    ('Martin Kleppmann');

INSERT INTO book_author (book_id, author_id, author_order)
SELECT b.book_id, a.author_id, 1
FROM (VALUES
    ('Report Title A', 'Erich Gamma'),
    ('Report Title B', 'Steven Skiena'),
    ('Report Title C', 'Martin Kleppmann')
) AS v(title, display_name)
JOIN book   AS b ON b.title = v.title
JOIN author AS a ON a.display_name = v.display_name;

INSERT INTO copy (book_id, barcode)
SELECT b.book_id, v.barcode
FROM (VALUES
    ('Report Title A', 'RA-1'),
    ('Report Title A', 'RA-2'),
    ('Report Title B', 'RB-1'),
    ('Report Title C', 'RC-1')
) AS v(title, barcode)
JOIN book AS b ON b.title = v.title;

INSERT INTO member (member_number, full_name) VALUES
    ('M-R1', 'Report Member One'),
    ('M-R2', 'Report Member Two'),
    ('M-R3', 'Report Member Three');

DO $$
BEGIN
    PERFORM issue_copy('M-R1', 'RA-1', DATE '2026-09-02');
    PERFORM issue_copy('M-R2', 'RA-2', DATE '2026-09-05');
    PERFORM return_copy('RA-1', DATE '2026-09-10');
    PERFORM issue_copy('M-R3', 'RA-1', DATE '2026-09-20');
    PERFORM return_copy('RA-2', DATE '2026-09-25');
    PERFORM issue_copy('M-R1', 'RB-1', DATE '2026-10-01');
    PERFORM issue_copy('M-R2', 'RC-1', DATE '2026-10-03');
    PERFORM issue_copy('M-R1', 'RA-2', DATE '2026-10-06');
    PERFORM return_copy('RA-2', DATE '2026-10-08');
    PERFORM return_copy('RB-1', DATE '2026-10-20');
END;
$$;

-- FR-10: the overdue worklist lists exactly the open loans past due.
DO $$
DECLARE
    v_rows  text[];
    v_row   record;
BEGIN
    SELECT array_agg(o.barcode ORDER BY o.due_on, o.loan_id)
    INTO v_rows
    FROM overdue_loans_as_of(DATE '2026-10-31') AS o;

    IF v_rows <> ARRAY['RA-1', 'RC-1'] THEN
        RAISE EXCEPTION 'overdue list at 2026-10-31 was %', v_rows;
    END IF;

    -- Oldest due date first, which is the order staff work through.
    SELECT * INTO v_row
    FROM overdue_loans_as_of(DATE '2026-10-31') AS o
    LIMIT 1;
    IF v_row.barcode <> 'RA-1' OR v_row.due_on <> DATE '2026-10-04' THEN
        RAISE EXCEPTION 'the first overdue row was % due %', v_row.barcode, v_row.due_on;
    END IF;
    IF v_row.days_past_due <> 27 OR v_row.chargeable_days <> 25 THEN
        RAISE EXCEPTION 'overdue days for RA-1 were % past due, % chargeable',
            v_row.days_past_due, v_row.chargeable_days;
    END IF;
    IF v_row.fine_minor <> 200 OR v_row.fine_display <> 'INR 2.00' THEN
        RAISE EXCEPTION 'overdue fine for RA-1 was % (%)',
            v_row.fine_minor, v_row.fine_display;
    END IF;
    IF v_row.member_number <> 'M-R3' OR v_row.title <> 'Report Title A' THEN
        RAISE EXCEPTION 'overdue row named % on %', v_row.member_number, v_row.title;
    END IF;
END;
$$;

-- FR-10: the worklist moves with the date it is asked for.
DO $$
DECLARE
    v_rows text[];
BEGIN
    -- Nothing is past due this early in the fixture.
    SELECT coalesce(array_agg(o.barcode), ARRAY[]::text[]) INTO v_rows
    FROM overdue_loans_as_of(DATE '2026-09-01') AS o;
    IF v_rows <> ARRAY[]::text[] THEN
        RAISE EXCEPTION 'overdue list at 2026-09-01 was %', v_rows;
    END IF;

    -- RC-1 is not due until 2026-10-17, so only RA-1 shows here.
    SELECT coalesce(array_agg(o.barcode), ARRAY[]::text[]) INTO v_rows
    FROM overdue_loans_as_of(DATE '2026-10-10') AS o;
    IF v_rows <> ARRAY['RA-1'] THEN
        RAISE EXCEPTION 'overdue list at 2026-10-10 was %', v_rows;
    END IF;

    -- A loan that was overdue when it came back is not a worklist item:
    -- L2 was returned six days late and must never appear.
    IF EXISTS (
        SELECT 1 FROM overdue_loans_as_of(DATE '2026-12-31') AS o
        WHERE o.loan_id IN (SELECT l.loan_id FROM loan AS l WHERE l.returned_on IS NOT NULL)
    ) THEN
        RAISE EXCEPTION 'a returned loan appeared in the overdue list';
    END IF;
END;
$$;

-- FR-10: a loan can be past due and still owe nothing, because the
-- grace period is not part of the overdue test.
DO $$
DECLARE
    v_row record;
BEGIN
    SELECT * INTO v_row
    FROM overdue_loans_as_of(DATE '2026-10-18') AS o
    WHERE o.barcode = 'RC-1';

    IF v_row.days_past_due <> 1 THEN
        RAISE EXCEPTION 'RC-1 was % days past due on 2026-10-18', v_row.days_past_due;
    END IF;
    IF v_row.chargeable_days <> 0 OR v_row.fine_minor <> 0 THEN
        RAISE EXCEPTION 'a loan inside its grace period owed % minor units',
            v_row.fine_minor;
    END IF;
END;
$$;

-- FR-10: the per-title summary matches the fixture, column by column.
DO $$
DECLARE
    v_case record;
    v_row  record;
BEGIN
    FOR v_case IN
        SELECT * FROM (VALUES
            ('Report Title A', 4, 3, 3, 1, 10.00, 300, 66.67),
            ('Report Title B', 1, 1, 1, 0, 19.00,  75, 16.67),
            ('Report Title C', 1, 1, 0, 1, NULL,  200, 16.67)
        ) AS t(title, issued, members, returned, still_open,
               avg_days, fines, share)
    LOOP
        SELECT * INTO v_row
        FROM circulation_summary_by_title(DATE '2026-09-01', DATE '2026-10-31') AS s
        WHERE s.title = v_case.title;

        IF v_row.loans_issued <> v_case.issued
           OR v_row.distinct_members <> v_case.members
           OR v_row.loans_returned <> v_case.returned
           OR v_row.loans_still_open <> v_case.still_open THEN
            RAISE EXCEPTION
                '% summarised as issued=% members=% returned=% open=%',
                v_case.title, v_row.loans_issued, v_row.distinct_members,
                v_row.loans_returned, v_row.loans_still_open;
        END IF;
        IF v_row.avg_days_held IS DISTINCT FROM v_case.avg_days THEN
            RAISE EXCEPTION 'average days held for % was %, expected %',
                v_case.title, v_row.avg_days_held, v_case.avg_days;
        END IF;
        IF v_row.fines_minor <> v_case.fines THEN
            RAISE EXCEPTION 'fines for % were %, expected %',
                v_case.title, v_row.fines_minor, v_case.fines;
        END IF;
        IF v_row.share_of_loans_percent <> v_case.share THEN
            RAISE EXCEPTION 'share for % was %, expected %',
                v_case.title, v_row.share_of_loans_percent, v_case.share;
        END IF;
        IF v_row.loans_issued <> v_row.loans_returned + v_row.loans_still_open THEN
            RAISE EXCEPTION 'returned and open loans for % do not sum to the total',
                v_case.title;
        END IF;
    END LOOP;

    -- The busiest title comes first, which is what makes the report
    -- readable without sorting it again.
    SELECT * INTO v_row
    FROM circulation_summary_by_title(DATE '2026-09-01', DATE '2026-10-31') AS s
    LIMIT 1;
    IF v_row.title <> 'Report Title A' THEN
        RAISE EXCEPTION 'the summary led with %', v_row.title;
    END IF;
    IF v_row.authors <> 'Erich Gamma' THEN
        RAISE EXCEPTION 'the summary credited %', v_row.authors;
    END IF;
END;
$$;

-- FR-10: the window share adds up to the whole report.
DO $$
DECLARE
    v_total numeric;
    v_loans bigint;
BEGIN
    SELECT sum(s.share_of_loans_percent), sum(s.loans_issued)
    INTO v_total, v_loans
    FROM circulation_summary_by_title(DATE '2026-09-01', DATE '2026-10-31') AS s;

    IF v_loans <> 6 THEN
        RAISE EXCEPTION 'the period held % loans, expected 6', v_loans;
    END IF;
    -- Three rounded shares, so a hundredth of rounding error is allowed.
    IF abs(v_total - 100) > 0.01 THEN
        RAISE EXCEPTION 'shares summed to %', v_total;
    END IF;
END;
$$;

-- FR-10: an empty period is reported as no rows rather than as zeroes.
DO $$
DECLARE
    v_n bigint;
BEGIN
    SELECT count(*) INTO v_n
    FROM circulation_summary_by_title(DATE '2025-01-01', DATE '2025-01-31') AS s;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'an empty period returned % rows', v_n;
    END IF;

    SELECT count(*) INTO v_n
    FROM circulation_summary_by_month(DATE '2025-01-01', DATE '2025-01-31') AS s;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'an empty monthly period returned % rows', v_n;
    END IF;
END;
$$;

-- FR-10: the monthly summary matches the fixture and carries its total.
DO $$
DECLARE
    v_case record;
    v_row  record;
    v_n    bigint;
BEGIN
    FOR v_case IN
        SELECT * FROM (VALUES
            (DATE '2026-09-01', 3, 2, 1, 3, 1, 300),
            (DATE '2026-10-01', 3, 2, 1, 2, 3, 275)
        ) AS t(month, issued, returned, still_open, members, titles, fines)
    LOOP
        SELECT * INTO v_row
        FROM circulation_summary_by_month(DATE '2026-09-01', DATE '2026-10-31') AS s
        WHERE s.period_month = v_case.month;

        IF v_row.is_period_total THEN
            RAISE EXCEPTION '% was flagged as the period total', v_case.month;
        END IF;
        IF v_row.loans_issued <> v_case.issued
           OR v_row.loans_returned <> v_case.returned
           OR v_row.loans_still_open <> v_case.still_open
           OR v_row.distinct_members <> v_case.members
           OR v_row.distinct_titles <> v_case.titles
           OR v_row.fines_minor <> v_case.fines THEN
            RAISE EXCEPTION
                '% summarised as issued=% returned=% open=% members=% titles=% fines=%',
                v_case.month, v_row.loans_issued, v_row.loans_returned,
                v_row.loans_still_open, v_row.distinct_members,
                v_row.distinct_titles, v_row.fines_minor;
        END IF;
    END LOOP;

    -- ROLLUP adds exactly one total row, and it counts distinct members
    -- and titles across the whole period rather than adding the months.
    SELECT count(*) INTO v_n
    FROM circulation_summary_by_month(DATE '2026-09-01', DATE '2026-10-31') AS s
    WHERE s.is_period_total;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'the monthly report carried % total rows', v_n;
    END IF;

    SELECT * INTO v_row
    FROM circulation_summary_by_month(DATE '2026-09-01', DATE '2026-10-31') AS s
    WHERE s.is_period_total;
    IF v_row.period_month IS NOT NULL THEN
        RAISE EXCEPTION 'the total row claimed month %', v_row.period_month;
    END IF;
    IF v_row.loans_issued <> 6 OR v_row.loans_returned <> 4
       OR v_row.loans_still_open <> 2 OR v_row.fines_minor <> 575 THEN
        RAISE EXCEPTION
            'the period total was issued=% returned=% open=% fines=%',
            v_row.loans_issued, v_row.loans_returned,
            v_row.loans_still_open, v_row.fines_minor;
    END IF;
    IF v_row.distinct_members <> 3 OR v_row.distinct_titles <> 3 THEN
        RAISE EXCEPTION 'the period total counted % members and % titles',
            v_row.distinct_members, v_row.distinct_titles;
    END IF;
END;
$$;

-- FR-10: the two reports agree with each other and with the loan table.
DO $$
DECLARE
    v_by_title bigint;
    v_by_month bigint;
    v_direct   bigint;
BEGIN
    SELECT sum(s.loans_issued) INTO v_by_title
    FROM circulation_summary_by_title(DATE '2026-09-01', DATE '2026-10-31') AS s;

    SELECT s.loans_issued INTO v_by_month
    FROM circulation_summary_by_month(DATE '2026-09-01', DATE '2026-10-31') AS s
    WHERE s.is_period_total;

    SELECT count(*) INTO v_direct FROM loan AS l
    WHERE l.issued_on BETWEEN DATE '2026-09-01' AND DATE '2026-10-31';

    IF v_by_title <> v_direct OR v_by_month <> v_direct THEN
        RAISE EXCEPTION 'loan counts disagree: by title %, by month %, direct %',
            v_by_title, v_by_month, v_direct;
    END IF;
END;
$$;

ROLLBACK;
