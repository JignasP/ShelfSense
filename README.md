# ShelfSense

ShelfSense is a single-library circulation application. It manages titles and physical copies, members, holds, issue and return transactions, and reproducible overdue fines. PostgreSQL enforces the circulation rules; MongoDB holds staff-curated reading lists. A Next.js staff interface exposes both through server-side APIs.

## Implemented scope

- Catalog and copy records, member records, full-text title search, and live availability.
- Transaction-safe issue and return, a title-level hold queue, policy snapshots on loans, and fine calculations in minor currency units.
- Overdue, title, monthly, and daily reports; the daily report includes dates with no issues.
- Administrator and librarian accounts, database-backed sessions, administrator-only policy and staff management, and loan audit events.
- MongoDB reading-list create, read, update, and delete with current PostgreSQL title and availability lookup.

Payments, multi-branch transfers, member self-service, graph storage, and vector search are outside this release.

## Project documents

| Information item | Location |
| --- | --- |
| Software Requirements Specification (SRS) | [docs/software-requirements-specification.md](docs/software-requirements-specification.md) |
| Architecture Description (AD) | [docs/architecture-description.md](docs/architecture-description.md) |
| Database Design Description (DDD), including E-R diagram | [docs/database-design-description.md](docs/database-design-description.md) |
| Application and NoSQL design | [docs/application-and-nosql.md](docs/application-and-nosql.md) |
| Circulation workflow | [docs/circulation-workflow.md](docs/circulation-workflow.md) |
| Discovery and reporting | [docs/discovery-and-reporting.md](docs/discovery-and-reporting.md) |
| Query performance | [docs/query-performance.md](docs/query-performance.md) |
| Course coverage and marking evidence | [docs/course-coverage.md](docs/course-coverage.md) |

The information-item names are tailored from ISO/IEC/IEEE 29148:2018, 42010:2022, and 15289:2019. This project does not claim standards conformance or certification.

## Local setup

Prerequisites: Node.js 24, npm, PostgreSQL 17, and MongoDB 8. The included `compose.yaml` can start the databases with Docker Compose. Keep passwords and connection strings in untracked environment files.

1. Copy `.env.example` to `.env`, choose distinct local passwords, and make the password portions of `DATABASE_URL` and `MONGODB_URL` match. Run `docker compose up -d` if using the included containers. The PostgreSQL container listens on localhost port 5433; MongoDB listens on localhost port 27017.
2. Create a database named `shelfsense` if using an existing PostgreSQL server. Apply the migrations in order:

   ```sh
   for file in db/00[1-6]_*.sql; do psql -X -v ON_ERROR_STOP=1 -d shelfsense -f "$file"; done
   ```

3. Copy `web/.env.example` to `web/.env.local` and set its database URLs, MongoDB database name, and library timezone. From `web`, run `npm ci` and `npm run setup:mongo`.
4. Create the first administrator from `web` after setting `SHELFSENSE_INITIAL_USERNAME`, `SHELFSENSE_INITIAL_NAME`, and `SHELFSENSE_INITIAL_PASSWORD` (12–128 characters). Run `npm run create:user`. No default administrator or password is supplied.
5. Set policy values in the administrator screen before issuing the first loan. Run `npm run dev` from `web` and open the local URL printed by Next.js. The policy starts unconfigured because loan limits, fine rates, and currency are library decisions.

The root `.env` is read by Docker Compose; Next.js reads `web/.env.local`. Do not commit either file. Migration 006 requires the first staff account to be an administrator; later staff and policy writes require an active administrator identity. The MongoDB collection is created by `setup:mongo` or on the first reading-list request.

## Verification

Apply migrations to a separate, clean test database, then run the six rollback-based SQL checks in order:

```sh
for file in db/verify_baseline.sql db/verify_circulation.sql db/verify_discovery.sql db/verify_holds.sql db/verify_reports.sql db/verify_application.sql; do
  psql -X -v ON_ERROR_STOP=1 -d shelfsense_test -f "$file"
done
```

From `web`, run `npm run typecheck`, `npm run lint`, `npm test`, and `npm run build`. For an end-to-end API check, start the app against disposable PostgreSQL and MongoDB databases, create a temporary administrator, set `TEST_BASE_URL`, `TEST_ADMIN_USERNAME`, and `TEST_ADMIN_PASSWORD`, then run `npm run verify:http`. This check creates persistent fixtures. The two-session concurrency checks are `scripts/verify_concurrency.sh` and `scripts/verify_hold_concurrency.sh`; run them against a disposable database because they briefly commit fixture rows. Query-plan measurement uses `db/perf_dataset.sql` and `scripts/measure_query_plans.sh`; its dataset and recorded results are in [Query performance](docs/query-performance.md).

## Development

Work is organized through [phase milestones](https://github.com/JignasP/ShelfSense/milestones) and issues, by delivery phase. Changes are reviewed through pull requests. Contributors should document what they implemented and be able to explain its behavior and tradeoffs.
