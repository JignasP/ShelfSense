# DBMS course coverage

This matrix links course topics to concrete ShelfSense evidence. Planned items are not claimed as implemented.

| Unit | Topic | Project evidence | State |
| --- | --- | --- | --- |
| 1 | E-R model, schema reduction, keys and constraints | [Database Design Description](database-design-description.md) and baseline DDL | Baseline drafted and SQL validated |
| 1 | Relational operations, grouping | `copy_availability` and `title_availability` views; grouped circulation summaries with `FILTER` aggregates checked against fixture data | Implemented and validated |
| 2 | Joins, subqueries, CTEs, window functions | `search_titles` (CTEs, `UNION ALL`, `DISTINCT ON`, lateral joins); `hold_queue` (`row_number()`); the per-title circulation share (window aggregate); the monthly report (`GROUP BY ROLLUP` with `GROUPING()`) | Implemented and validated |
| 2 | Views and functions | `loan_fines` view and `calculate_fine_minor` function; `issue_copy`, `return_copy`, `loan_fine_as_of`, and the `loan_fine_statement` view; the availability, search, hold, and report functions and views of migrations 003 to 005 | Validated |
| 2 | Triggers and procedures | Decided against triggers: the one-open-loan rule is a partial unique index and the workflow is transactional functions, so no trigger fires behind the caller's back. See [Circulation workflow](circulation-workflow.md), section 2 | Decided and validated |
| 2 | Full-text search | `to_tsvector`/`to_tsquery` prefix search over titles and author names with GIN indexes, measured in [Query performance](query-performance.md) | Implemented and validated |
| 3 | Functional dependencies and normal forms | Key and dependency analysis in database design, including the hold relation and why its resolution columns are constrained rather than split into one relation per state | Baseline drafted |
| 3 | Query processing and optimization | `EXPLAIN (ANALYZE, BUFFERS)` on 15 search, availability, hold, and report queries against 20,000 titles and 150,000 loans; four indexes justified, one proposed index rejected, and two query plans rewritten because the measurement exposed them | Implemented and validated |
| 4 | Transactions, locking, concurrency | Competing issue requests for one copy; one succeeds. Two psql sessions in [scripts/verify_concurrency.sh](../scripts/verify_concurrency.sh), covering both the locked workflow path and a direct write that bypasses it. Holds add a title-level lock, checked for over-allocation and queue order in [scripts/verify_hold_concurrency.sh](../scripts/verify_hold_concurrency.sh) | Implemented and validated |
| 4 | Next.js and SQL | Staff application with server-side database access and authorization | Planned |
| 4 | NoSQL, graph, vector concepts | Short comparative analysis or isolated prototype if time permits; no second authoritative store | Optional |

The core deliverable is a correct relational circulation system. Advanced features should be demonstrated with a clear use case, query, test data, and result rather than added only to satisfy a checklist.
