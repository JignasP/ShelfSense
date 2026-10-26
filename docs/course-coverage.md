# DBMS course coverage

This matrix links course topics to concrete ShelfSense evidence. Planned items are not claimed as implemented.

| Unit | Topic | Project evidence | State |
| --- | --- | --- | --- |
| 1 | E-R model, schema reduction, keys and constraints | [Database Design Description](database-design-description.md) and baseline DDL | Baseline drafted and SQL validated |
| 1 | Relational operations, grouping | Availability and circulation queries with sample data | Planned |
| 2 | Joins, subqueries, CTEs, window functions | Catalog search and overdue/circulation reports | Planned |
| 2 | Views and functions | `loan_fines` view and `calculate_fine_minor` function; `issue_copy`, `return_copy`, `loan_fine_as_of`, and the `loan_fine_statement` view | Validated |
| 2 | Triggers and procedures | Decided against triggers: the one-open-loan rule is a partial unique index and the workflow is transactional functions, so no trigger fires behind the caller's back. See [Circulation workflow](circulation-workflow.md), section 2 | Decided and validated |
| 2 | Full-text search | PostgreSQL title/author search with measured query plans | Planned |
| 3 | Functional dependencies and normal forms | Key and dependency analysis in database design | Baseline drafted |
| 3 | Query processing and optimization | `EXPLAIN (ANALYZE, BUFFERS)` on representative searches and reports | Planned |
| 4 | Transactions, locking, concurrency | Competing issue requests for one copy; one succeeds. Two psql sessions in [scripts/verify_concurrency.sh](../scripts/verify_concurrency.sh), covering both the locked workflow path and a direct write that bypasses it | Implemented and validated |
| 4 | Next.js and SQL | Staff application with server-side database access and authorization | Planned |
| 4 | NoSQL, graph, vector concepts | Short comparative analysis or isolated prototype if time permits; no second authoritative store | Optional |

The core deliverable is a correct relational circulation system. Advanced features should be demonstrated with a clear use case, query, test data, and result rather than added only to satisfy a checklist.
