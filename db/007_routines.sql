-- Policy and session procedures; staff-session invariant.
-- Apply after 006_application.sql.
BEGIN;

-- The existing policy trigger checks the transaction's administrator actor.
-- This procedure gives callers one stable operation for the seven policy values.
CREATE PROCEDURE save_circulation_policy(
    p_loan_limit integer,
    p_loan_days integer,
    p_grace_days integer,
    p_fine_minor_per_day integer,
    p_max_fine_minor integer,
    p_currency_code char(3),
    p_currency_minor_digits integer
)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO circulation_policy (
        policy_id, loan_limit, loan_days, grace_days, fine_minor_per_day,
        max_fine_minor, currency_code, currency_minor_digits
    ) VALUES (
        1, p_loan_limit, p_loan_days, p_grace_days, p_fine_minor_per_day,
        p_max_fine_minor, p_currency_code, p_currency_minor_digits
    )
    ON CONFLICT (policy_id) DO UPDATE SET
        loan_limit = EXCLUDED.loan_limit,
        loan_days = EXCLUDED.loan_days,
        grace_days = EXCLUDED.grace_days,
        fine_minor_per_day = EXCLUDED.fine_minor_per_day,
        max_fine_minor = EXCLUDED.max_fine_minor,
        currency_code = EXCLUDED.currency_code,
        currency_minor_digits = EXCLUDED.currency_minor_digits;
END;
$$;

COMMENT ON PROCEDURE save_circulation_policy(integer, integer, integer, integer, integer, char(3), integer) IS
    'Save the single library policy. The policy_admin_write trigger requires an active administrator actor.';

-- Session lookup already rejects expired sessions. This procedure removes
-- their stored hashes and reports how many rows were removed.
CREATE PROCEDURE purge_expired_staff_sessions(
    IN p_as_of timestamptz,
    INOUT p_deleted bigint
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'as-of timestamp is required' USING ERRCODE = '22004';
    END IF;
    DELETE FROM staff_session WHERE expires_at <= p_as_of;
    GET DIAGNOSTICS p_deleted = ROW_COUNT;
END;
$$;

COMMENT ON PROCEDURE purge_expired_staff_sessions(timestamptz, bigint) IS
    'Delete expired staff sessions and return the number removed.';

-- A session row must not be created for an inactive staff account, even
-- through direct SQL. Existing sessions become unusable when staff are
-- deactivated because userFromToken also checks staff_user.active.
CREATE FUNCTION reject_session_for_inactive_staff()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM staff_user
        WHERE staff_user_id = NEW.staff_user_id AND active
        FOR SHARE
    ) THEN
        RAISE EXCEPTION 'cannot create a session for inactive staff'
            USING ERRCODE = 'SS017';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER staff_session_active_user
BEFORE INSERT OR UPDATE OF staff_user_id ON staff_session
FOR EACH ROW
EXECUTE FUNCTION reject_session_for_inactive_staff();

COMMIT;
