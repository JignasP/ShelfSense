# Application and NoSQL design

## Purpose and data ownership

ShelfSense uses PostgreSQL 17 for titles, copies, members, loans, holds, policy, and staff identity. Foreign keys, partial unique indexes, transactional functions, and locks keep circulation correct. MongoDB 8 stores staff-curated reading lists: a title, description, ordered entries, and optional per-title notes. This document structure fits variable-length editorial content without weakening the relational loan model. MongoDB is the NoSQL deliverable; vector search and a graph database are not implemented.

A reading-list entry stores a PostgreSQL `book_id` string, not a duplicate title or availability count. The API validates referenced books when a list is written. On read, it joins those identifiers to current PostgreSQL `title_availability` results in the server layer. If a book was later removed, the entry displays “Title unavailable.” There is no distributed transaction across the stores; a list can retain a stale reference until staff edit it. Loans and fines never depend on MongoDB.

## MongoDB collection and operations

`npm run setup:mongo` connects to the named database and creates `reading_lists` with a JSON schema validator and an `updatedAt` index. The document fields are `ownerStaffId`, `title`, `description`, `entries: [{bookId, note}]`, `createdAt`, and `updatedAt`. The API bounds lists to 30 distinct entries and rejects unknown titles on create or update.

| Operation | API | UI |
| --- | --- | --- |
| Create | `POST /api/reading-lists` | Add a curated list |
| Read | `GET /api/reading-lists` | Browse lists and current availability |
| Update | `PATCH /api/reading-lists` | Edit the title, description, entries, and notes |
| Delete | `DELETE /api/reading-lists` | Remove a list |

All staff may read lists. A librarian may edit or delete their own lists; an administrator may edit any list. API handlers enforce the rule after loading the document.

## Staff access and SQL evidence

`staff_user.role` permits `admin` and `librarian`. Passwords use a random salt and scrypt. An opaque session token is stored only as a SHA-256 hash in PostgreSQL and sent in an HTTP-only, SameSite cookie with an eight-hour expiry. API routes check the session; mutation routes also check the request origin. The browser does not hold database credentials.

Administrators manage staff and circulation policy. Librarians use catalog, membership, issue/return, holds, reports, and reading lists. Migration 006 adds a PostgreSQL trigger that requires an active administrator identity for staff and policy changes once the first administrator exists. The trusted server sets that identity only within the transaction. This guard complements API authorization, but cannot protect against an attacker who already controls the database connection or can forge its session setting. The first account must be an administrator.

The same migration records loan issue and return events through triggers. `daily_issues` uses a recursive CTE to emit each date, including dates with zero issues. Earlier migrations supply joins, full-text search, nested queries, views, window functions, grouping, and transaction-safe circulation functions. See the [course coverage matrix](course-coverage.md) for file-level evidence.

## Verification

Run six SQL verification files after migrations against a clean disposable database. Each rolls its fixture data back. Run `npm run typecheck`, `npm run lint`, `npm test`, and `npm run build` inside `web`. The MongoDB test starts a disposable in-memory server and checks collection creation, validation, and document CRUD. The password test checks salted hashes and verification.

`npm run verify:http`, with `TEST_BASE_URL`, `TEST_ADMIN_USERNAME`, and `TEST_ADMIN_PASSWORD` set for disposable PostgreSQL and MongoDB, checks unauthenticated rejection, admin login, policy and record creation, issue/duplicate-issue conflict/return, audit rows, daily reports, reading-list CRUD, librarian login, librarian administrator-action rejection, and origin rejection. Use only disposable databases when reproducing this flow because it creates real records. The UI still needs a final manual review in the target browser and operating environment before deployment.
