-- ShelfSense migration 002: circulation workflow.
-- Apply after db/001_baseline.sql. Implements the issue and return
-- transactions described in the Architecture Description, section 4,
-- and the fine presentation required by QR-04.
--
-- Business failures are raised with project SQLSTATE codes in class SS so
-- the server layer can map them to staff-readable messages without parsing
-- text. The codes are listed in docs/circulation-workflow.md.
BEGIN;

-- Currency configuration (SRS section 4, QR-04).
-- The currency is deployment configuration rather than a project decision,
-- so the column defaults to ISO 4217 'XXX' ("no currency") and an
-- administrator sets the real code. Mixed currencies are out of scope, so
-- the code belongs on the single policy row and not on every loan.
ALTER TABLE circulation_policy
    ADD COLUMN currency_code char(3) NOT NULL DEFAULT 'XXX',
    ADD COLUMN currency_minor_digits smallint NOT NULL DEFAULT 2;

ALTER TABLE circulation_policy
    ADD CONSTRAINT circulation_policy_currency_code_format
        CHECK (currency_code ~ '^[A-Z]{3}$'),
    ADD CONSTRAINT circulation_policy_currency_minor_digits_range
        CHECK (currency_minor_digits BETWEEN 0 AND 4);

COMMENT ON COLUMN circulation_policy.currency_code IS
    'ISO 4217 alphabetic code for every minor-unit amount; XXX until configured.';
COMMENT ON COLUMN circulation_policy.currency_minor_digits IS
    'Digits after the decimal separator when minor units are displayed.';

-- Hold rule evaluation point (FR-11).
-- The hold schema is a later decision and no hold table exists yet, so no
-- hold can block an issue today. issue_copy calls this inside its own
-- transaction and after it has taken its row locks, so replacing the body
-- in the holds phase does not move where the rule is evaluated.
CREATE FUNCTION hold_permits_issue(p_copy_id bigint, p_member_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT true;
$$;

COMMENT ON FUNCTION hold_permits_issue(bigint, bigint) IS
    'Hold rule checked during issue. Always true until the holds phase defines a hold table.';

-- Issue transaction (FR-03, FR-04, FR-05, QR-01, QR-02).
CREATE FUNCTION issue_copy(
    p_member_number text,
    p_barcode text,
    p_issued_on date DEFAULT CURRENT_DATE
) RETURNS loan
LANGUAGE plpgsql
AS $$
DECLARE
    v_policy circulation_policy%ROWTYPE;
    v_member member%ROWTYPE;
    v_copy   copy%ROWTYPE;
    v_open_loans integer;
    v_loan   loan%ROWTYPE;
BEGIN
    SELECT * INTO v_policy FROM circulation_policy WHERE policy_id = 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'circulation policy is not configured'
            USING ERRCODE = 'SS010',
                  HINT = 'Insert the single circulation_policy row before issuing loans.';
    END IF;

    -- Lock the member row first, then the copy row. return_copy takes the
    -- copy row and never the member row, so no two circulation
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
            USING ERRCODE = 'SS007';
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

    RETURN v_loan;
END;
$$;

COMMENT ON FUNCTION issue_copy(text, text, date) IS
    'Issues one copy to one member in a single transaction and returns the new loan row.';

-- Return transaction (FR-06, QR-01).
CREATE FUNCTION return_copy(
    p_barcode text,
    p_returned_on date DEFAULT CURRENT_DATE
) RETURNS loan
LANGUAGE plpgsql
AS $$
DECLARE
    v_copy copy%ROWTYPE;
    v_loan loan%ROWTYPE;
    v_history integer;
BEGIN
    -- Locking the copy row before reading its open loan makes two
    -- simultaneous returns of one copy serial, so the second sees the
    -- committed return date and is rejected rather than overwriting it.
    SELECT * INTO v_copy FROM copy
        WHERE barcode = p_barcode
        FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no copy with barcode %', p_barcode
            USING ERRCODE = 'SS003';
    END IF;

    SELECT * INTO v_loan FROM loan
        WHERE copy_id = v_copy.copy_id AND returned_on IS NULL
        FOR UPDATE;
    IF NOT FOUND THEN
        SELECT count(*) INTO v_history FROM loan WHERE copy_id = v_copy.copy_id;
        IF v_history > 0 THEN
            RAISE EXCEPTION 'copy % has already been returned', p_barcode
                USING ERRCODE = 'SS009';
        END IF;
        RAISE EXCEPTION 'copy % is not on loan', p_barcode
            USING ERRCODE = 'SS008';
    END IF;

    IF p_returned_on < v_loan.issued_on THEN
        RAISE EXCEPTION 'return date % precedes the issue date % on loan %',
                p_returned_on, v_loan.issued_on, v_loan.loan_id
            USING ERRCODE = 'SS011';
    END IF;

    UPDATE loan
        SET returned_on = p_returned_on
        WHERE loan_id = v_loan.loan_id AND returned_on IS NULL
        RETURNING * INTO v_loan;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'copy % has already been returned', p_barcode
            USING ERRCODE = 'SS009';
    END IF;

    RETURN v_loan;
END;
$$;

COMMENT ON FUNCTION return_copy(text, date) IS
    'Records the return date on the open loan for one copy, once, and returns the closed loan.';

-- Amount presentation (QR-04).
CREATE FUNCTION format_minor_amount(
    p_amount_minor bigint,
    p_currency_code char(3),
    p_minor_digits integer
) RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT p_currency_code || ' ' ||
        CASE WHEN p_minor_digits = 0
            THEN to_char(p_amount_minor, 'FM999999990')
            ELSE to_char(
                p_amount_minor::numeric / (10::numeric ^ p_minor_digits),
                'FM999999990.' || repeat('0', p_minor_digits)
            )
        END;
$$;

COMMENT ON FUNCTION format_minor_amount(bigint, char, integer) IS
    'Renders a minor-unit amount with its currency code, for display only.';

-- Fine for one loan at a stated date (FR-07, QR-04).
-- A returned loan ignores the requested date and reports its return date,
-- so a final fine does not change after the return is recorded.
CREATE FUNCTION loan_fine_as_of(
    p_loan_id bigint,
    p_as_of_date date DEFAULT CURRENT_DATE
) RETURNS TABLE (
    loan_id bigint,
    as_of_date date,
    is_final boolean,
    days_past_due integer,
    chargeable_days integer,
    fine_minor integer,
    currency_code char(3),
    fine_display text
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        l.loan_id,
        COALESCE(l.returned_on, p_as_of_date),
        l.returned_on IS NOT NULL,
        GREATEST(0, COALESCE(l.returned_on, p_as_of_date) - l.due_on),
        GREATEST(0, COALESCE(l.returned_on, p_as_of_date) - l.due_on - l.grace_days),
        calculate_fine_minor(
            l.due_on, l.returned_on, p_as_of_date,
            l.grace_days, l.fine_minor_per_day, l.max_fine_minor
        ),
        pol.currency_code,
        format_minor_amount(
            calculate_fine_minor(
                l.due_on, l.returned_on, p_as_of_date,
                l.grace_days, l.fine_minor_per_day, l.max_fine_minor
            )::bigint,
            pol.currency_code,
            pol.currency_minor_digits
        )
    FROM loan AS l
    JOIN circulation_policy AS pol ON pol.policy_id = l.policy_id
    WHERE l.loan_id = p_loan_id;
$$;

COMMENT ON FUNCTION loan_fine_as_of(bigint, date) IS
    'Fine for one loan at a stated date, with the as-of date and currency for display.';

-- Staff-facing circulation statement (QR-04).
CREATE VIEW loan_fine_statement AS
SELECT
    l.loan_id,
    c.barcode,
    b.title,
    m.member_number,
    m.full_name,
    l.issued_on,
    l.due_on,
    l.returned_on,
    f.as_of_date,
    f.is_final,
    f.days_past_due,
    f.chargeable_days,
    f.fine_minor,
    f.currency_code,
    f.fine_display
FROM loan AS l
JOIN copy AS c ON c.copy_id = l.copy_id
JOIN book AS b ON b.book_id = c.book_id
JOIN member AS m ON m.member_id = l.member_id
CROSS JOIN LATERAL loan_fine_as_of(l.loan_id, CURRENT_DATE) AS f;

COMMENT ON VIEW loan_fine_statement IS
    'One row per loan with the borrower, the dates, and the fine as of the current date.';

COMMIT;
