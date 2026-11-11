# Phase 1 — Core write path: test report

- **Date:** 2026-11-11 · **Code state:** `1929735` (all Phase 1 code; increment 1-12 adds documentation only)
- **Machine:** Windows 11 Home, Docker Desktop with Engine 29 on WSL 2, JDK Temurin 21, Maven 3.9.9 via the wrapper
- **Data:** synthetic only (fixture names such as `G A`, `DE entity`, `PERF leaf 0001-0001`; no client, account or personal data)

## Commands and results

| Suite | Command | Passed | Failed | Skipped |
|---|---|---|---|---|
| Migrations V1–V8 + pgTAP | `scripts\db-test.ps1` (fresh database) | 211 | 0 | 0 |
| API build + tests | `cd services/mdm-api; .\mvnw.cmd -B verify` (Testcontainers, PostgreSQL 16, app login `nexus_api_test`) | 77 | 0 | 0 |
| Performance (tag `perf`) | `./mvnw -B verify -Dperf` | — | — | **not run** (deferred by the repository owner) |

pgTAP by file: `01_core_invariants` 18 · `02_workflow_invariants` 17 · `03_error_codes` 10 · `04_change_request_controls` 19 ·
`05_roles_and_privileges` 17 · `06_entitlements` 11 · `07_property_resolution` 12 · `08_change_request_functions` 8 ·
`09_apply_change_request` 26 · `10_apply_structure` 24 · `11_apply_properties` 18 · `12_validation_submit` 17 · `13_decide` 14.

JUnit by class: `ChangeRequestApiTest` 21 · `DecisionApiTest` 6 · `HierarchyApiTest` 6 · `PagingAndAsOfApiTest` 5 ·
`NodePropertiesApiTest` 2 · `EntitlementApiTest` 7 · `EntitlementServiceTest` 6 · `RolePermissionsTest` 5 ·
`BusinessClockTest` 5 · `DbErrorTranslatorTest` 8 · `ProblemShapeTest` 3 · `DatabasePrivilegeTest` 3.

## Traceability (LLD §13)

| Capability | Criterion | Tests | Result |
|---|---|---|---|
| HIE-01 | Hierarchies list with top node, paged | `HierarchyApiTest.listsHierarchiesWithTopNode`, `PagingAndAsOfApiTest.theHierarchyListPagesWithoutRepeats`, `rejectsOversizedPages`, `aMalformedCursorIsABadRequest`; `EntitlementApiTest.aScopedViewerSeesOnlyTheirHierarchy` (unreadable absent) | Pass |
| HIE-01 | Children in sort order, paged; lazy loading | `HierarchyApiTest.returnsChildrenInSortOrderWithChildFlags`, `pagesChildren`; `PagingAndAsOfApiTest.childrenPageInNameOrderWhenSortOrdersTie` | Pass |
| HIE-01 | Add a hierarchy | pgTAP 10 (add_hierarchy, duplicate code); `ChangeRequestApiTest.addHierarchyNeedsAnAllHierarchiesGrantAndAValidPurpose` | Pass |
| HIE-02 | Each action produces the expected tree | pgTAP 09 (add, insert shared, move with history), 10 (remove leaf and cascade, delete, update); `DecisionApiTest.draftSubmitApproveAndTheChangeIsLive` (add through the API) | Pass |
| HIE-02 | Negatives | pgTAP 09: `N2004` leaf, `N2001` cycle, `N2003` shared in a no-shared hierarchy; 10: `N2005`, `N2006`, `N2002`, `N2105` | Pass |
| HIE-02 | Control: tree before D unchanged | pgTAP 09, 10 ("before the effective date …"), `DecisionApiTest` (`asOf` two days earlier → 404) | Pass |
| HIE-02 | Boundary: move to the same parent | — | **Gap** (see below) |
| HIE-02 | Same result as DRM (golden) | — | **Gap**: golden framework is Phase 4 (as planned) |
| PRP-01 | Global vs local scope; clear → inherited with source; local without hierarchy `N2020`; JSON null blocks inheritance | pgTAP 11 (18 tests); pgTAP 07; `NodePropertiesApiTest` (provenance and source) | Pass |
| NEW-01 | Read at a recorded time shows what was believed then | `PagingAndAsOfApiTest.readsAtAnEarlierRecordedTimeShowWhatWasBelievedThen` | Pass (seeded history, not history written by apply) |
| NEW-01 | Future-dated change invisible today, visible at D | `PagingAndAsOfApiTest.aFutureDatedPlacementIsVisibleOnlyFromItsDate`; pgTAP 09–11 at D−1 / D | Pass |
| SEC-01 | Each role can do exactly what it should; no actor → 401 | `RolePermissionsTest` (5), `EntitlementApiTest.onlyStewardsPropose`, `onlyApproversDecide`, `aRoleWithoutThePermissionIsRefused`, `requestsWithoutAnActorAreUnauthenticated`, `unknownAndInactiveUsersAreUnauthenticated`; `ChangeRequestApiTest.viewerCannotCreate`; `DecisionApiTest.theRequesterCannotDecideEvenWithTheApproverRole` | Pass, **gap**: no generated matrix of every endpoint × every role |
| SEC-02 | Scoped steward adds under the scope, not outside; scope top is inside; sub-tree grant is not the whole hierarchy | `ChangeRequestApiTest.scopedStewardCannotProposeOutsideTheirSubtree`, `scopedStewardCanAddUnderANodeAddedEarlierInTheSameRequest`; `EntitlementServiceTest.stewardMayProposeAtAndUnderTheScopeTop`, `aSubtreeGrantDoesNotCoverTheWholeHierarchy`, `aSharedPlacementUnderTheScopeCounts` | Pass |
| SEC-02 | Cannot move a node from inside the scope to outside | — | **Gap** (see below) |
| PROG D-04 | No forged policy approval | pgTAP 05, 13 (`nexus_api` cannot write decision columns; decide records `human_review`); `DatabasePrivilegeTest.applicationCannotWriteDecisionColumns` | Pass |
| PROG D-05 | Requester kind is truthful | pgTAP 04 | Pass |
| PROG D-07 | Frozen after draft, valid transitions only | pgTAP 04, 08, 12, 13; `ChangeRequestApiTest.withdrawEndsTheDraftAndItCanNoLongerBeEdited`, `DecisionApiTest.draftSubmitApproveAndTheChangeIsLive` | Pass |
| PROG D-29 | Every applied row traceable | pgTAP 09 (audit rows carry actor and request; rows written carry the request id) | Pass |
| PROG D-36 | Delete needs a human | pgTAP 04 (commit policy with `delete_node` rejected) | Pass |
| PROG ADR-014 | App runs with least privilege | `DatabasePrivilegeTest` (3), pgTAP 05, 09 (`nexus_api` cannot write facts) | Pass |
| PROG ADR-015 | Paging, ETag, idempotency | `ChangeRequestApiTest` (428 / 412 on PATCH, items, delete; idempotent replay and 422 on a different body); `PagingAndAsOfApiTest` | Pass |
| PROG ADR-018 | Business today in `America/New_York` | `BusinessClockTest` (EST, EDT, both DST change days, configured zone mismatch) | Pass |
| PROG ADR-020 | Error codes and Problem Details | pgTAP 03; `DbErrorTranslatorTest` (8), `ProblemShapeTest` (3) | Pass |
| PROG stale base | No silent overwrite | pgTAP 09–11 (`N3001`); `DecisionApiTest.theSecondOfTwoConflictingRequestsFailsInsteadOfOverwriting` | Pass |
| PROG validation | Trial leaves nothing; findings stored; submit 422 keeps the draft | pgTAP 12; `ChangeRequestApiTest.submitWithValidationErrorsIs422KeepsTheDraftAndStoresTheFindings`, `validateIsForTheRequesterOrADeciderInScope` | Pass |
| PROG recovery | Request left approved is applied by the sweeper | `DecisionApiTest.theSweeperAppliesARequestLeftApproved` | Pass |
| Performance | LLD §10 targets | `PerfTest` (written, not run) | **Not measured** (deferred) |

## Failures and skipped tests
None in the suites that ran. No test was disabled, deleted or weakened. During the phase, these existing tests changed
setup or shape only, each recorded in the build state and LLD:
- `01_core_invariants.sql`: requests are submitted before the maker-checker tests decide them (the new transition guard).
- `HierarchyApiTest`, `EntitlementApiTest`: read `$.items` (paging envelope, ADR-015); seeding through the owner connection.
- `ProblemShapeTest`: the web slice excludes `IdempotencyFilter`, which needs a database.
- `09_apply_change_request.sql`: the "action without a handler" case moved from `update_node` to `inactivate_node` as handlers were built.

## Explicit gaps
1. **Performance not measured.** The repository owner deferred performance testing to the end of the build. `PerfTest`
   and `SyntheticHierarchy` exist and are excluded from the default build. One finding before the deferral: bulk
   placement inserts into a large hierarchy with stale statistics are slow (cycle-check plan); Phase 4 loads must refresh
   statistics between batches.
2. **Move to the same parent** (HIE-02 boundary) and **moving a node out of a steward's scope** (SEC-02 negative) have no
   test. The code checks PROPOSE on both the node's current place and the target (`ItemFactory.placement`), but no test proves it.
3. **No generated role × endpoint matrix** (SEC-01): permissions are covered per role and per command, not exhaustively.
4. **Serialization-failure retry** in `ApplyService` is not exercised (hard to force reliably); reviewed only.
5. **Golden parity for HIE-02** waits for the Phase 4 golden framework, as planned.
6. **Observability (LLD §11):** structured logs for apply exist; the listed Micrometer metrics are not built.
7. **OpenAPI:** closed after the gate: springdoc approved and added; `docs/api/openapi.json`, checked by `OpenApiDocumentTest`.
8. **CI has never run on GitHub** (no remote; OD-11).

## Gate result
All suites that ran are green, and every in-scope criterion is covered by a passing test or listed above as an explicit,
explained gap. **Gate: pass with the gaps above**, subject to your approval.
