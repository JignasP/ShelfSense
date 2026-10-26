# ShelfSense

ShelfSense is a database-backed library circulation project. It tracks titles, physical copies, members, loans, and overdue fines. The central design rule is that a copy may have at most one open loan, including when two staff members issue books at the same time.

## Status

This repository contains the requirements, architecture, PostgreSQL schema, and the circulation workflow. Issuing and returning a copy run as transaction-safe database functions with automated checks, including a two-session concurrency check. It does not yet contain a web application. Features described as planned in the documents are not claimed as implemented.

## Scope

The first release is for one library and its staff. It will support catalog and copy management, member records, issue and return transactions, copy availability, and a reproducible overdue fine calculation. Planned extensions include title search, hold queues, operational reports, and a Next.js interface. Payment collection, multi-branch transfers, and recommendation systems are outside the first release.

## Project documents

| Information item | Location | Purpose |
| --- | --- | --- |
| Software Requirements Specification (SRS) | [docs/software-requirements-specification.md](docs/software-requirements-specification.md) | Verifiable behavior, constraints, and boundaries |
| Architecture Description (AD) | [docs/architecture-description.md](docs/architecture-description.md) | Context, components, data ownership, and key decisions |
| Database Design Description (DDD) | [docs/database-design-description.md](docs/database-design-description.md) | Entities, relationships, integrity rules, and schema rationale |
| Circulation workflow | [docs/circulation-workflow.md](docs/circulation-workflow.md) | Issue and return behavior, failure codes, locking, and fine presentation |
| Course coverage matrix | [docs/course-coverage.md](docs/course-coverage.md) | Evidence planned for each DBMS unit |
| PostgreSQL baseline schema | [db/001_baseline.sql](db/001_baseline.sql) | Executable starting schema; not a complete application |
| PostgreSQL circulation migration | [db/002_circulation.sql](db/002_circulation.sql) | Issue and return transactions, currency configuration, fine presentation |
| Baseline verification SQL | [db/verify_baseline.sql](db/verify_baseline.sql) | Deterministic checks against a clean test database |
| Circulation verification SQL | [db/verify_circulation.sql](db/verify_circulation.sql) | Deterministic checks for issue, return, and fine boundaries |
| Concurrency verification | [scripts/verify_concurrency.sh](scripts/verify_concurrency.sh) | Two-session check that one copy yields exactly one open loan |

These names are chosen with reference to the terminology of ISO/IEC/IEEE 29148:2018, 42010:2022, and 15289:2019. The documents are tailored for a semester project; no standards conformance or certification is claimed.

## Database setup

Requires PostgreSQL 17 or a compatible recent PostgreSQL version. Create an empty database, then run:

```sh
psql -X -v ON_ERROR_STOP=1 -d shelfsense -f db/001_baseline.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense -f db/002_circulation.sql
```

Migration 001 creates tables, constraints, indexes, a fine calculation function, and a read-only view. Migration 002 adds the issue and return transactions, the currency configuration, and the fine presentation described in [docs/circulation-workflow.md](docs/circulation-workflow.md). Neither migration seeds production data. The application still owns authentication and authorization; the database owns the circulation transactions and integrity rules.

An administrator must insert the single `circulation_policy` row before issuing the first loan; the project has not chosen operational fine rates, loan limits, or a currency on the library's behalf. `currency_code` starts as ISO 4217 `XXX` ("no currency") until it is set.

To check a disposable database after applying both migrations:

```sh
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/verify_baseline.sql
psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f db/verify_circulation.sql
sh scripts/verify_concurrency.sh shelfsense_test
```

The two SQL scripts insert fixtures in a transaction and roll them back, so they succeed quietly and print nothing. They assume a fresh test database with no existing records. The concurrency script runs two psql sessions against one copy, so it has to commit its fixtures; it removes them when it passes and leaves them in place when it fails.

## Development sequence

Work is organized by [GitHub phase milestones](https://github.com/JignasP/ShelfSense/milestones) rather than dates or weeks: foundation, circulation, discovery and reporting, and application verification. Issues carry acceptance criteria so contributors can take ownership independently.

## References

- [ISO/IEC/IEEE 29148:2018 — Requirements engineering](https://www.iso.org/standard/72089.html)
- [ISO/IEC/IEEE 42010:2022 — Architecture description](https://www.iso.org/standard/74393.html)
- [ISO/IEC/IEEE 15289:2019 — Content of life-cycle information items](https://www.iso.org/standard/74909.html)
