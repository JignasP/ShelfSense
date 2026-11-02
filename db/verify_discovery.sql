-- Deterministic checks for catalog search and copy availability in
-- db/003_discovery.sql. Assumes a disposable database with every
-- migration applied and no existing records. Every fixture is rolled
-- back at the end, so a passing run prints nothing.
BEGIN;

INSERT INTO circulation_policy (
    loan_limit, loan_days, grace_days, fine_minor_per_day, max_fine_minor,
    currency_code, currency_minor_digits
) VALUES (5, 14, 2, 25, 200, 'INR', 2);

INSERT INTO book (title, isbn13, publication_year) VALUES
    ('Database System Concepts',   '9780078022159', 2019),
    ('Introduction to Algorithms', '9780262046305', 2022),
    ('The Idiot',                  NULL,            1869),
    ('Clean Code',                 '9780132350884', 2008);

INSERT INTO author (display_name) VALUES
    ('Abraham Silberschatz'),
    ('Henry F. Korth'),
    ('Thomas H. Cormen'),
    ('Fyodor Dostoevsky'),
    ('Robert C. Martin');

INSERT INTO book_author (book_id, author_id, author_order)
SELECT b.book_id, a.author_id, v.author_order
FROM (VALUES
    ('Database System Concepts',   'Abraham Silberschatz', 1),
    ('Database System Concepts',   'Henry F. Korth',       2),
    ('Introduction to Algorithms', 'Thomas H. Cormen',     1),
    ('The Idiot',                  'Fyodor Dostoevsky',    1),
    ('Clean Code',                 'Robert C. Martin',     1)
) AS v(title, display_name, author_order)
JOIN book   AS b ON b.title = v.title
JOIN author AS a ON a.display_name = v.display_name;

-- "The Idiot" is deliberately left with no copies, so the catalog views
-- have to report a title that cannot be borrowed at all.
INSERT INTO copy (book_id, barcode)
SELECT b.book_id, v.barcode
FROM (VALUES
    ('Database System Concepts',   'DSC-1'),
    ('Database System Concepts',   'DSC-2'),
    ('Database System Concepts',   'DSC-3'),
    ('Introduction to Algorithms', 'ALG-1'),
    ('Clean Code',                 'CC-1')
) AS v(title, barcode)
JOIN book AS b ON b.title = v.title;

INSERT INTO copy (book_id, barcode, acquired_on, withdrawn_on)
SELECT b.book_id, 'DSC-4', DATE '2015-01-01', DATE '2026-02-01'
FROM book AS b WHERE b.title = 'Database System Concepts';

INSERT INTO member (member_number, full_name) VALUES
    ('M-S1', 'Search Member One'),
    ('M-S2', 'Search Member Two');

DO $$
BEGIN
    PERFORM issue_copy('M-S1', 'DSC-1', DATE '2026-10-01');
    PERFORM issue_copy('M-S2', 'DSC-2', DATE '2026-10-05');
    PERFORM issue_copy('M-S1', 'CC-1',  DATE '2026-10-03');
END;
$$;

-- FR-09: a title search matches whole words, prefixes, and any case.
DO $$
DECLARE
    v_case   record;
    v_titles text[];
BEGIN
    FOR v_case IN
        SELECT * FROM (VALUES
            ('Database System Concepts',  ARRAY['Database System Concepts']),
            ('database',                  ARRAY['Database System Concepts']),
            ('DATABASE',                  ARRAY['Database System Concepts']),
            ('algor',                     ARRAY['Introduction to Algorithms']),
            ('database concepts',         ARRAY['Database System Concepts']),
            ('concepts database',         ARRAY['Database System Concepts']),
            ('clean cod',                 ARRAY['Clean Code']),
            -- Every token must match, so an impossible combination finds
            -- nothing rather than falling back to either token.
            ('database algorithms',       ARRAY[]::text[]),
            ('nonexistent',               ARRAY[]::text[]),
            -- The 'simple' configuration keeps stop words, so a title
            -- that is mostly stop words is still reachable.
            ('the idiot',                 ARRAY['The Idiot'])
        ) AS t(query, expected)
    LOOP
        SELECT coalesce(array_agg(s.title ORDER BY s.title), ARRAY[]::text[])
        INTO v_titles
        FROM search_titles(v_case.query) AS s;

        IF v_titles <> v_case.expected THEN
            RAISE EXCEPTION 'search % returned %, expected %',
                v_case.query, v_titles, v_case.expected;
        END IF;
    END LOOP;
END;
$$;

-- FR-09: an author search returns that author's titles.
DO $$
DECLARE
    v_case   record;
    v_titles text[];
BEGIN
    FOR v_case IN
        SELECT * FROM (VALUES
            ('Cormen',       ARRAY['Introduction to Algorithms']),
            ('silberschatz', ARRAY['Database System Concepts']),
            -- A second credited author reaches the same title.
            ('Korth',        ARRAY['Database System Concepts']),
            ('Dostoev',      ARRAY['The Idiot'])
        ) AS t(query, expected)
    LOOP
        SELECT coalesce(array_agg(s.title ORDER BY s.title), ARRAY[]::text[])
        INTO v_titles
        FROM search_titles(v_case.query) AS s;

        IF v_titles <> v_case.expected THEN
            RAISE EXCEPTION 'author search % returned %, expected %',
                v_case.query, v_titles, v_case.expected;
        END IF;
    END LOOP;
END;
$$;

-- FR-09: an ISBN search is an exact match and is reported as one.
DO $$
DECLARE
    v_row record;
    v_n   bigint;
BEGIN
    SELECT * INTO v_row FROM search_titles('9780132350884');
    IF v_row.title <> 'Clean Code' THEN
        RAISE EXCEPTION 'ISBN search returned %', v_row.title;
    END IF;
    IF v_row.matched_on <> 'isbn' THEN
        RAISE EXCEPTION 'ISBN search reported matched_on = %', v_row.matched_on;
    END IF;

    -- Punctuation a librarian copies from a book cover is accepted.
    SELECT count(*) INTO v_n FROM search_titles('978-0-13-235088-4');
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'hyphenated ISBN search returned % rows', v_n;
    END IF;

    -- A partial ISBN is not an ISBN; it has no exact match to make.
    SELECT count(*) INTO v_n FROM search_titles('978013235');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'partial ISBN search returned % rows', v_n;
    END IF;

    -- An unknown but well-formed ISBN simply finds nothing.
    SELECT count(*) INTO v_n FROM search_titles('9780000000000');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'unknown ISBN search returned % rows', v_n;
    END IF;

    IF search_isbn13('Clean Code 2') IS NOT NULL THEN
        RAISE EXCEPTION 'a title containing digits was read as an ISBN';
    END IF;
END;
$$;

-- FR-09: blank and punctuation-only input match nothing.
DO $$
DECLARE
    v_case text;
    v_n    bigint;
BEGIN
    FOREACH v_case IN ARRAY ARRAY['', ' ', '   ', '!!!', '-', NULL] LOOP
        SELECT count(*) INTO v_n FROM search_titles(v_case);
        IF v_n <> 0 THEN
            RAISE EXCEPTION 'blank search [%] returned % rows', v_case, v_n;
        END IF;
    END LOOP;

    -- Staff browse the catalog through title_availability instead, which
    -- still lists every title including the one with no copies.
    SELECT count(*) INTO v_n FROM title_availability;
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'catalog browse listed % titles, expected 4', v_n;
    END IF;
END;
$$;

-- FR-09: a title match outranks an author match for the same query, and
-- paging is stable.
DO $$
DECLARE
    v_n bigint;
BEGIN
    SELECT count(*) INTO v_n FROM search_titles('e', 2, 0);
    IF v_n > 2 THEN
        RAISE EXCEPTION 'limit 2 returned % rows', v_n;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM search_titles('e', 100, 0) AS a
        JOIN search_titles('e', 100, 0) AS b
            ON a.book_id = b.book_id AND a.matched_on <> b.matched_on
    ) THEN
        RAISE EXCEPTION 'one title was reported with two match sources';
    END IF;
END;
$$;

-- FR-08: a copy is available, on loan, or withdrawn, and nothing else.
DO $$
DECLARE
    v_case  record;
    v_state text;
BEGIN
    FOR v_case IN
        SELECT * FROM (VALUES
            ('DSC-1', 'on_loan'),
            ('DSC-2', 'on_loan'),
            ('DSC-3', 'available'),
            ('DSC-4', 'withdrawn'),
            ('ALG-1', 'available'),
            ('CC-1',  'on_loan')
        ) AS t(barcode, expected)
    LOOP
        SELECT ca.availability_status INTO v_state
        FROM copy_availability AS ca WHERE ca.barcode = v_case.barcode;

        IF v_state IS DISTINCT FROM v_case.expected THEN
            RAISE EXCEPTION 'copy % is %, expected %',
                v_case.barcode, v_state, v_case.expected;
        END IF;
    END LOOP;
END;
$$;

-- FR-08: title counts add up and report the earliest open due date.
DO $$
DECLARE
    v_case record;
    v_row  record;
BEGIN
    FOR v_case IN
        SELECT * FROM (VALUES
            ('Database System Concepts',   4, 1, 2, 1, DATE '2026-10-15'),
            ('Introduction to Algorithms', 1, 1, 0, 0, NULL),
            ('The Idiot',                  0, 0, 0, 0, NULL),
            ('Clean Code',                 1, 0, 1, 0, DATE '2026-10-17')
        ) AS t(title, total, available, on_loan, withdrawn, next_due_on)
    LOOP
        SELECT * INTO v_row FROM title_availability AS ta
        WHERE ta.title = v_case.title;

        IF v_row.copies_total <> v_case.total
           OR v_row.copies_available <> v_case.available
           OR v_row.copies_on_loan <> v_case.on_loan
           OR v_row.copies_withdrawn <> v_case.withdrawn THEN
            RAISE EXCEPTION
                'counts for % were total=% available=% on_loan=% withdrawn=%',
                v_case.title, v_row.copies_total, v_row.copies_available,
                v_row.copies_on_loan, v_row.copies_withdrawn;
        END IF;
        IF v_row.next_due_on IS DISTINCT FROM v_case.next_due_on THEN
            RAISE EXCEPTION 'next due date for % was %, expected %',
                v_case.title, v_row.next_due_on, v_case.next_due_on;
        END IF;
        IF v_row.copies_total
               <> v_row.copies_available + v_row.copies_on_loan + v_row.copies_withdrawn THEN
            RAISE EXCEPTION 'copy counts for % do not sum to the total', v_case.title;
        END IF;
    END LOOP;
END;
$$;

-- FR-08: authors are listed in their recorded order.
DO $$
DECLARE
    v_authors text;
BEGIN
    SELECT ta.authors INTO v_authors FROM title_availability AS ta
    WHERE ta.title = 'Database System Concepts';
    IF v_authors <> 'Abraham Silberschatz; Henry F. Korth' THEN
        RAISE EXCEPTION 'author list was %', v_authors;
    END IF;

    SELECT ta.authors INTO v_authors FROM title_availability AS ta
    WHERE ta.title = 'The Idiot';
    IF v_authors <> 'Fyodor Dostoevsky' THEN
        RAISE EXCEPTION 'single author list was %', v_authors;
    END IF;
END;
$$;

-- FR-08: availability follows circulation, in both directions.
DO $$
DECLARE
    v_row record;
BEGIN
    PERFORM return_copy('DSC-1', DATE '2026-10-10');

    SELECT * INTO v_row FROM title_availability AS ta
    WHERE ta.title = 'Database System Concepts';
    IF v_row.copies_available <> 2 OR v_row.copies_on_loan <> 1 THEN
        RAISE EXCEPTION 'after a return: available=% on_loan=%',
            v_row.copies_available, v_row.copies_on_loan;
    END IF;
    IF v_row.next_due_on <> DATE '2026-10-19' THEN
        RAISE EXCEPTION 'after a return the next due date was %', v_row.next_due_on;
    END IF;

    PERFORM issue_copy('M-S1', 'DSC-1', DATE '2026-10-11');

    SELECT * INTO v_row FROM title_availability AS ta
    WHERE ta.title = 'Database System Concepts';
    IF v_row.copies_available <> 1 OR v_row.copies_on_loan <> 2 THEN
        RAISE EXCEPTION 'after re-issue: available=% on_loan=%',
            v_row.copies_available, v_row.copies_on_loan;
    END IF;

    -- Withdrawing the last free copy leaves the title unborrowable.
    UPDATE copy SET withdrawn_on = DATE '2026-10-12' WHERE barcode = 'DSC-3';

    SELECT * INTO v_row FROM title_availability AS ta
    WHERE ta.title = 'Database System Concepts';
    IF v_row.copies_available <> 0 OR v_row.copies_withdrawn <> 2 THEN
        RAISE EXCEPTION 'after withdrawal: available=% withdrawn=%',
            v_row.copies_available, v_row.copies_withdrawn;
    END IF;

    BEGIN
        PERFORM issue_copy('M-S2', 'DSC-3', DATE '2026-10-13');
        RAISE EXCEPTION 'a withdrawn copy was issued';
    EXCEPTION WHEN SQLSTATE 'SS004' THEN NULL;
    END;
END;
$$;

-- FR-08: a copy withdrawn while still on loan reports as withdrawn but
-- does not hide the loan that is still open against it.
DO $$
DECLARE
    v_row record;
BEGIN
    UPDATE copy SET withdrawn_on = DATE '2026-10-14' WHERE barcode = 'CC-1';

    SELECT * INTO v_row FROM copy_availability AS ca WHERE ca.barcode = 'CC-1';
    IF v_row.availability_status <> 'withdrawn' THEN
        RAISE EXCEPTION 'withdrawn copy on loan reported as %', v_row.availability_status;
    END IF;
    IF v_row.open_loan_id IS NULL THEN
        RAISE EXCEPTION 'the open loan on a withdrawn copy was hidden';
    END IF;
END;
$$;

ROLLBACK;
