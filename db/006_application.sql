-- Staff access, circulation audit, and a daily report for the web application.
-- Apply after 005_reports.sql.
BEGIN;

CREATE TABLE staff_user (
    staff_user_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    username text NOT NULL UNIQUE CHECK (username ~ '^[a-z0-9._-]{3,40}$'),
    display_name text NOT NULL CHECK (length(btrim(display_name)) BETWEEN 1 AND 120),
    password_hash text NOT NULL CHECK (password_hash LIKE 'scrypt$%'),
    role text NOT NULL CHECK (role IN ('admin', 'librarian')),
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE staff_session (
    token_hash char(64) PRIMARY KEY CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    staff_user_id bigint NOT NULL REFERENCES staff_user(staff_user_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL CHECK (expires_at > created_at)
);

CREATE INDEX staff_session_user_id_idx ON staff_session(staff_user_id);
CREATE INDEX staff_session_expires_at_idx ON staff_session(expires_at);

-- The first account is an administrator. Subsequent staff and policy writes
-- require an active administrator in the transaction's staff identity context.
CREATE FUNCTION guard_admin_write()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_actor bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM staff_user) THEN
        IF TG_TABLE_NAME = 'staff_user' AND TG_OP = 'INSERT' THEN
            IF NEW.role = 'admin' THEN
                RETURN NEW;
            END IF;
        END IF;
        IF TG_TABLE_NAME = 'circulation_policy' THEN
            RETURN COALESCE(NEW, OLD);
        END IF;
    END IF;
    v_actor := NULLIF(current_setting('shelfsense.actor_user_id', true), '')::bigint;
    IF NOT EXISTS (SELECT 1 FROM staff_user WHERE staff_user_id = v_actor AND role = 'admin' AND active) THEN
        RAISE EXCEPTION 'active administrator required' USING ERRCODE = 'SS016';
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER staff_admin_write
BEFORE INSERT OR UPDATE OR DELETE ON staff_user
FOR EACH ROW EXECUTE FUNCTION guard_admin_write();

CREATE TRIGGER policy_admin_write
BEFORE INSERT OR UPDATE OR DELETE ON circulation_policy
FOR EACH ROW EXECUTE FUNCTION guard_admin_write();

CREATE TABLE loan_event (
    loan_event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id bigint NOT NULL REFERENCES loan(loan_id) ON DELETE CASCADE,
    event_type text NOT NULL CHECK (event_type IN ('issued', 'returned')),
    effective_on date NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    staff_user_id bigint REFERENCES staff_user(staff_user_id) ON DELETE SET NULL
);

CREATE INDEX loan_event_loan_id_idx ON loan_event(loan_id, loan_event_id);

-- A trigger is justified here because it records loan changes even when a
-- writer bypasses the application functions. Application transactions set
-- shelfsense.actor_user_id locally; direct SQL changes remain unattributed.
CREATE FUNCTION record_loan_event()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_actor bigint;
BEGIN
    v_actor := NULLIF(current_setting('shelfsense.actor_user_id', true), '')::bigint;
    IF TG_OP = 'INSERT' THEN
        INSERT INTO loan_event (loan_id, event_type, effective_on, staff_user_id)
        VALUES (NEW.loan_id, 'issued', NEW.issued_on, v_actor);
    ELSIF OLD.returned_on IS NULL AND NEW.returned_on IS NOT NULL THEN
        INSERT INTO loan_event (loan_id, event_type, effective_on, staff_user_id)
        VALUES (NEW.loan_id, 'returned', NEW.returned_on, v_actor);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER loan_event_insert
AFTER INSERT ON loan
FOR EACH ROW EXECUTE FUNCTION record_loan_event();

CREATE TRIGGER loan_event_return
AFTER UPDATE OF returned_on ON loan
FOR EACH ROW
WHEN (OLD.returned_on IS NULL AND NEW.returned_on IS NOT NULL)
EXECUTE FUNCTION record_loan_event();

-- Recursive date series includes quiet days, unlike grouping only loan rows.
-- The interface caps the requested span at 366 days to bound the recursion.
CREATE FUNCTION daily_issues(p_from date, p_to date)
RETURNS TABLE (report_date date, loans_issued bigint)
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE days(report_date) AS (
        SELECT p_from WHERE p_from <= p_to AND p_to - p_from <= 366
        UNION ALL
        SELECT report_date + 1 FROM days WHERE report_date < p_to
    )
    SELECT d.report_date, count(l.loan_id)
    FROM days AS d
    LEFT JOIN loan AS l ON l.issued_on = d.report_date
    GROUP BY d.report_date
    ORDER BY d.report_date;
$$;

COMMENT ON FUNCTION daily_issues(date, date) IS
    'Daily loan counts, including zero-activity days, for a period of at most 366 days.';

COMMIT;
