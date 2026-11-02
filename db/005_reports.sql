-- ShelfSense migration 005: overdue and circulation reports.
-- Apply after db/004_holds.sql. Implements FR-10, described in
-- docs/discovery-and-reporting.md, section 4.
--
-- Every report takes its reporting dates as arguments so a result can be
-- reproduced. The views that wrap them state CURRENT_DATE, matching the
-- loan_fine_as_of and loan_fine_statement pair from migration 002.
BEGIN;

-- Overdue worklist (FR-10).
-- An open loan is overdue once the stated date is past its due date.
-- The grace period is not part of that test: a loan can be overdue and
-- still owe nothing, which is why days_past_due and chargeable_days are
-- both reported, as in the circulation workflow.
--
-- Only open loans are listed, so returned_on is always NULL here and
-- every row is non-final. The fine columns are therefore assembled from
-- the loan row this query already holds, through the same
-- calculate_fine_minor and format_minor_amount functions the rest of
-- the project uses. Calling loan_fine_as_of once per row instead reads
-- the loan table a second time, which measured as a full extra scan of
-- all 150,000 loans to report 4,391 overdue ones.
--
-- No new index is introduced here. The driving scan uses
-- loan_open_due_on_idx, the partial index on loan(due_on) WHERE
-- returned_on IS NULL from the baseline, but dropping it changed
-- nothing measurable: 20.3 ms against 20.2 ms, because the planner fell
-- back to the other partial index on open loans and both restrict the
-- scan to the 5,000 open loans rather than all 150,000. That
-- measurement does not settle whether the index earns its place, since
-- the dataset leaves 88% of open loans overdue and a real library would
-- not. See docs/query-performance.md.
CREATE FUNCTION overdue_loans_as_of(p_as_of date DEFAULT CURRENT_DATE)
RETURNS TABLE (
    loan_id bigint,
    barcode text,
    title text,
    member_number text,
    full_name text,
    issued_on date,
    due_on date,
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
        c.barcode,
        b.title,
        m.member_number,
        m.full_name,
        l.issued_on,
        l.due_on,
        GREATEST(0, p_as_of - l.due_on),
        GREATEST(0, p_as_of - l.due_on - l.grace_days),
        calculate_fine_minor(
            l.due_on, l.returned_on, p_as_of,
            l.grace_days, l.fine_minor_per_day, l.max_fine_minor
        ),
        pol.currency_code,
        format_minor_amount(
            calculate_fine_minor(
                l.due_on, l.returned_on, p_as_of,
                l.grace_days, l.fine_minor_per_day, l.max_fine_minor
            )::bigint,
            pol.currency_code,
            pol.currency_minor_digits
        )
    FROM loan AS l
    JOIN copy AS c ON c.copy_id = l.copy_id
    JOIN book AS b ON b.book_id = c.book_id
    JOIN member AS m ON m.member_id = l.member_id
    JOIN circulation_policy AS pol ON pol.policy_id = l.policy_id
    WHERE l.returned_on IS NULL
      AND l.due_on < p_as_of
    ORDER BY l.due_on, l.loan_id;
$$;

COMMENT ON FUNCTION overdue_loans_as_of(date) IS
    'Open loans past their due date at a stated date, with borrower, title, and the fine so far.';

CREATE VIEW overdue_loans AS
SELECT * FROM overdue_loans_as_of(CURRENT_DATE);

COMMENT ON VIEW overdue_loans IS
    'Open loans past their due date today, ordered oldest first.';

-- Circulation by title (FR-10).
-- The period selects loans by issue date, so a loan belongs to the
-- period in which it left the shelf. A loan still open at the end of the
-- period has its fine computed as of p_to, which keeps the report
-- reproducible for a closed period.
--
-- share_of_loans_percent is a window aggregate over the grouped rows: it
-- divides each title's loans by the report's own total without a second
-- pass over the loan table.
CREATE FUNCTION circulation_summary_by_title(
    p_from date,
    p_to date
) RETURNS TABLE (
    book_id bigint,
    title text,
    authors text,
    loans_issued bigint,
    distinct_members bigint,
    loans_returned bigint,
    loans_still_open bigint,
    avg_days_held numeric,
    fines_minor bigint,
    share_of_loans_percent numeric
)
LANGUAGE sql
STABLE
AS $$
    WITH period_loans AS (
        SELECT
            c.book_id AS pl_book_id,
            l.member_id AS pl_member_id,
            l.issued_on AS pl_issued_on,
            l.returned_on AS pl_returned_on,
            calculate_fine_minor(
                l.due_on, l.returned_on, p_to,
                l.grace_days, l.fine_minor_per_day, l.max_fine_minor
            ) AS pl_fine_minor
        FROM loan AS l
        JOIN copy AS c ON c.copy_id = l.copy_id
        WHERE l.issued_on BETWEEN p_from AND p_to
    ),
    per_title AS (
        SELECT
            pl.pl_book_id AS t_book_id,
            count(*) AS t_loans_issued,
            count(DISTINCT pl.pl_member_id) AS t_distinct_members,
            count(*) FILTER (WHERE pl.pl_returned_on IS NOT NULL) AS t_loans_returned,
            count(*) FILTER (WHERE pl.pl_returned_on IS NULL) AS t_loans_still_open,
            round(
                avg(pl.pl_returned_on - pl.pl_issued_on)
                    FILTER (WHERE pl.pl_returned_on IS NOT NULL),
                2
            ) AS t_avg_days_held,
            sum(pl.pl_fine_minor)::bigint AS t_fines_minor
        FROM period_loans AS pl
        GROUP BY pl.pl_book_id
    ),
    -- One grouped pass over the credits of the titles this report
    -- covers. Calling title_authors() per output row instead costs an
    -- index lookup per title, which measured as 160,000 buffer hits on
    -- a report of 20,000 titles against 2,000 for the aggregate.
    title_credits AS (
        SELECT
            ba.book_id AS tc_book_id,
            string_agg(au.display_name, '; ' ORDER BY ba.author_order) AS tc_authors
        FROM book_author AS ba
        JOIN author AS au ON au.author_id = ba.author_id
        JOIN per_title AS pt ON pt.t_book_id = ba.book_id
        GROUP BY ba.book_id
    )
    SELECT
        pt.t_book_id,
        b.title,
        tc.tc_authors,
        pt.t_loans_issued,
        pt.t_distinct_members,
        pt.t_loans_returned,
        pt.t_loans_still_open,
        pt.t_avg_days_held,
        pt.t_fines_minor,
        round(100.0 * pt.t_loans_issued / sum(pt.t_loans_issued) OVER (), 2)
    FROM per_title AS pt
    JOIN book AS b ON b.book_id = pt.t_book_id
    LEFT JOIN title_credits AS tc ON tc.tc_book_id = pt.t_book_id
    ORDER BY pt.t_loans_issued DESC, b.title, pt.t_book_id;
$$;

COMMENT ON FUNCTION circulation_summary_by_title(date, date) IS
    'Loans issued per title in a period, with borrowers, returns, average days held, and fines.';

-- Circulation by month (FR-10).
-- Loans are grouped by the month they were issued in. ROLLUP adds the
-- period total as one extra row, and GROUPING() marks it, so staff and
-- tests can tell the total apart from a month without summing the
-- report themselves.
CREATE FUNCTION circulation_summary_by_month(
    p_from date,
    p_to date
) RETURNS TABLE (
    period_month date,
    is_period_total boolean,
    loans_issued bigint,
    loans_returned bigint,
    loans_still_open bigint,
    distinct_members bigint,
    distinct_titles bigint,
    fines_minor bigint
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        g.m_period_month,
        g.m_is_total,
        g.m_loans_issued,
        g.m_loans_returned,
        g.m_loans_still_open,
        g.m_distinct_members,
        g.m_distinct_titles,
        g.m_fines_minor
    FROM (
        SELECT
            CASE
                WHEN GROUPING(date_trunc('month', l.issued_on)) = 1 THEN NULL
                ELSE date_trunc('month', l.issued_on)::date
            END AS m_period_month,
            GROUPING(date_trunc('month', l.issued_on)) = 1 AS m_is_total,
            count(*) AS m_loans_issued,
            count(*) FILTER (WHERE l.returned_on IS NOT NULL) AS m_loans_returned,
            count(*) FILTER (WHERE l.returned_on IS NULL) AS m_loans_still_open,
            count(DISTINCT l.member_id) AS m_distinct_members,
            count(DISTINCT c.book_id) AS m_distinct_titles,
            sum(
                calculate_fine_minor(
                    l.due_on, l.returned_on, p_to,
                    l.grace_days, l.fine_minor_per_day, l.max_fine_minor
                )
            )::bigint AS m_fines_minor
        FROM loan AS l
        JOIN copy AS c ON c.copy_id = l.copy_id
        WHERE l.issued_on BETWEEN p_from AND p_to
        GROUP BY ROLLUP (date_trunc('month', l.issued_on))
        -- ROLLUP produces its grand-total group even when no loan fell
        -- in the period, which would report a period with no
        -- circulation as one row of zeroes. A period with no loans has
        -- nothing to total, so the empty report is empty, as it is in
        -- circulation_summary_by_title.
        HAVING count(*) > 0
    ) AS g
    ORDER BY g.m_is_total, g.m_period_month;
$$;

COMMENT ON FUNCTION circulation_summary_by_month(date, date) IS
    'Loans issued per month in a period, plus one ROLLUP row carrying the period total.';

COMMIT;
