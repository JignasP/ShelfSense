# DBMS course coverage

This matrix links course topics to concrete ShelfSense evidence. Planned items are not claimed as implemented.

| Unit | Topic | Project evidence | State |
| --- | --- | --- | --- |
| 1 | E-R model, schema reduction, keys and constraints | [Database Design Description](database-design-description.md) and baseline DDL | Baseline drafted and SQL validated |
| 1 | Relational operations, grouping | Availability and circulation queries with sample data | Planned |
| 2 | Joins, subqueries, CTEs, window functions | Catalog search and overdue/circulation reports | Planned |
| 2 | Views and functions | `loan_fines` view and `calculate_fine_minor` function | Baseline validated |
| 2 | Triggers and procedures | Add only for a justified invariant or workflow; compare with constraints and server transactions first | Design decision pending |
| 2 | Full-text search | PostgreSQL title/author search with measured query plans | Planned |
| 3 | Functional dependencies and normal forms | Key and dependency analysis in database design | Baseline drafted |
| 3 | Query processing and optimization | `EXPLAIN (ANALYZE, BUFFERS)` on representative searches and reports | Planned |
| 4 | Transactions, locking, concurrency | Competing issue requests for one copy; one succeeds | Planned |
| 4 | Next.js and SQL | Staff application with server-side database access and authorization | Planned |
| 4 | NoSQL, graph, vector concepts | Short comparative analysis or isolated prototype if time permits; no second authoritative store | Optional |

The core deliverable is a correct relational circulation system. Advanced features should be demonstrated with a clear use case, query, test data, and result rather than added only to satisfy a checklist.
