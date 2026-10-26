-- ShelfSense baseline schema for an empty PostgreSQL database.
-- Calendar dates use the library's configured local timezone at the application boundary.
BEGIN;

CREATE TABLE book (
    book_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title text NOT NULL CHECK (length(btrim(title)) > 0),
    isbn13 char(13) UNIQUE,
    publication_year integer CHECK (publication_year BETWEEN 1450 AND 3000),
    CONSTRAINT book_isbn13_format CHECK (isbn13 IS NULL OR isbn13 ~ '^[0-9]{13}$')
);

CREATE TABLE author (
    author_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    display_name text NOT NULL CHECK (length(btrim(display_name)) > 0)
);

CREATE TABLE book_author (
    book_id bigint NOT NULL REFERENCES book(book_id) ON DELETE RESTRICT,
    author_id bigint NOT NULL REFERENCES author(author_id) ON DELETE RESTRICT,
    author_order integer NOT NULL CHECK (author_order > 0),
    PRIMARY KEY (book_id, author_id),
    UNIQUE (book_id, author_order)
);

CREATE TABLE copy (
    copy_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    book_id bigint NOT NULL REFERENCES book(book_id) ON DELETE RESTRICT,
    barcode text NOT NULL UNIQUE CHECK (length(btrim(barcode)) > 0),
    acquired_on date,
    withdrawn_on date,
    CONSTRAINT copy_withdrawal_order CHECK (
        acquired_on IS NULL OR withdrawn_on IS NULL OR withdrawn_on >= acquired_on
    )
);

CREATE INDEX copy_book_id_idx ON copy(book_id);

CREATE TABLE member (
    member_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    member_number text NOT NULL UNIQUE CHECK (length(btrim(member_number)) > 0),
    full_name text NOT NULL CHECK (length(btrim(full_name)) > 0),
    email text UNIQUE,
    joined_on date NOT NULL DEFAULT CURRENT_DATE,
    active boolean NOT NULL DEFAULT true,
    CONSTRAINT member_email_nonblank CHECK (email IS NULL OR length(btrim(email)) > 0)
);

CREATE TABLE circulation_policy (
    policy_id smallint PRIMARY KEY DEFAULT 1 CHECK (policy_id = 1),
    loan_limit integer NOT NULL CHECK (loan_limit > 0),
    loan_days integer NOT NULL CHECK (loan_days > 0),
    grace_days integer NOT NULL CHECK (grace_days >= 0),
    fine_minor_per_day integer NOT NULL CHECK (fine_minor_per_day >= 0),
    max_fine_minor integer NOT NULL CHECK (max_fine_minor >= 0)
);

CREATE TABLE loan (
    loan_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    copy_id bigint NOT NULL REFERENCES copy(copy_id) ON DELETE RESTRICT,
    member_id bigint NOT NULL REFERENCES member(member_id) ON DELETE RESTRICT,
    policy_id smallint NOT NULL REFERENCES circulation_policy(policy_id) ON DELETE RESTRICT,
    issued_on date NOT NULL,
    due_on date NOT NULL,
    returned_on date,
    grace_days integer NOT NULL CHECK (grace_days >= 0),
    fine_minor_per_day integer NOT NULL CHECK (fine_minor_per_day >= 0),
    max_fine_minor integer NOT NULL CHECK (max_fine_minor >= 0),
    CONSTRAINT loan_date_order CHECK (
        due_on >= issued_on AND (returned_on IS NULL OR returned_on >= issued_on)
    )
);

CREATE UNIQUE INDEX loan_one_open_per_copy_idx ON loan(copy_id) WHERE returned_on IS NULL;
CREATE INDEX loan_member_id_idx ON loan(member_id);
CREATE INDEX loan_open_due_on_idx ON loan(due_on) WHERE returned_on IS NULL;

CREATE FUNCTION calculate_fine_minor(
    p_due_on date,
    p_returned_on date,
    p_as_of_date date,
    p_grace_days integer,
    p_fine_minor_per_day integer,
    p_max_fine_minor integer
) RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT LEAST(
        p_max_fine_minor,
        GREATEST(0, COALESCE(p_returned_on, p_as_of_date) - p_due_on - p_grace_days)::bigint
            * p_fine_minor_per_day
    );
$$;

CREATE VIEW loan_fines AS
SELECT
    l.loan_id,
    CURRENT_DATE AS as_of_date,
    l.returned_on IS NOT NULL AS is_final,
    GREATEST(0, COALESCE(l.returned_on, CURRENT_DATE) - l.due_on) AS overdue_days,
    calculate_fine_minor(
        l.due_on, l.returned_on, CURRENT_DATE,
        l.grace_days, l.fine_minor_per_day, l.max_fine_minor
    ) AS fine_minor
FROM loan AS l;

COMMIT;
