# DBMS course coverage

This matrix points to executable evidence for the supplied marking criteria. MongoDB is the chosen NoSQL implementation; vector search is not claimed.

| Criterion | Evidence |
| --- | --- |
| E-R diagram; relational schema, keys, relationships, constraints | [Database Design Description](database-design-description.md) and migrations [001](../db/001_baseline.sql) through [006](../db/006_application.sql). |
| SQL database creation and DDL | Ordered PostgreSQL migrations and six rollback-based [verification scripts](../db/verify_application.sql). |
| NoSQL database creation | `web/scripts/setup-mongo.ts` creates `reading_lists` with a MongoDB JSON schema validator and index; `web/tests/mongo.test.ts` checks creation and validation. |
| Technology justification | [Architecture Description](architecture-description.md) and [Application and NoSQL design](application-and-nosql.md) explain the PostgreSQL/MongoDB boundary. |
| DML operations | `web/lib/actions.ts` creates and updates catalog, copy, member, policy, and staff records; `book.delete` removes an unreferenced title. The web application issues and returns loans without deleting history. MongoDB reading lists support create, read, update, and delete. |
| Nested/correlated/recursive queries and joins | `search_titles`, `title_availability`, `hold_queue`, and `daily_issues`; see migrations [003](../db/003_discovery.sql), [004](../db/004_holds.sql), and [006](../db/006_application.sql). The recursive daily report includes zero-issue dates. |
| Advanced SQL | `issue_copy` and `return_copy` transactional functions, `record_loan_event` trigger, `daily_issues` recursive CTE, `hold_queue` window function, circulation summary window and `ROLLUP` grouping. SQL assertions and two-session concurrency scripts verify behavior. |
| NoSQL feature and RUD | Staff-curated reading lists are retrieved, edited, and deleted through `/api/reading-lists`; PostgreSQL supplies current title and availability. The UI exposes the complete CRUD workflow. |
| Next.js interface; backend/API integration | `web/app` and `web/components` provide staff screens; API route handlers call PostgreSQL functions and MongoDB operations. |
| Authentication and two roles with database access control | `staff_user.role` holds `admin` or `librarian`; server routes check roles; migration 006 guards staff and policy writes in PostgreSQL with an active administrator identity. `db/verify_application.sql` includes negative role checks. |
| Documentation, Git, and GitHub | README, requirements, architecture, database design, workflow and measurement documents, migrations, phase issues, and pull requests. |
| Originality, individual contribution, modification, viva | The project includes a specific hold allocation rule, reproducible fine snapshots, measured index decisions, and a two-store curated-list feature. Each contributor should explain and demonstrate their own changes; this repository cannot certify individual contribution. |

Unit 1 is covered by the model, schema, constraints, and basic queries. Unit 2 is covered by search, joins, views, functions, triggers, CTEs, and reports. Unit 3 is covered by the dependency analysis and [measured query plans](query-performance.md). Unit 4 is covered by transactions, locking, MongoDB, and the Next.js application.
