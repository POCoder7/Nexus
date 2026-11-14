# ADR-040: Database-independent persistence; business logic and controls in Java

- **Status:** Proposed, **deferred** (repository owner, 2026-11-14: "lets go ahead with the database approved designs" for now). The approved database designs (ADR-014, ADR-019) stay in force. Revisit before a shared environment exists, because after that the V1–V12 migrations can no longer be rewritten (rule 6)
- **Date:** 2026-11-14
- **Deciders:** Repository owner; Audit-Risk and Security (review)
- **Capabilities:** PROG, HIE-02, PRP-01, GOV-02, GOV-12, AUD-01, SEC-01, NEW-08
- **Supersedes, when accepted:** ADR-019; parts of ADR-011, ADR-014, ADR-020, ADR-021 and ADR-023 (listed under Consequences)

## Context
Phases 1 to 3 put the core logic of Nexus in PostgreSQL. At 5-1a this was about 125 functions and 44 triggers,
3,500 to 4,000 lines of PL/pgSQL in all, tested by about 470 pgTAP assertions. These include:
- the guards (maker-checker, separation of duties, human-only decisions, append-only logs, bitemporal rules, status
  transitions, version lifecycle, commit-policy limits);
- the apply engine, as `SECURITY DEFINER` functions (ADR-019);
- most of the workflow logic;
- the reads (tree, resolved properties, DRM export, ownership).

The schema also uses PostgreSQL-only features: `daterange` and `tstzrange` periods, `EXCLUDE USING gist` constraints
that stop overlapping history, `jsonb`, trigram indexes, `SECURITY DEFINER` and a fixed `search_path`.

On 2026-11-14 the repository owner set these directions:
- Nexus must be **database independent**: it runs on **PostgreSQL and Oracle**.
- Business logic and controls move to Java. The owner accepts that the API, not the database, becomes the
  enforcement point, and will secure it.
- The database keeps **no rule enforcement**: no triggers, functions, foreign keys, unique constraints or check
  constraints ("Java only").
- **Phase 5 pauses** until the move is done.
- This ADR is written now, and Audit-Risk reviews it before anything merges to `main`.

## Decision
### D1. Target databases
PostgreSQL 16 and Oracle. The Oracle release is open (C-1). Every migration, query and test runs on both.

### D2. The database stores data; Java enforces every rule
- No triggers, stored functions, foreign keys, unique constraints or check constraints.
- The database keeps tables, primary keys, `NOT NULL`, indexes and grants. Primary keys are kept because they identify
  rows, not because they enforce a business rule (C-3).
- Every rule now enforced in SQL becomes a Java domain rule with the same error code (`N`-codes, ADR-020). The
  Problem Details contract (ADR-015) and the OpenAPI description stay the same.

### D3. Portable schema
| PostgreSQL today | Portable form |
|---|---|
| `valid_period daterange` | `valid_from date`, `valid_to date` (exclusive; the open end is `9999-12-31`, not NULL, so it can be indexed and compared the same way on both) |
| `recorded tstzrange` | `recorded_from`, `recorded_to timestamp with time zone`, UTC; open end `9999-12-31T00:00Z` |
| `EXCLUDE USING gist` (no overlapping history) | a Java check under the lock in D5 |
| `uuid` | a dialect type: `uuid` on PostgreSQL, `RAW(16)` on Oracle |
| `jsonb` | a JSON text column (PostgreSQL `jsonb`, Oracle `JSON` or `CLOB`). Nothing queries inside it in SQL; Java reads it |
| `boolean` | a dialect type (`boolean`; on Oracle before 23ai, `NUMBER(1)`) |
| trigram search | a `SearchPort` with one adapter per database (`pg_trgm`; Oracle Text) |
| `WITH RECURSIVE` | recursive common table expressions in a dialect query (Oracle leaves out `RECURSIVE`) |
| schemas `mdm`, `wf`, `wf_bridge`, `mdm_stage` | kept: schemas on PostgreSQL, users on Oracle |
| `FOR UPDATE SKIP LOCKED` (outbox) | kept: both databases support it |

Flyway keeps one migration set per database (`db/migration/postgresql`, `db/migration/oracle`). The V1 to V12
migrations are rewritten, not appended to: no shared environment exists yet (rule 6, OD-44).

### D4. Data access
- Java keeps `JdbcClient` with explicit SQL and row mappers, as CLAUDE.md requires.
- SQL that differs between the two databases lives behind a small `SqlDialect` interface, one implementation per
  database.
- No ORM. jOOQ is not used, because its Oracle support needs a commercial licence (C-2).

### D5. Concurrency without database constraints
Without unique or exclusion constraints, a check followed by an insert can race. Every write therefore runs in one
transaction that first takes a **pessimistic lock** (`SELECT … FOR UPDATE`) on the aggregate it changes:
- the hierarchy, for placements, moves, cycles, sort order and sibling names;
- the node, for its attributes and history;
- the change request, for status, items and decisions;
- the policy row, for the daily cap.

The checks run after the lock. Serializable isolation is not relied on, because Oracle's `SERIALIZABLE` is snapshot
isolation and allows write skew. Each lock order is documented so deadlocks are avoided.

### D6. Compensating controls for the API as the enforcement point
| Control in the database today | Control after this ADR |
|---|---|
| Only `nexus_apply` (definer functions) writes facts | Facts are written only by an **apply worker** with its own database login, which is the only login with `INSERT`/`UPDATE` on fact tables. The API login keeps read access and draft-side writes. Grants are portable and stay |
| Append-only triggers on logs and history | The application logins get only `INSERT` and `SELECT` on log tables, never `UPDATE` or `DELETE` |
| Maker-checker, separation of duties, human-only and status triggers | One Java domain service per aggregate; every write goes through it. ArchUnit tests prove that no other code uses the write repositories |
| Bitemporal guard trigger | `BitemporalWriter`, the only class that closes or opens fact rows |
| Audit trigger | An audit row written in the same transaction by the domain service. Native database auditing (pgaudit, Oracle Unified Auditing) is turned on in each environment for direct SQL access |
| `nexus_bridge`, the only writer across layers | A `WorkflowBridge` module, the only Java module allowed to change `mdm` because of `wf`, enforced by ArchUnit. The `wf` login has no write access to `mdm` |
| Sub-tree scope as SQL | The same rule in Java, tested on the 28 cases from 2-4 |
| Direct writes by loaders and scripts are blocked by triggers | Loaders write only to `mdm_stage`. Data reaches `mdm` only through change requests, applied by the apply worker. No person or tool gets the fact-writing login (an operations control) |

### D7. Tests
- Every pgTAP assertion is re-expressed as a JUnit test before its SQL is removed.
- The domain-rule and repository tests run on both databases with Testcontainers.
- pgTAP and `db/tests/` are retired once their JUnit tests pass.
- Oracle in CI and on the laptop needs about 2 GB of memory (C-4).

### D8. Order: a re-platform phase before Phase 5 resumes
- **R0 Design:** an LLD for the Java domain model, locks, dialects and test plan. Stop for review.
- **R1 Port tests:** JUnit equivalents of the pgTAP suites, run against today's PostgreSQL code (safety net).
- **R2 Portable schema** on both databases.
- **R3 Change requests, apply and trial apply**, in Java.
- **R4 Workflow, bridge and commit policies**, in Java.
- **R5 Reads:** tree, resolved properties, DRM export, ownership, search, versions.
- **R6 Remove the SQL logic**; both databases green; UI end-to-end tests green (the API contract does not change).
- **R7 Records** and the gate.

Phase 5 then resumes from 5-1b. The 5-1b overlay is designed again on the Java trial apply: run the items, read the
result, then roll back.

## Alternatives considered
- **Keep the logic in PostgreSQL (ADR-019).** The controls hold for every client, but it rules out Oracle. Rejected by
  the owner.
- **Keep the guards and definer functions in the database, move only reads and orchestration to Java.** Fewer
  controls move, but two sets of triggers and functions would have to be kept in step on two databases. Rejected: it is
  not database independent.
- **Keep portable constraints (foreign keys, unique, check) as a backstop.** These would catch bad data written outside
  the API at little cost. The owner chose Java only. Revisit if Audit-Risk asks for a backstop.
- **JPA/Hibernate.** It hides dialect differences, but conflicts with the explicit-SQL convention and makes bitemporal
  writes and keyset paging harder to control.
- **jOOQ.** A good fit technically, but needs a commercial licence for Oracle.

## Consequences
- **Gains:** runs on PostgreSQL and Oracle; one language for the logic; better tooling for debugging, refactoring and
  coverage; faster unit tests; the logic can scale out with the application.
- **Losses:**
  - The controls protect only writes that go through the application. Anyone with the fact-writing login or the
    database owner account can change facts with no check. Today the triggers also apply to any login with direct
    table access. Access to those accounts becomes a key operational control.
  - Large applies make more round-trips. Set-based SQL is kept where it can be portable (batched inserts and updates),
    and performance is measured in the deferred performance work.
  - Without foreign keys, the database no longer stops dangling references. Java checks them under the lock, and a
    periodic reconciliation job reports orphans (in R5).
- **Superseded or amended, when accepted:**
  - ADR-011: "PostgreSQL 16" becomes "PostgreSQL 16 and Oracle"; pgTAP is retired.
  - ADR-014: database roles become logins with grants; the definer owner roles go.
  - ADR-019: superseded.
  - ADR-020: the codes stay; they are raised by Java, not the database.
  - ADR-021, ADR-023: the controls are kept but implemented in Java (needs Audit-Risk review, OD-18a).
  - ADR-028: the overlay is kept, built on the Java trial apply.
  - `CLAUDE.md`, `docs/architecture/`, `docs/data-model.md` and the Phase 1 to 3 LLDs are updated in R0 and R7.
- **Cost:** about the size of Phases 1 and 2. Phase 5 and Phase 4 move later by that much.
- **Tests:** CI needs an Oracle container. The 3.7 GiB Docker limit, already a problem for Camunda, may stop Oracle
  from running locally (C-4).

## Choices for the reviewer
- **C-1 Oracle release:** 19c (long-term support; no `BOOLEAN` or native `JSON` type) or 23ai. Recommended: 19c,
  unless the target environment is known to be 23ai.
- **C-2 Data access:** `JdbcClient` with a dialect interface (recommended) or JPA/Hibernate.
- **C-3 Primary keys:** keep them (recommended; they are identity, not rules), even under "Java only".
- **C-4 Oracle in tests:** Oracle Free in Testcontainers in CI on every pull request, and locally when Docker has
  memory (recommended), or Oracle in CI only.
- **C-5 Uncommitted 5-1b work:** keep it on a parked branch for reference (recommended) or discard it.
