-- ShelfSense migration 003: catalog search and copy availability.
-- Apply after db/002_circulation.sql. Implements FR-08 (availability
-- derived from copies, withdrawal state, and open loans) and FR-09
-- (search titles by title, author, or ISBN), described in
-- docs/discovery-and-reporting.md.
--
-- Availability is derived, never stored. The Architecture Description,
-- section 6, rejects a second mutable status column that could disagree
-- with loan history, so every answer here is computed from copy and loan
-- rows at read time.
BEGIN;

-- Availability of one physical copy (FR-08).
-- The three states are mutually exclusive and ordered the same way
-- issue_copy checks them: a withdrawn copy is reported as withdrawn even
-- if a loan is still open against it, because it is not lendable either
-- way. open_loan_id stays visible so that loan is not hidden.
CREATE VIEW copy_availability AS
SELECT
    c.copy_id,
    c.book_id,
    c.barcode,
    c.acquired_on,
    c.withdrawn_on,
    l.loan_id   AS open_loan_id,
    l.member_id AS borrower_member_id,
    l.issued_on AS on_loan_since,
    l.due_on    AS due_on,
    CASE
        WHEN c.withdrawn_on IS NOT NULL THEN 'withdrawn'
        WHEN l.loan_id IS NOT NULL      THEN 'on_loan'
        ELSE 'available'
    END AS availability_status
FROM copy AS c
LEFT JOIN loan AS l
    ON l.copy_id = c.copy_id AND l.returned_on IS NULL;

COMMENT ON VIEW copy_availability IS
    'One row per physical copy with its derived availability: available, on_loan, or withdrawn.';

-- Copy counts for one title (FR-08).
-- Kept as a function so the catalog browse view and the search results
-- share one definition of "available", and so a search pays for the
-- titles it matched rather than for the whole catalog.
CREATE FUNCTION title_copy_counts(p_book_id bigint)
RETURNS TABLE (
    copies_total bigint,
    copies_available bigint,
    copies_on_loan bigint,
    copies_withdrawn bigint,
    next_due_on date
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        count(ca.copy_id),
        count(*) FILTER (WHERE ca.availability_status = 'available'),
        count(*) FILTER (WHERE ca.availability_status = 'on_loan'),
        count(*) FILTER (WHERE ca.availability_status = 'withdrawn'),
        min(ca.due_on) FILTER (WHERE ca.availability_status = 'on_loan')
    FROM copy_availability AS ca
    WHERE ca.book_id = p_book_id;
$$;

COMMENT ON FUNCTION title_copy_counts(bigint) IS
    'Copy counts by availability for one title, and the earliest due date among its open loans.';

-- Credited authors for one title, in the order recorded in book_author.
CREATE FUNCTION title_authors(p_book_id bigint)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT string_agg(au.display_name, '; ' ORDER BY ba.author_order)
    FROM book_author AS ba
    JOIN author AS au ON au.author_id = ba.author_id
    WHERE ba.book_id = p_book_id;
$$;

COMMENT ON FUNCTION title_authors(bigint) IS
    'Credited authors for one title as a display string, ordered by author_order.';

-- Catalog browse list (FR-08).
CREATE VIEW title_availability AS
SELECT
    b.book_id,
    b.title,
    b.isbn13,
    b.publication_year,
    title_authors(b.book_id) AS authors,
    cc.copies_total,
    cc.copies_available,
    cc.copies_on_loan,
    cc.copies_withdrawn,
    cc.next_due_on
FROM book AS b
CROSS JOIN LATERAL title_copy_counts(b.book_id) AS cc;

COMMENT ON VIEW title_availability IS
    'One row per catalog title with its authors and copy counts by availability.';

-- Search input parsing (FR-09).
-- An ISBN search is an exact match on isbn13, so a query counts as an
-- ISBN only when it contains nothing but digits, spaces, and hyphens and
-- carries exactly thirteen digits. A title that merely happens to contain
-- digits is therefore never mistaken for an ISBN.
CREATE FUNCTION search_isbn13(p_query text)
RETURNS char(13)
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN btrim(coalesce(p_query, '')) ~ '^[0-9 -]+$'
             AND length(regexp_replace(p_query, '[^0-9]', '', 'g')) = 13
        THEN regexp_replace(p_query, '[^0-9]', '', 'g')::char(13)
    END;
$$;

COMMENT ON FUNCTION search_isbn13(text) IS
    'The 13-digit ISBN a query denotes, or NULL when the query is not an ISBN.';

-- Text search query construction (FR-09).
-- Every token must match and each token is a prefix term, so "algor sys"
-- finds "Algorithms" and "Systems". The lexemes come back from
-- to_tsvector already tokenised and are quoted with %L before they are
-- parsed again, so punctuation in staff input cannot become tsquery
-- syntax.
--
-- The 'simple' configuration is used rather than 'english' because it
-- removes no stop words and does no stemming: titles such as "It" and
-- "The Idiot" stay searchable, and prefix matching already covers most of
-- what stemming would have given. A blank or punctuation-only query
-- produces no lexemes and therefore NULL, which matches no row.
CREATE FUNCTION search_tsquery(p_query text)
RETURNS tsquery
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT to_tsquery('simple', string_agg(format('%L:*', lexeme), ' & '))
    FROM unnest(tsvector_to_array(to_tsvector('simple', coalesce(p_query, ''))))
        AS t(lexeme);
$$;

COMMENT ON FUNCTION search_tsquery(text) IS
    'Prefix-and tsquery for a staff search string, or NULL when the string holds no searchable token.';

-- Search indexes (FR-09).
-- The two GIN indexes match the expressions used in search_titles
-- exactly, which is what lets a search avoid reading every title.
-- book_author's primary key is (book_id, author_id), so walking from a
-- matched author to that author's titles has no usable index without
-- book_author_author_id_idx. All three are justified by the measured
-- plans in docs/query-performance.md.
CREATE INDEX book_title_fts_idx ON book USING gin (to_tsvector('simple', title));
CREATE INDEX author_display_name_fts_idx ON author USING gin (to_tsvector('simple', display_name));
CREATE INDEX book_author_author_id_idx ON book_author(author_id);

-- Browsing the catalog in title order (FR-08).
-- title_availability counts copies per title through a lateral join, so
-- without an ordered index on title the whole catalog has to be counted
-- before the first page can be sorted and cut. One page of fifty titles
-- measured at 180,666 buffer hits that way and 928 with this index.
CREATE INDEX book_title_idx ON book(title);

-- Catalog search (FR-09).
-- The three match paths are separate indexed lookups combined with
-- UNION ALL rather than one OR across a join, so each path can use its
-- own index. DISTINCT ON then keeps one row per title, preferring an
-- ISBN match over a title match over an author match.
--
-- Each branch carries the title columns it found rather than leaving one
-- join to book at the end. PostgreSQL estimates the selectivity of a
-- tsquery match from a fixed default rather than from statistics, so a
-- single join after the branches was planned for that guess and read
-- every row of book even when the search matched four titles. Resolving
-- the columns inside each branch lets the planner choose per branch, and
-- keeps a narrow search proportional to what it matched.
CREATE FUNCTION search_titles(
    p_query text,
    p_limit integer DEFAULT 50,
    p_offset integer DEFAULT 0
) RETURNS TABLE (
    book_id bigint,
    title text,
    isbn13 char(13),
    publication_year integer,
    authors text,
    copies_total bigint,
    copies_available bigint,
    copies_on_loan bigint,
    copies_withdrawn bigint,
    next_due_on date,
    matched_on text,
    rank real
)
LANGUAGE sql
STABLE
AS $$
    WITH input AS (
        SELECT search_tsquery(p_query) AS tsq,
               search_isbn13(p_query)  AS isbn
    ),
    matches AS (
        SELECT
            b.book_id, b.title, b.isbn13, b.publication_year,
            'isbn'::text AS matched_on, 1::real AS rank
        FROM book AS b, input AS i
        WHERE i.isbn IS NOT NULL
          AND b.isbn13 = i.isbn
        UNION ALL
        SELECT
            b.book_id, b.title, b.isbn13, b.publication_year,
            'title', ts_rank(to_tsvector('simple', b.title), i.tsq)
        FROM book AS b, input AS i
        WHERE i.tsq IS NOT NULL
          AND to_tsvector('simple', b.title) @@ i.tsq
        UNION ALL
        SELECT
            b.book_id, b.title, b.isbn13, b.publication_year,
            'author', ts_rank(to_tsvector('simple', au.display_name), i.tsq)
        FROM author AS au
        JOIN book_author AS ba ON ba.author_id = au.author_id
        JOIN book AS b ON b.book_id = ba.book_id
        CROSS JOIN input AS i
        WHERE i.tsq IS NOT NULL
          AND to_tsvector('simple', au.display_name) @@ i.tsq
    ),
    best AS (
        SELECT DISTINCT ON (m.book_id)
            m.book_id, m.title, m.isbn13, m.publication_year,
            m.matched_on, m.rank
        FROM matches AS m
        ORDER BY m.book_id,
                 CASE m.matched_on
                     WHEN 'isbn'  THEN 1
                     WHEN 'title' THEN 2
                     ELSE 3
                 END,
                 m.rank DESC
    )
    SELECT
        best.book_id,
        best.title,
        best.isbn13,
        best.publication_year,
        title_authors(best.book_id),
        cc.copies_total,
        cc.copies_available,
        cc.copies_on_loan,
        cc.copies_withdrawn,
        cc.next_due_on,
        best.matched_on,
        best.rank
    FROM best
    CROSS JOIN LATERAL title_copy_counts(best.book_id) AS cc
    ORDER BY best.rank DESC, best.title, best.book_id
    LIMIT p_limit OFFSET p_offset;
$$;

COMMENT ON FUNCTION search_titles(text, integer, integer) IS
    'Titles matching a staff query by ISBN, title, or author, with availability and why each row matched.';

COMMIT;
