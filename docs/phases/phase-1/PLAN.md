# Phase 1 — Core write path: plan

- **Status:** Awaiting approval (2026-11-11)
- **Follows:** `docs/design/phase-1-core-write-path/LLD.md` (approved), amended by ADR-026 (`add_hierarchy`, `update_node`)
  and consistency findings CR-01, CR-02, CR-04 (`docs/design/CONSISTENCY_REVIEW.md`). No deviation from the LLD is planned.
- **Exit criteria (BUILD_PROTOCOL §2):** API to create change requests and items; apply writes bitemporal rows atomically;
  validation on submit; as-of reads proven by tests; every endpoint checks a role and scope; `mdm`-side control fixes tested.

## Orient (baseline, 2026-11-11)
| Check | Result |
|---|---|
| `git status` | clean, branch `main`, last commit `d808b01`; no remote (OD-11 decided, not yet created) |
| `scripts\db-test.ps1` | pass: V1–V6, 35/35 pgTAP |
| `mvnw.cmd -B verify` | pass: 6/6 (`HierarchyApiTest`) |
| Shared environment (OD-44) | none exists → editing V1–V6 is allowed (CLAUDE.md rule 6) |
| Open decisions this phase waits on | OD-18a (Audit-Risk review of ADR-021 before the fix migrations reach `main`), OD-17a (Security/Audit-Risk on ADR-014/019 before any shared environment); neither blocks building on a branch |

## Scope
**In (decided):** HIE-01 (Parity), HIE-02 (Parity), PRP-01 (Parity), SEC-01 and SEC-02 basic (Improve), NEW-01 (New),
PROG: control fixes D-04, D-05, D-07, D-29, D-36 (ADR-021); DB roles (ADR-014/019); error codes (ADR-020, CR-02); API
conventions (ADR-015); time handling (ADR-018, CR-01); `add_hierarchy` and `update_node` (ADR-026); request `origin` (CR-04).

**Infrastructure built for SLICE-01 although related capabilities are pending:** `validate_change_request` and submit-time
validation (VAL-01–03 parity semantics are not built).

**Needs decision (nothing built):** HIE-06 (inactivate), PRP-02 / PRP-03 beyond the existing trigger, VAL-01–03 parity,
AUD-01 history query API. Listed in the LLD §15 as outlines.

**Out:** workflow (Phase 2), UI (Phase 3), ownership actions (Phase 6).

## Way of working
- Branch `feature/HIE-02-phase-1-core-write-path` from `main`; one local commit per increment with its capability ID
  (`HIE-02: …`, `SEC-01: …`, `PROG: …`); I ask before each commit; nothing is pushed.
- The branch is merged to `main` only after the Phase 1 gate **and** the Audit-Risk review of ADR-021 (OD-18a), because it edits guards.
- Tests first for every increment; the full suite (`db-test` + `mvnw verify`) before each commit.

## Work breakdown (LLD §16, with the amendments in **bold**)
| # | Increment | Size | Capabilities | Tests written first |
|---|---|---|---|---|
| 1-1 | Error codes on existing guards (messages unchanged), `DbErrorTranslator`, Problem Details shape (`type`, `correlationId`, `errors[]`); **registry codes from CR-02** | S | PROG | existing 35 pgTAP unchanged; new pgTAP `throws_ok` on codes; JUnit mapping per class |
| 1-2 | V1 control fixes: requester-kind check, status transitions, frozen content, draft-only items (+ owner-run `row_version` bump), item audit; new statuses/actions (`apply_failed`, `delete_node`, **`add_hierarchy`**, **`update_node`**); **`origin` column**; hard-limit list in V6 (`delete_node`, **`add_hierarchy`**, **`update_node`**) | M | PROG, HIE-02 | pgTAP D-05, D-07, D-36; fixture change in `01_core_invariants.sql` (submit before approve, plan count stays 18) |
| 1-3 | V7 roles and privileges; `db/testroles` test login; datasource split (Flyway owner vs app login) | M | PROG (D-04) | pgTAP `SET ROLE` denials; whole JUnit suite runs as `nexus_api`; `HierarchyApiTest` seeds through an owner-role `JdbcClient` |
| 1-4 | V8 entitlements; `CurrentActor`, `LocalDevActor`, `ActorFilter`, `StartupGuard`, `EntitlementService`, `GET /me` | M | SEC-01, SEC-02 | JUnit role × endpoint matrix; scope tests (in, out, boundary) |
| 1-5 | **`mdm.system_setting` with `business_time_zone` = `America/New_York` (CR-01)**; `BusinessClock`; UTC sessions; paging envelope and cursors; `recordedAsOf`; D-17, D-19 | M | HIE-01, NEW-01 | JUnit HIE-01, NEW-01, time-zone cases (EST/EDT, DST days); `HierarchyApiTest` shape change `$[0]` → `$.items[0]` (assertions kept) |
| 1-6 | `node_properties_resolved`; node detail with provenance (D-18, D-40) | S | PRP-01 | pgTAP equality with `property_value_asof`; JUnit provenance |
| 1-7 | Change requests: create, edit, items, withdraw; `allocate_node`; ETag; idempotency (V8) | M | HIE-02, PRP-01 | JUnit ETag, idempotency, items |
| 1-8a | `apply_change_request`: framework, set-from-D, `add_node`, `insert_node`, `move_node`, stale base, `change_event` | L | HIE-02 | pgTAP per action and stale base; D-29 traceability |
| 1-8b | `remove_node`, `delete_node`, **`update_node`**, **`add_hierarchy`** | M | HIE-02, HIE-01 | pgTAP per action incl. negatives (`N2004`–`N2006`) |
| 1-8c | `set_property`, `clear_property`; **item limit by origin (CR-04)** | M | PRP-01 | pgTAP scope, inheritance after clear, JSON null override, `N2103` |
| 1-9 | `validate_change_request` (trial apply) + submit | M | (infrastructure) | pgTAP trial rollback leaves no rows; JUnit submit 422 with findings |
| 1-10 | `decide_change_request`, decision endpoint, `ApplyService` with sweeper | M | HIE-02, PRP-01 | JUnit end-to-end slice (core mode); maker-checker negatives |
| 1-11 | Performance tests (tagged `perf`, excluded from the default build) + small synthetic generator | S | HIE-01, PRP-01 | perf: children page at 50 000 siblings, node detail, submit/apply 50 items |
| 1-12 | Records: `data-model.md` (new objects, error-code registry), changelog, test report, summary, build state | S | PROG | review |

**Change of order while building (2026-11-11):** `mdm.system_setting` and `BusinessClock` moved from 1-5 into 1-4,
because entitlement checks need the business date; the idempotency table is created in V8 (1-4) and used in 1-7.
pgTAP files are numbered `03_error_codes`, `04_change_request_controls`, `05_roles_and_privileges`, `06_entitlements`, …

## Tests (summary)
pgTAP grows from 35 to an estimated 110–130 assertions across new files `03_change_request_controls.sql`,
`04_roles_and_privileges.sql`, `05_apply.sql`, `06_validation.sql`, `07_entitlements.sql` (one file per area, `BEGIN … ROLLBACK`).
JUnit gains controller and service tests per endpoint plus the role matrix. Every case in LLD §13 is implemented.
**No existing assertion is removed or weakened**; the two setup changes are listed under 1-2 and 1-3/1-5.

## Decisions and dependencies
- No new ADRs expected (ADR-014, 019, 020, 021, 022, 026 accepted). Any deviation found while building stops for an LLD update and an ADR.
- **New dependencies: none.** (OpenAPI generation is planned for Phase 3.)

## Risks, assumptions and open questions
1. **Editing V1, V5, V6 changes their Flyway checksums.** Any local database built from the old files will fail Flyway
   validation. `scripts/db-test` always rebuilds, so it is unaffected; the `docker compose` dev database must be recreated
   (`docker compose down -v`). I will note this in the changelog and setup guide.
2. **Roles are cluster-wide in PostgreSQL**; V7 creates them idempotently, so repeated test runs on the same container work.
3. **Audit-Risk review (OD-18a)** may ask for changes to the control fixes; they are isolated in 1-1, 1-2, 1-3 so a change stays local.
4. **HIE-02 semantics** (A-3 remove with children, A-4 delete) follow the LLD's assumptions until golden data (Phase 4) confirms DRM behaviour.
5. The Mockito agent warning remains technical debt.

## Questions for you
1. Approve this plan?
2. Branch and merge approach above (merge to `main` only after the gate and the ADR-021 Audit-Risk review): agreed?
