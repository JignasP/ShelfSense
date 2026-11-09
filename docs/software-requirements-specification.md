# Software Requirements Specification (SRS)

**Project:** ShelfSense
**Status:** Implemented baseline, subject to project review
**Scope:** Single-library circulation system

## 1. Purpose and boundary

ShelfSense supports librarians who maintain a catalog and lend physical books to registered members. The system distinguishes a bibliographic title from each lendable physical copy. The first release covers inventory, membership, circulation, availability, and fine computation. It does not process payments, transfer stock between branches, or use machine learning.

This specification records intended behavior. An item is implemented only when its linked issue and verification evidence are complete.

## 2. Stakeholders and operating context

- **Librarian:** maintains records and performs issue and return operations.
- **Member:** has a registered account and borrows copies; a self-service interface is not required initially.
- **Project maintainer:** configures policy, deploys the application, and reviews database changes.

PostgreSQL owns catalog, circulation, staff identity, and policy. MongoDB stores staff-curated reading lists, whose book identifiers are resolved against PostgreSQL when displayed. A Next.js server layer handles authenticated staff requests. Browser code connects to neither database directly.

## 3. Functional requirements

| ID | Requirement | Verification |
| --- | --- | --- |
| FR-01 | Staff shall create and update title records and identify each physical copy by a unique barcode. | Create two copies of one title; reject a duplicate barcode. |
| FR-02 | Staff shall register members with a unique member number and mark a member inactive without deleting loan history. | Deactivate a member with a historical loan; history remains. |
| FR-03 | The system shall issue an available, non-withdrawn copy to an active member with an issue date, due date, and a snapshot of the applicable fine policy. | Issue a copy and inspect the recorded policy values. |
| FR-04 | The system shall reject an issue when the copy already has an open loan. | Attempt concurrent issues of one copy; exactly one succeeds. |
| FR-05 | The system shall reject an issue when the member has reached the configured open-loan limit. | Attempt an issue at the limit; no loan is created. |
| FR-06 | Staff shall return an open loan once; the return date shall be recorded without deleting the loan. | Return a loan twice; the second attempt is rejected. |
| FR-07 | The system shall calculate a fine in minor currency units from days after the due date and grace period, subject to a cap. The fine for a returned loan shall remain fixed; the fine for an open loan shall be calculated as of a stated date. | Compare before-due, within-grace, overdue, capped, and returned cases. |
| FR-08 | Staff shall see copy availability derived from open loans and withdrawal state. | Issue, return, and withdraw copies; availability changes accordingly. |
| FR-09 | Staff shall search titles by title, author, or ISBN. | Search sample records and inspect results. |
| FR-10 | Staff shall view overdue loans and circulation summaries. | Compare report results with known fixture data. |
| FR-11 | Staff shall place a member into a title's hold queue; fulfillment shall follow request order among active holds. | Create two holds and verify fulfillment order. |
| FR-12 | Staff shall create, read, update, and delete curated reading lists with notes; each listed title shall resolve to current catalog data and availability. | Exercise all four MongoDB operations and confirm a removed title is shown safely. |
| FR-13 | Administrators shall manage policy and staff accounts; librarians shall perform daily library work without administrator privileges. | Test both roles at the API and reject unauthorized policy and staff writes in PostgreSQL. |
| FR-14 | The system shall record issue and return events with the acting staff member when one is available, and shall report daily issue counts including days with no issues. | Check trigger output and a recursive date report with quiet days. |

FR-01 through FR-14 are implemented in the database and staff application. FR-11 is served through a staff-assisted hold form; member self-service remains outside this release. The checks are described in [Application and NoSQL design](application-and-nosql.md).

## 4. Data and business rules

- A title can have many physical copies and many authors. A copy belongs to exactly one title.
- A copy can have many historical loans but at most one open loan.
- Member and copy identifiers are stable; historical loan rows are retained.
- A due date must be on or after the issue date. A return date cannot precede the issue date.
- Money is stored as integer minor units. The initial currency is configured at deployment; mixed currencies are outside scope.
- Fine policy values are copied onto each loan when issued so later policy changes do not rewrite historical liability.
- A fine is an amount due calculation, not evidence of a payment or a posted charge.
- A hold is placed on a title, not on a copy, and any copy of the title satisfies it. A member may hold one title at most once at a time, and a hold is resolved by cancellation or by fulfillment rather than by deletion.
- A hold reserves one available copy for the member waiting. An issue to anybody else is refused only when it would leave a member already in the queue without a copy.
- Copy availability is derived from copy and loan records, never stored as a separate status.

## 5. Quality and interface requirements

| ID | Requirement | Verification |
| --- | --- | --- |
| QR-01 | Circulation writes shall be atomic. A failed issue or return shall leave no partial change. | Force an error inside a transaction and confirm rollback. |
| QR-02 | The database shall enforce referential integrity and the one-open-loan-per-copy rule independently of the interface. | Direct SQL negative tests. |
| QR-03 | Staff-only mutations shall require server-side authorization; administrator writes to staff and policy records shall also be guarded by PostgreSQL. | Unauthenticated requests, librarian administrator requests, and direct SQL writes without an administrator identity are denied. |
| QR-04 | The application shall display dates and amounts unambiguously, including the fine's as-of date and configured currency. | Interface review with overdue and returned examples. |
| QR-05 | Schema changes shall be reproducible from versioned SQL files against an empty database. | Apply migrations in order to a clean database. |

No response-time target is asserted. Query plans and index choices for the discovery and reporting queries have now been measured against a representative dataset, and the results, the dataset size, and the one index the measurement rejected are recorded in [Query performance](query-performance.md). Those numbers come from one developer machine, so they justify the index decisions rather than a service level; a target still depends on a defined deployment environment.

## 6. Traceability and acceptance

The issue tracker links requirements to implementation and checks. Migrations 001–005 cover FR-01 through FR-11, with evidence in [Circulation workflow](circulation-workflow.md), [Discovery and reporting](discovery-and-reporting.md), and [Query performance](query-performance.md). Migration 006, the Next.js application, and the MongoDB collection cover FR-12 through FR-14 and QR-03. The application checks include HTTP requests against disposable PostgreSQL and MongoDB instances. Project review remains a separate step.

## 7. Terminology

- **Title:** bibliographic work/edition record presented in the catalog.
- **Copy:** physical lendable item identified by barcode.
- **Open loan:** a loan with no return date.
- **Fine:** computed overdue amount in minor currency units.
- **Hold:** request for a title, to be fulfilled by an available copy.

This is a project-specific SRS using terminology from [ISO/IEC/IEEE 29148:2018](https://www.iso.org/standard/72089.html). It is not a claim of full conformance.
