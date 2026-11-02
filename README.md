# ShelfSense

ShelfSense is a database-backed library circulation project. It tracks titles, physical copies, members, loans, and overdue fines. The central design rule is that a copy may have at most one open loan, including when two staff members issue books at the same time.

## Status

This repository contains the requirements, architecture, PostgreSQL schema, the circulation workflow, and catalog search, availability, holds, and reports. Issuing and returning a copy run as transaction-safe database functions with automated checks, including two-session concurrency checks for both the one-open-loan rule and the hold queue. Index choices are backed by measured query plans against a representative dataset. It does not yet contain a web application. Features described as planned in the documents are not claimed as implemented.

## Scope

The first release is for one library and its staff. It will support catalog and copy management, member records, issue and return transactions, copy availability, and a reproducible overdue fine calculation. Planned extensions include title search, hold queues, operational reports, and a Next.js interface. Payment collection, multi-branch transfers, and recommendation systems are outside the first release.

## Project documents

| Information item | Location | Purpose |
| --- | --- | --- |
| Software Requirements Specification (SRS) | [docs/software-requirements-specification.md](docs/software-requirements-specification.md) | Verifiable behavior, constraints, and boundaries |
| Architecture Description (AD) | [docs/architecture-description.md](docs/architecture-description.md) | Context, components, data ownership, and key decisions |
| Database Design Description (DDD) | [docs/database-design-description.md](docs/database-design-description.md) | Entities, relationships, integrity rules, and schema rationale |
| Circulation workflow | [docs/circulation-workflow.md](docs/circulation-workflow.md) | Issue and return behavior, failure codes, locking, and fine presentation |
| Discovery and reporting | [docs/discovery-and-reporting.md](docs/discovery-and-reporting.md) | Search, availability, the hold queue and its rule, and the reports |
| Query performance | [docs/query-performance.md](docs/query-performance.md) | Measured plans, dataset size, and the index decisions they justify |
| Course coverage matrix | [docs/course-coverage.md](docs/course-coverage.md) | Evidence planned for each DBMS unit |
| PostgreSQL baseline schema | [db/001_baseline.sql](db/001_baseline.sql) | Executable starting schema; not a complete application |
| PostgreSQL circulation migration | [db/002_circulation.sql](db/002_circulation.sql) | Issue and return transactions, currency configuration, fine presentation |
| PostgreSQL discovery migration | [db/003_discovery.sql](db/003_discovery.sql) | Copy and title availability, catalog search, search indexes |
| PostgreSQL holds migration | [db/004_holds.sql](db/004_holds.sql) | Hold table, queue view, the hold rule, and hold fulfillment on issue |
| PostgreSQL reports migration | [db/005_reports.sql](db/005_reports.sql) | Overdue worklist and circulation summaries by title and by month |
| Baseline verification SQL | [db/verify_baseline.sql](db/verify_baseline.sql) | Deterministic checks against a clean test database |
| Circulation verification SQL | [db/verify_circulation.sql](db/verify_circulation.sql) | Deterministic checks for issue, return, and fine boundaries |
| Discovery verification SQL | [db/verify_discovery.sql](db/verify_discovery.sql) | Deterministic checks for search behavior and availability |
| Holds verification SQL | [db/verify_holds.sql](db/verify_holds.sql) | Deterministic checks for hold states, duplicates, order, and history |
| Reports verification SQL | [db/verify_reports.sql](db/verify_reports.sql) | Report totals checked against a hand-computed fixture |
| Concurrency verification | [scripts/verify_concurrency.sh](scripts/verify_concurrency.sh) | Two-session check that one copy yields exactly one open loan |
| Hold concurrency verification | [scripts/verify_hold_concurrency.sh](scripts/verify_hold_concurrency.sh) | Two-session check that competing issues cannot starve a hold queue |
| Query plan measurement | [scripts/measure_query_plans.sh](scripts/measure_query_plans.sh) | Measures the discovery and reporting queries on a representative dataset |

These names are chosen with reference to the terminology of ISO/IEC/IEEE 29148:2018, 42010:2022, and 15289:2019. The documents are tailored for a semester project; no standards conformance or certification is claimed.

## Database setup

Requires PostgreSQL 17 or a compatible recent PostgreSQL version. Create an empty database, then run:

```sh
psql -X -v ON_ERROR_STOP=1 -d shelfsense -f db/001_baseline.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense -f db/002_circulation.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense -f db/003_discovery.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense -f db/004_holds.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense -f db/005_reports.sql
```

Migration 001 creates tables, constraints, indexes, a fine calculation function, and a read-only view. Migration 002 adds the issue and return transactions, the currency configuration, and the fine presentation described in [docs/circulation-workflow.md](docs/circulation-workflow.md). Migrations 003 to 005 add availability and catalog search, the hold queue, and the overdue and circulation reports described in [docs/discovery-and-reporting.md](docs/discovery-and-reporting.md). Migration 004 also revises `issue_copy`, which now enforces the hold rule and fulfills a borrower's hold. No migration seeds production data. The application still owns authentication and authorization; the database owns the circulation transactions and integrity rules.

An administrator must insert the single `circulation_policy` row before issuing the first loan; the project has not chosen operational fine rates, loan limits, or a currency on the library's behalf. `currency_code` starts as ISO 4217 `XXX` ("no currency") until it is set.

To check a disposable database after applying both migrations:

```sh
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/verify_baseline.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/verify_circulation.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/verify_discovery.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/verify_holds.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/verify_reports.sql
sh scripts/verify_concurrency.sh shelfsense_test
sh scripts/verify_hold_concurrency.sh shelfsense_test
```

The five SQL scripts insert fixtures in a transaction and roll them back, so they succeed quietly and print nothing. They assume a fresh test database with no existing records. The concurrency scripts run two psql sessions against one copy or one title, so they have to commit their fixtures; they remove them when they pass and leave them in place when they fail.

Query plans are measured separately, on a disposable database loaded with a representative dataset rather than on the small test fixtures:

```sh
psql -X -v ON_ERROR_STOP=1 -d shelfsense_perf -f db/perf_dataset.sql
sh scripts/measure_query_plans.sh shelfsense_perf
```

The dataset is 20,000 titles, 45,000 copies, 6,000 members, 150,000 loans, and 4,000 holds, generated without randomness so it rebuilds identically. The results are recorded in [docs/query-performance.md](docs/query-performance.md).

## Development sequence

Work is organized by [GitHub phase milestones](https://github.com/JignasP/ShelfSense/milestones) rather than dates or weeks: foundation, circulation, discovery and reporting, and application verification. Issues carry acceptance criteria so contributors can take ownership independently.

## References

- [ISO/IEC/IEEE 29148:2018 — Requirements engineering](https://www.iso.org/standard/72089.html)
- [ISO/IEC/IEEE 42010:2022 — Architecture description](https://www.iso.org/standard/74393.html)
- [ISO/IEC/IEEE 15289:2019 — Content of life-cycle information items](https://www.iso.org/standard/74909.html)
