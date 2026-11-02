-- ShelfSense migration 004: title hold queue.
-- Apply after db/003_discovery.sql. Implements FR-11, described in
-- docs/discovery-and-reporting.md, section 3.
--
-- Migration 002 reserved hold_permits_issue as the point where the hold
-- rule is evaluated and SS007 as its rejection. This migration replaces
-- that function body with the real rule and gives issue_copy the
-- fulfillment step, which the rule function cannot do itself: it is
-- STABLE and runs before the loan row exists.
--
-- A hold is held against a title, not a copy. A member waits for the
-- work, and any copy of it satisfies the wait.
BEGIN;

CREATE TABLE hold (
    hold_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    book_id bigint NOT NULL REFERENCES book(book_id) ON DELETE RESTRICT,
    member_id bigint NOT NULL REFERENCES member(member_id) ON DELETE RESTRICT,
    status text NOT NULL DEFAULT 'active',
    placed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    canceled_at timestamptz,
    fulfilled_at timestamptz,
    fulfilled_loan_id bigint REFERENCES loan(loan_id) ON DELETE RESTRICT,
    CONSTRAINT hold_status_known CHECK (status IN ('active', 'canceled', 'fulfilled')),
    -- Each state owns exactly the columns that belong to it, so a row
    -- cannot claim to be active while carrying a cancellation, or claim
    -- fulfillment without naming the loan that fulfilled it.
    CONSTRAINT hold_status_fields CHECK (
        CASE status
            WHEN 'active' THEN
                canceled_at IS NULL AND fulfilled_at IS NULL AND fulfilled_loan_id IS NULL
            WHEN 'canceled' THEN
                canceled_at IS NOT NULL AND fulfilled_at IS NULL AND fulfilled_loan_id IS NULL
            WHEN 'fulfilled' THEN
                canceled_at IS NULL AND fulfilled_at IS NOT NULL AND fulfilled_loan_id IS NOT NULL
        END
    ),
    CONSTRAINT hold_resolution_order CHECK (
        (canceled_at IS NULL OR canceled_at >= placed_at)
        AND (fulfilled_at IS NULL OR fulfilled_at >= placed_at)
    )
);

COMMENT ON TABLE hold IS
    'A member''s request for a title. Resolved rows are kept, never deleted, so the queue has a history.';
COMMENT ON COLUMN hold.status IS
    'active (waiting), canceled (withdrawn), or fulfilled (a copy was issued to this member).';
COMMENT ON COLUMN hold.placed_at IS
    'When the hold row was created, from clock_timestamp() so holds placed in one transaction still differ.';
COMMENT ON COLUMN hold.fulfilled_loan_id IS
    'The loan that fulfilled this hold, which is the evidence that fulfillment happened.';

-- One active hold per member per title. A member cannot queue twice for
-- the same work; a canceled or fulfilled hold does not block a new one,
-- which is why the index is partial on the active status.
CREATE UNIQUE INDEX hold_one_active_per_member_title_idx
    ON hold(book_id, member_id) WHERE status = 'active';

-- A queue read is ordered by placed_at, with hold_id breaking any tie so
-- the order is total and stable. No separate index is added for that
-- ordering: hold_one_active_per_member_title_idx above is already
-- partial on active holds and leads with book_id, so it serves the same
-- lookups. An index on (book_id, placed_at, hold_id) was measured
-- against it and read one title's queue in 20 buffers against 26, with
-- no gain in time, which does not pay for a second index to maintain on
-- every hold written. measure_query_plans.sh still runs that comparison
-- so the decision can be rechecked; a library with queues long enough to
-- make the ordering matter should do so before adding one.
CREATE INDEX hold_member_id_idx ON hold(member_id);
CREATE INDEX hold_fulfilled_loan_id_idx ON hold(fulfilled_loan_id);

-- The active queue for every title, in request order (FR-11).
CREATE VIEW hold_queue AS
SELECT
    h.hold_id,
    h.book_id,
    b.title,
    m.member_id,
    m.member_number,
    m.full_name,
    h.placed_at,
    row_number() OVER (
        PARTITION BY h.book_id
        ORDER BY h.placed_at, h.hold_id
    ) AS queue_position
FROM hold AS h
JOIN book AS b ON b.book_id = h.book_id
JOIN member AS m ON m.member_id = h.member_id
WHERE h.status = 'active';

COMMENT ON VIEW hold_queue IS
    'Active holds with their 1-based position in their title''s queue.';

-- Placing a hold (FR-11).
-- Locks are taken member before book, the order issue_copy uses, so the
-- two cannot deadlock against each other. The member row is only read,
-- so a share lock is enough; issue_copy needs an exclusive lock there
-- because it counts that member's own open loans.
CREATE FUNCTION place_hold(
    p_member_number text,
    p_book_id bigint
) RETURNS hold
LANGUAGE plpgsql
AS $$
DECLARE
    v_member member%ROWTYPE;
    v_book   book%ROWTYPE;
    v_hold   hold%ROWTYPE;
BEGIN
    SELECT * INTO v_member FROM member
        WHERE member_number = p_member_number
        FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no member with number %', p_member_number
            USING ERRCODE = 'SS001';
    END IF;
    IF NOT v_member.active THEN
        RAISE EXCEPTION 'member % is not active', p_member_number
            USING ERRCODE = 'SS002';
    END IF;

    SELECT * INTO v_book FROM book
        WHERE book_id = p_book_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no title with book_id %', p_book_id
            USING ERRCODE = 'SS012';
    END IF;

    BEGIN
        INSERT INTO hold (book_id, member_id)
        VALUES (v_book.book_id, v_member.member_id)
        RETURNING * INTO v_hold;
    EXCEPTION WHEN unique_violation THEN
        -- hold_one_active_per_member_title_idx is the authoritative
        -- guard, including against a competing transaction that
        -- committed its hold while this one waited.
        RAISE EXCEPTION 'member % already has an active hold on title %',
                p_member_number, p_book_id
            USING ERRCODE = 'SS013',
                  HINT = 'Cancel the existing hold before placing another.';
    END;

    RETURN v_hold;
END;
$$;

COMMENT ON FUNCTION place_hold(text, bigint) IS
    'Adds one active hold for a member on a title and returns the new hold row.';

-- Cancelling a hold (FR-11).
-- The hold row is updated, never deleted, so the cancellation is part of
-- the record. The title is read without a lock first so that the book row
-- can be locked before the hold row, keeping the queue lock order the
-- same as in issue_copy.
CREATE FUNCTION cancel_hold(p_hold_id bigint)
RETURNS hold
LANGUAGE plpgsql
AS $$
DECLARE
    v_book_id bigint;
    v_hold    hold%ROWTYPE;
BEGIN
    SELECT book_id INTO v_book_id FROM hold WHERE hold_id = p_hold_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no hold with id %', p_hold_id
            USING ERRCODE = 'SS014';
    END IF;

    PERFORM 1 FROM book WHERE book_id = v_book_id FOR UPDATE;

    SELECT * INTO v_hold FROM hold
        WHERE hold_id = p_hold_id
        FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no hold with id %', p_hold_id
            USING ERRCODE = 'SS014';
    END IF;
    IF v_hold.status <> 'active' THEN
        RAISE EXCEPTION 'hold % is already %', p_hold_id, v_hold.status
            USING ERRCODE = 'SS015';
    END IF;

    UPDATE hold
        SET status = 'canceled',
            canceled_at = clock_timestamp()
        WHERE hold_id = p_hold_id AND status = 'active'
        RETURNING * INTO v_hold;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'hold % is no longer active', p_hold_id
            USING ERRCODE = 'SS015';
    END IF;

    RETURN v_hold;
END;
$$;

COMMENT ON FUNCTION cancel_hold(bigint) IS
    'Marks one active hold canceled, keeping the row as history, and returns it.';

-- The hold rule (FR-11).
-- A hold reserves one available copy for the member waiting, so the rule
-- is a comparison of counts rather than a veto by any hold at all:
--
--   permit  <=>  copies_available > holds_ahead
--
-- holds_ahead counts the active holds that sit in front of this member
-- in the queue, or every active hold when the member holds no place in
-- it. copies_available counts this title's copies that are neither
-- withdrawn nor on an open loan, which still includes the copy about to
-- be issued, because the loan does not exist yet.
--
-- Two consequences are deliberate. A walk-in borrower is refused only
-- when taking the copy would leave someone in the queue without one, so
-- three available copies and one hold still serve a walk-in. And a hold
-- is fulfillable only once a copy remains for every hold ahead of it, so
-- no hold loses its place to a later one.
CREATE OR REPLACE FUNCTION hold_permits_issue(p_copy_id bigint, p_member_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    WITH title AS (
        SELECT c.book_id FROM copy AS c WHERE c.copy_id = p_copy_id
    ),
    own_hold AS (
        SELECT h.placed_at, h.hold_id
        FROM hold AS h
        JOIN title AS t ON t.book_id = h.book_id
        WHERE h.member_id = p_member_id
          AND h.status = 'active'
    ),
    ahead AS (
        SELECT count(*) AS holds_ahead
        FROM hold AS h
        JOIN title AS t ON t.book_id = h.book_id
        LEFT JOIN own_hold AS o ON true
        WHERE h.status = 'active'
          AND (
              o.hold_id IS NULL
              OR (h.placed_at, h.hold_id) < (o.placed_at, o.hold_id)
          )
    ),
    free AS (
        SELECT count(*) AS copies_available
        FROM copy_availability AS ca
        JOIN title AS t ON t.book_id = ca.book_id
        WHERE ca.availability_status = 'available'
    )
    SELECT free.copies_available > ahead.holds_ahead
    FROM free, ahead;
$$;

COMMENT ON FUNCTION hold_permits_issue(bigint, bigint) IS
    'True when issuing this copy to this member leaves a copy for every hold ahead of them.';

-- Issue transaction, revised for holds (FR-03, FR-04, FR-05, FR-11, QR-01, QR-02).
-- Two things change from migration 002. The book row is locked between
-- the member row and the copy row, which serialises every decision about
-- one title's queue against every other. And after the loan is inserted,
-- the member's own active hold for that title, if they had one, is
-- marked fulfilled and pointed at the new loan.
CREATE OR REPLACE FUNCTION issue_copy(
    p_member_number text,
    p_barcode text,
    p_issued_on date DEFAULT CURRENT_DATE
) RETURNS loan
LANGUAGE plpgsql
AS $$
DECLARE
    v_policy  circulation_policy%ROWTYPE;
    v_member  member%ROWTYPE;
    v_copy    copy%ROWTYPE;
    v_book_id bigint;
    v_open_loans integer;
    v_loan    loan%ROWTYPE;
BEGIN
    SELECT * INTO v_policy FROM circulation_policy WHERE policy_id = 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'circulation policy is not configured'
            USING ERRCODE = 'SS010',
                  HINT = 'Insert the single circulation_policy row before issuing loans.';
    END IF;

    -- Locks are taken member, then book, then copy. return_copy takes
    -- the copy row and neither of the others, and place_hold and
    -- cancel_hold never take a copy row, so no two circulation
    -- transactions can acquire these locks in opposite orders.
    SELECT * INTO v_member FROM member
        WHERE member_number = p_member_number
        FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no member with number %', p_member_number
            USING ERRCODE = 'SS001';
    END IF;
    IF NOT v_member.active THEN
        RAISE EXCEPTION 'member % is not active', p_member_number
            USING ERRCODE = 'SS002';
    END IF;

    -- The title is read without a lock only to learn which book row to
    -- lock. The copy itself is re-read and locked below, so a copy that
    -- disappears in between is still reported as a missing barcode.
    SELECT c.book_id INTO v_book_id FROM copy AS c WHERE c.barcode = p_barcode;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no copy with barcode %', p_barcode
            USING ERRCODE = 'SS003';
    END IF;

    PERFORM 1 FROM book WHERE book_id = v_book_id FOR UPDATE;

    SELECT * INTO v_copy FROM copy
        WHERE barcode = p_barcode
        FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no copy with barcode %', p_barcode
            USING ERRCODE = 'SS003';
    END IF;
    IF v_copy.withdrawn_on IS NOT NULL THEN
        RAISE EXCEPTION 'copy % was withdrawn on %', p_barcode, v_copy.withdrawn_on
            USING ERRCODE = 'SS004';
    END IF;

    PERFORM 1 FROM loan
        WHERE copy_id = v_copy.copy_id AND returned_on IS NULL;
    IF FOUND THEN
        RAISE EXCEPTION 'copy % already has an open loan', p_barcode
            USING ERRCODE = 'SS005';
    END IF;

    -- The member row lock above serialises two concurrent issues to the
    -- same member, so this count cannot be read twice before either insert.
    SELECT count(*) INTO v_open_loans FROM loan
        WHERE member_id = v_member.member_id AND returned_on IS NULL;
    IF v_open_loans >= v_policy.loan_limit THEN
        RAISE EXCEPTION 'member % already holds % of % permitted open loans',
                p_member_number, v_open_loans, v_policy.loan_limit
            USING ERRCODE = 'SS006';
    END IF;

    IF NOT hold_permits_issue(v_copy.copy_id, v_member.member_id) THEN
        RAISE EXCEPTION 'an active hold prevents issuing copy % to member %',
                p_barcode, p_member_number
            USING ERRCODE = 'SS007',
                  DETAIL = 'Holds ahead of this member reserve every available copy of the title.',
                  HINT = 'Check hold_queue for the title to see who is waiting.';
    END IF;

    -- Policy values are copied onto the loan so a later policy change does
    -- not rewrite the fine owed on a loan that already exists.
    BEGIN
        INSERT INTO loan (
            copy_id, member_id, policy_id, issued_on, due_on,
            grace_days, fine_minor_per_day, max_fine_minor
        )
        VALUES (
            v_copy.copy_id, v_member.member_id, v_policy.policy_id,
            p_issued_on, p_issued_on + v_policy.loan_days,
            v_policy.grace_days, v_policy.fine_minor_per_day, v_policy.max_fine_minor
        )
        RETURNING * INTO v_loan;
    EXCEPTION WHEN unique_violation THEN
        -- A competing transaction committed its open loan for this copy
        -- while this one was waiting. The partial unique index is the
        -- authoritative guard; report the conflict as a business failure.
        RAISE EXCEPTION 'copy % already has an open loan', p_barcode
            USING ERRCODE = 'SS005',
                  DETAIL = 'A concurrent issue for this copy committed first.';
    END;

    -- Fulfillment closes the member's own wait for this title. The book
    -- row lock held above serialises this against place_hold and
    -- cancel_hold, and hold_one_active_per_member_title_idx means at
    -- most one row can match.
    UPDATE hold
        SET status = 'fulfilled',
            fulfilled_at = clock_timestamp(),
            fulfilled_loan_id = v_loan.loan_id
        WHERE book_id = v_copy.book_id
          AND member_id = v_member.member_id
          AND status = 'active';

    RETURN v_loan;
END;
$$;

COMMENT ON FUNCTION issue_copy(text, text, date) IS
    'Issues one copy to one member in a single transaction, fulfilling their hold if they had one, and returns the new loan row.';

COMMIT;
