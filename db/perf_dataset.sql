-- Representative dataset for scripts/measure_query_plans.sh.
--
-- Assumes a disposable database with every migration in db/ applied and
-- no existing records, and commits what it inserts: query plans depend
-- on committed rows and on the statistics ANALYZE collects from them.
-- Identity columns are therefore expected to start at 1.
--
-- Nothing here is random. Every value comes from arithmetic on
-- generate_series, so two runs produce the same database and the plans
-- in docs/query-performance.md can be reproduced rather than
-- approximated. Multipliers are coprime with their moduli so that rows
-- spread evenly instead of clustering.
--
-- The result is one library's scale, not a stress test:
--
--   20,000 titles        45,000 copies         6,000 members
--    8,000 authors      150,000 loans          4,000 holds
--   30,000 title-author links (5,000 of the loans still open)
BEGIN;

INSERT INTO circulation_policy (
    loan_limit, loan_days, grace_days, fine_minor_per_day, max_fine_minor,
    currency_code, currency_minor_digits
) VALUES (10, 14, 2, 25, 200, 'INR', 2);

-- Titles are built from three word lists so that search terms differ in
-- how much they select: a subject word appears in roughly a tenth of the
-- catalog, while "Palimpsest" below appears four times.
INSERT INTO book (title, isbn13, publication_year)
SELECT
    (ARRAY['Advanced','Practical','Modern','Introductory','Essential',
           'Applied','Comparative','Foundational','Critical','Concise'])[(n % 10) + 1]
        || ' ' ||
    (ARRAY['Database','Algorithms','Networks','Systems','Graphics',
           'Security','Compilers','Robotics','Statistics','Linguistics'])[((n / 10) % 10) + 1]
        || ' ' ||
    (ARRAY['Theory','Design','Practice','Analysis','Methods',
           'Workbook','Review','Casebook','Primer','Atlas'])[((n / 100) % 10) + 1]
        || ' Volume ' || ((n / 1000) + 1)::text,
    to_char(9780000000000::bigint + n, 'FM0000000000000'),
    2000 + (n % 26)
FROM generate_series(0, 19999) AS n;

-- A term that almost nothing matches, so a selective search can be
-- measured next to an unselective one.
UPDATE book SET title = title || ' Palimpsest' WHERE book_id % 5000 = 0;

INSERT INTO author (display_name)
SELECT
    (ARRAY['Ada','Grace','Edsger','Barbara','Tony','Leslie','Donald','Frances',
           'Alan','Maurice','Niklaus','Peter','Robin','Karen','Jim','Nancy',
           'Butler','Shafi','Silvio','Manuel'])[(n % 20) + 1]
        || ' ' ||
    (ARRAY['Lovelace','Hopper','Dijkstra','Liskov','Hoare','Lamport','Knuth',
           'Allen','Turing','Wilkes','Wirth','Naur','Milner','Sparck','Gray',
           'Leveson','Lampson','Goldwasser','Micali','Blum'])[((n / 20) % 20) + 1]
        || ' ' || ((n / 400) + 1)::text
FROM generate_series(0, 7999) AS n;

-- A single author nobody shares a name with.
UPDATE author SET display_name = 'Quenneville Rarename' WHERE author_id = 4242;

-- Every title has one credited author; every second title has two.
INSERT INTO book_author (book_id, author_id, author_order)
SELECT b.book_id, ((b.book_id * 7) % 8000) + 1, 1
FROM book AS b;

INSERT INTO book_author (book_id, author_id, author_order)
SELECT b.book_id, ((b.book_id * 13) % 8000) + 1, 2
FROM book AS b
WHERE b.book_id % 2 = 0
  -- The first author of this title may already be this author.
  AND ((b.book_id * 13) % 8000) <> ((b.book_id * 7) % 8000);

-- Copies cluster on the lower title ids, so some titles have several
-- copies and most have one or two, as a real catalog does.
INSERT INTO copy (book_id, barcode, acquired_on)
SELECT
    ((n * 11) % 20000) + 1,
    'BC-' || to_char(n, 'FM000000'),
    DATE '2015-01-01' + (n % 4000)
FROM generate_series(1, 45000) AS n;

-- A small share of the stock is retired, which availability has to
-- exclude without hiding it.
UPDATE copy SET withdrawn_on = DATE '2026-01-15' WHERE copy_id % 50 = 0;

INSERT INTO member (member_number, full_name, joined_on)
SELECT
    'MB-' || to_char(n, 'FM00000'),
    'Member ' || n::text,
    DATE '2019-01-01' + (n % 2500)
FROM generate_series(1, 6000) AS n;

-- 145,000 closed loans spread over 34 months. Some came back after
-- their due date, so the fine calculation has real work to do.
INSERT INTO loan (
    copy_id, member_id, policy_id, issued_on, due_on, returned_on,
    grace_days, fine_minor_per_day, max_fine_minor
)
SELECT
    ((n * 17) % 45000) + 1,
    ((n * 29) % 6000) + 1,
    1,
    DATE '2024-01-01' + ((n * 7) % 1035),
    DATE '2024-01-01' + ((n * 7) % 1035) + 14,
    DATE '2024-01-01' + ((n * 7) % 1035) + ((n * 3) % 25),
    2, 25, 200
FROM generate_series(1, 145000) AS n;

-- 5,000 open loans, one per distinct copy so the partial unique index
-- on open loans is satisfied. Issue dates straddle the due boundary, so
-- the overdue worklist has both overdue and current loans to sort.
INSERT INTO loan (
    copy_id, member_id, policy_id, issued_on, due_on,
    grace_days, fine_minor_per_day, max_fine_minor
)
SELECT
    ((n * 9) % 45000) + 1,
    ((n * 31) % 6000) + 1,
    1,
    DATE '2026-07-01' + ((n * 7) % 123),
    DATE '2026-07-01' + ((n * 7) % 123) + 14,
    2, 25, 200
FROM generate_series(1, 5000) AS n;

-- 3,000 active holds: three members waiting on each of 1,000 titles.
-- The member for each place in a queue is chosen so that no member
-- appears twice in the same queue, which the partial unique index on
-- active holds would reject. placed_at is set rather than defaulted, so
-- the order within each queue is fixed and a measured plan for
-- hold_queue can be reproduced.
INSERT INTO hold (book_id, member_id, status, placed_at)
SELECT
    ((n - 1) % 1000) + 1,
    ((((n - 1) / 1000) * 1777 + ((n - 1) % 1000) * 3) % 6000) + 1,
    'active',
    TIMESTAMPTZ '2026-10-01 09:00:00+00' + n * INTERVAL '1 minute'
FROM generate_series(1, 3000) AS n;

-- 1,000 cancelled holds, so the queue views have resolved history to
-- read past. The unique index is partial on active holds, so these may
-- repeat a member and title freely.
INSERT INTO hold (book_id, member_id, status, placed_at, canceled_at)
SELECT
    ((n * 7) % 1000) + 1,
    ((n * 23) % 6000) + 1,
    'canceled',
    TIMESTAMPTZ '2026-05-01 09:00:00+00' + (n % 90) * INTERVAL '1 day',
    TIMESTAMPTZ '2026-05-08 09:00:00+00' + (n % 90) * INTERVAL '1 day'
FROM generate_series(1, 1000) AS n;

COMMIT;

-- Plans follow the statistics, so the measurement is meaningless until
-- these are collected.
--
-- VACUUM, not just ANALYZE. A GIN index buffers freshly inserted
-- entries in a pending list that every search has to read in full until
-- something flushes it, which here cost a title search 289 buffer hits
-- instead of 3. A running library reaches the flushed state through
-- autovacuum, so measuring before the flush would report the cost of
-- having just bulk-loaded the catalog rather than the cost of searching
-- it.
VACUUM ANALYZE;
