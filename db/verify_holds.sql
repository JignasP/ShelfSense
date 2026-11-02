-- Deterministic checks for the hold queue in db/004_holds.sql. Assumes a
-- disposable database with every migration applied and no existing
-- records. Every fixture is rolled back at the end, so a passing run
-- prints nothing.
--
-- Concurrency is not checked here; one psql session cannot race itself.
-- See scripts/verify_hold_concurrency.sh for the two-session check that
-- competing issues cannot over-allocate a queued title.
BEGIN;

INSERT INTO circulation_policy (
    loan_limit, loan_days, grace_days, fine_minor_per_day, max_fine_minor,
    currency_code, currency_minor_digits
) VALUES (5, 14, 2, 25, 200, 'INR', 2);

INSERT INTO book (title, isbn13) VALUES ('Hold Test Title', '9780307474278');

INSERT INTO copy (book_id, barcode)
SELECT b.book_id, v.barcode
FROM (VALUES ('HT-1'), ('HT-2'), ('HT-3')) AS v(barcode)
JOIN book AS b ON b.isbn13 = '9780307474278';

INSERT INTO member (member_number, full_name, active) VALUES
    ('M-H1', 'Hold Member One',   true),
    ('M-H2', 'Hold Member Two',   true),
    ('M-H3', 'Hold Member Three', true),
    ('M-H4', 'Walk-in Member',    true),
    ('M-HOFF', 'Inactive Member', false);

-- FR-11: placing a hold refuses the inputs it cannot act on.
DO $$
DECLARE
    v_book_id bigint;
    v_absent  bigint;
BEGIN
    SELECT b.book_id INTO v_book_id FROM book AS b WHERE b.isbn13 = '9780307474278';
    SELECT max(b.book_id) + 1000 INTO v_absent FROM book AS b;

    BEGIN
        PERFORM place_hold('M-MISSING', v_book_id);
        RAISE EXCEPTION 'a hold was placed for an unknown member';
    EXCEPTION WHEN SQLSTATE 'SS001' THEN NULL;
    END;

    BEGIN
        PERFORM place_hold('M-HOFF', v_book_id);
        RAISE EXCEPTION 'an inactive member placed a hold';
    EXCEPTION WHEN SQLSTATE 'SS002' THEN NULL;
    END;

    BEGIN
        PERFORM place_hold('M-H1', v_absent);
        RAISE EXCEPTION 'a hold was placed on a title that does not exist';
    EXCEPTION WHEN SQLSTATE 'SS012' THEN NULL;
    END;

    IF (SELECT count(*) FROM hold) <> 0 THEN
        RAISE EXCEPTION 'a rejected place_hold created a hold row';
    END IF;
END;
$$;

-- FR-11: a member cannot hold the same title twice at once.
DO $$
DECLARE
    v_book_id bigint;
    v_hold    hold%ROWTYPE;
BEGIN
    SELECT b.book_id INTO v_book_id FROM book AS b WHERE b.isbn13 = '9780307474278';

    SELECT * INTO v_hold FROM place_hold('M-H1', v_book_id);
    IF v_hold.status <> 'active' THEN
        RAISE EXCEPTION 'a new hold has status %', v_hold.status;
    END IF;
    IF v_hold.canceled_at IS NOT NULL
       OR v_hold.fulfilled_at IS NOT NULL
       OR v_hold.fulfilled_loan_id IS NOT NULL THEN
        RAISE EXCEPTION 'a new hold already carries a resolution';
    END IF;

    BEGIN
        PERFORM place_hold('M-H1', v_book_id);
        RAISE EXCEPTION 'a duplicate active hold was accepted';
    EXCEPTION WHEN SQLSTATE 'SS013' THEN NULL;
    END;

    IF (SELECT count(*) FROM hold WHERE status = 'active') <> 1 THEN
        RAISE EXCEPTION 'the rejected duplicate changed the active hold count';
    END IF;

    PERFORM place_hold('M-H2', v_book_id);
    PERFORM place_hold('M-H3', v_book_id);
END;
$$;

-- FR-11: the queue is numbered in request order.
DO $$
DECLARE
    v_order text[];
BEGIN
    SELECT array_agg(q.member_number ORDER BY q.queue_position)
    INTO v_order
    FROM hold_queue AS q;

    IF v_order <> ARRAY['M-H1', 'M-H2', 'M-H3'] THEN
        RAISE EXCEPTION 'queue order was %', v_order;
    END IF;
END;
$$;

-- FR-11: with as many holds as free copies, a walk-in is refused.
DO $$
DECLARE
    v_loans_before bigint;
BEGIN
    SELECT count(*) INTO v_loans_before FROM loan;

    BEGIN
        PERFORM issue_copy('M-H4', 'HT-1', DATE '2026-10-01');
        RAISE EXCEPTION 'a walk-in took a copy reserved by the queue';
    EXCEPTION WHEN SQLSTATE 'SS007' THEN NULL;
    END;

    IF (SELECT count(*) FROM loan) <> v_loans_before THEN
        RAISE EXCEPTION 'a rejected issue created a loan row';
    END IF;
END;
$$;

-- FR-11: cancelling keeps the row and releases the copy it reserved.
DO $$
DECLARE
    v_hold_id bigint;
    v_hold    hold%ROWTYPE;
BEGIN
    SELECT h.hold_id INTO v_hold_id
    FROM hold AS h
    JOIN member AS m ON m.member_id = h.member_id
    WHERE m.member_number = 'M-H3' AND h.status = 'active';

    SELECT * INTO v_hold FROM cancel_hold(v_hold_id);
    IF v_hold.status <> 'canceled' THEN
        RAISE EXCEPTION 'a cancelled hold has status %', v_hold.status;
    END IF;
    IF v_hold.canceled_at IS NULL THEN
        RAISE EXCEPTION 'a cancelled hold has no cancellation time';
    END IF;

    -- The row is still there; cancellation is recorded, not erased.
    IF NOT EXISTS (SELECT 1 FROM hold WHERE hold_id = v_hold_id) THEN
        RAISE EXCEPTION 'cancelling deleted the hold row';
    END IF;
    IF (SELECT count(*) FROM hold_queue) <> 2 THEN
        RAISE EXCEPTION 'a cancelled hold is still in the queue';
    END IF;

    -- Two holds now wait for three free copies, so a walk-in may borrow
    -- without taking a copy either of them needs.
    PERFORM issue_copy('M-H4', 'HT-1', DATE '2026-10-01');

    IF (SELECT count(*) FROM hold WHERE status = 'active') <> 2 THEN
        RAISE EXCEPTION 'a walk-in issue resolved somebody else''s hold';
    END IF;
END;
$$;

-- FR-11: the member at the front of the queue is served, and the issue
-- that serves them is recorded on the hold.
DO $$
DECLARE
    v_hold record;
    v_loan loan%ROWTYPE;
BEGIN
    SELECT * INTO v_loan FROM issue_copy('M-H1', 'HT-2', DATE '2026-10-02');

    SELECT h.* INTO v_hold
    FROM hold AS h
    JOIN member AS m ON m.member_id = h.member_id
    WHERE m.member_number = 'M-H1';

    IF v_hold.status <> 'fulfilled' THEN
        RAISE EXCEPTION 'the front hold was left as %', v_hold.status;
    END IF;
    IF v_hold.fulfilled_loan_id <> v_loan.loan_id THEN
        RAISE EXCEPTION 'the hold points at loan % but the issue made loan %',
            v_hold.fulfilled_loan_id, v_loan.loan_id;
    END IF;
    IF v_hold.fulfilled_at IS NULL THEN
        RAISE EXCEPTION 'a fulfilled hold has no fulfillment time';
    END IF;

    -- The member behind them keeps their place, and moves up.
    IF (SELECT q.member_number FROM hold_queue AS q WHERE q.queue_position = 1)
            <> 'M-H2' THEN
        RAISE EXCEPTION 'the queue did not advance after fulfillment';
    END IF;
END;
$$;

-- FR-11: a member whose hold was cancelled has no place in the queue,
-- and the one hold left still reserves the last free copy.
DO $$
BEGIN
    BEGIN
        PERFORM issue_copy('M-H3', 'HT-3', DATE '2026-10-03');
        RAISE EXCEPTION 'a cancelled hold still won a copy';
    EXCEPTION WHEN SQLSTATE 'SS007' THEN NULL;
    END;

    PERFORM issue_copy('M-H2', 'HT-3', DATE '2026-10-03');

    IF (SELECT count(*) FROM hold_queue) <> 0 THEN
        RAISE EXCEPTION 'the queue is not empty after every hold resolved';
    END IF;
END;
$$;

-- FR-11: resolved holds are history, and every resolution is consistent.
DO $$
DECLARE
    v_counts record;
BEGIN
    SELECT
        count(*) AS total,
        count(*) FILTER (WHERE status = 'active')    AS active,
        count(*) FILTER (WHERE status = 'canceled')  AS canceled,
        count(*) FILTER (WHERE status = 'fulfilled') AS fulfilled
    INTO v_counts
    FROM hold;

    IF (v_counts.total, v_counts.active, v_counts.canceled, v_counts.fulfilled)
            IS DISTINCT FROM (3::bigint, 0::bigint, 1::bigint, 2::bigint) THEN
        RAISE EXCEPTION 'hold history was total=% active=% canceled=% fulfilled=%',
            v_counts.total, v_counts.active, v_counts.canceled, v_counts.fulfilled;
    END IF;

    -- Every fulfilled hold names a loan of the same title, taken by the
    -- same member. That is what makes fulfillment auditable.
    IF EXISTS (
        SELECT 1
        FROM hold AS h
        JOIN loan AS l ON l.loan_id = h.fulfilled_loan_id
        JOIN copy AS c ON c.copy_id = l.copy_id
        WHERE h.status = 'fulfilled'
          AND (c.book_id <> h.book_id OR l.member_id <> h.member_id)
    ) THEN
        RAISE EXCEPTION 'a fulfilled hold points at an unrelated loan';
    END IF;
END;
$$;

-- FR-11: a hold can only be resolved once.
DO $$
DECLARE
    v_canceled  bigint;
    v_fulfilled bigint;
    v_absent    bigint;
BEGIN
    SELECT h.hold_id INTO v_canceled  FROM hold AS h WHERE h.status = 'canceled';
    SELECT h.hold_id INTO v_fulfilled FROM hold AS h WHERE h.status = 'fulfilled' LIMIT 1;
    SELECT max(h.hold_id) + 1000 INTO v_absent FROM hold AS h;

    BEGIN
        PERFORM cancel_hold(v_canceled);
        RAISE EXCEPTION 'a cancelled hold was cancelled again';
    EXCEPTION WHEN SQLSTATE 'SS015' THEN NULL;
    END;

    BEGIN
        PERFORM cancel_hold(v_fulfilled);
        RAISE EXCEPTION 'a fulfilled hold was cancelled';
    EXCEPTION WHEN SQLSTATE 'SS015' THEN NULL;
    END;

    BEGIN
        PERFORM cancel_hold(v_absent);
        RAISE EXCEPTION 'a hold that does not exist was cancelled';
    EXCEPTION WHEN SQLSTATE 'SS014' THEN NULL;
    END;

    -- The cancelled hold is spent, so the member may queue again.
    PERFORM place_hold(
        'M-H3',
        (SELECT b.book_id FROM book AS b WHERE b.isbn13 = '9780307474278')
    );
    IF (SELECT count(*) FROM hold_queue) <> 1 THEN
        RAISE EXCEPTION 'a member could not re-queue after cancelling';
    END IF;
    IF (SELECT count(*) FROM hold) <> 4 THEN
        RAISE EXCEPTION 're-queueing did not add a new row to the history';
    END IF;
END;
$$;

-- FR-11: the status columns cannot disagree with the status.
DO $$
DECLARE
    v_hold_id bigint;
BEGIN
    SELECT h.hold_id INTO v_hold_id FROM hold AS h WHERE h.status = 'active';

    BEGIN
        UPDATE hold SET canceled_at = clock_timestamp() WHERE hold_id = v_hold_id;
        RAISE EXCEPTION 'an active hold accepted a cancellation time';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE hold SET status = 'fulfilled', fulfilled_at = clock_timestamp()
        WHERE hold_id = v_hold_id;
        RAISE EXCEPTION 'a hold was fulfilled without naming a loan';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE hold SET status = 'expired' WHERE hold_id = v_hold_id;
        RAISE EXCEPTION 'an unknown hold status was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END;
$$;

ROLLBACK;
