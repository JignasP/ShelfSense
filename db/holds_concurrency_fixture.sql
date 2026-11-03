-- Committed fixture for scripts/verify_hold_concurrency.sh.
-- Two sessions must see the same rows, so this file commits rather than
-- rolling back. It removes its own rows first and can be run repeatedly.
--
-- It leaves one title with three copies and two active holds, placed in
-- order by M-HC-A and then M-HC-B, plus two members who hold no place in
-- the queue.
BEGIN;

-- Holds reference loans, so they go before the loans they point at.
DELETE FROM hold
WHERE book_id IN (SELECT book_id FROM book WHERE isbn13 = '9780596007126');
DELETE FROM loan
WHERE copy_id IN (SELECT copy_id FROM copy WHERE barcode LIKE 'HC-%');
DELETE FROM copy WHERE barcode LIKE 'HC-%';
DELETE FROM member WHERE member_number LIKE 'M-HC-%';
DELETE FROM book WHERE isbn13 = '9780596007126';

-- Leaves an existing deployment policy untouched.
INSERT INTO circulation_policy (
    loan_limit, loan_days, grace_days, fine_minor_per_day, max_fine_minor,
    currency_code, currency_minor_digits
) VALUES (3, 14, 1, 25, 200, 'INR', 2)
ON CONFLICT (policy_id) DO NOTHING;

INSERT INTO book (title, isbn13)
VALUES ('Hold Concurrency Title', '9780596007126');

INSERT INTO copy (book_id, barcode)
SELECT b.book_id, v.barcode
FROM (VALUES ('HC-1'), ('HC-2'), ('HC-3')) AS v(barcode)
JOIN book AS b ON b.isbn13 = '9780596007126';

INSERT INTO member (member_number, full_name) VALUES
    ('M-HC-A', 'Queue Member A'),
    ('M-HC-B', 'Queue Member B'),
    ('M-HC-C', 'Walk-in Member C'),
    ('M-HC-D', 'Walk-in Member D');

-- Placed one after the other, so M-HC-A is ahead of M-HC-B.
DO $$
DECLARE
    v_book_id bigint;
BEGIN
    SELECT book_id INTO v_book_id FROM book WHERE isbn13 = '9780596007126';
    PERFORM place_hold('M-HC-A', v_book_id);
    PERFORM place_hold('M-HC-B', v_book_id);
END;
$$;

COMMIT;
