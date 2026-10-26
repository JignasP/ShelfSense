-- Committed fixture for scripts/verify_concurrency.sh.
-- Two sessions must see the same rows, so this file commits rather than
-- rolling back. It removes its own rows first and can be run repeatedly.
BEGIN;

DELETE FROM loan
WHERE copy_id IN (SELECT copy_id FROM copy WHERE barcode = 'COPY-CONC');
DELETE FROM copy WHERE barcode = 'COPY-CONC';
DELETE FROM member WHERE member_number IN ('M-CONC-A', 'M-CONC-B');
DELETE FROM book WHERE isbn13 = '9780262033848';

-- Leaves an existing deployment policy untouched.
INSERT INTO circulation_policy (
    loan_limit, loan_days, grace_days, fine_minor_per_day, max_fine_minor,
    currency_code, currency_minor_digits
) VALUES (3, 14, 1, 25, 200, 'INR', 2)
ON CONFLICT (policy_id) DO NOTHING;

INSERT INTO book (title, isbn13)
VALUES ('Introduction to Algorithms', '9780262033848');

INSERT INTO copy (book_id, barcode)
SELECT book_id, 'COPY-CONC' FROM book WHERE isbn13 = '9780262033848';

INSERT INTO member (member_number, full_name) VALUES
    ('M-CONC-A', 'Concurrent Staff A'),
    ('M-CONC-B', 'Concurrent Staff B');

COMMIT;
