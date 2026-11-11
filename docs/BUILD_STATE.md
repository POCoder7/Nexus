# Build state

- **Current phase:** 2 — Governance
- **Step in loop:** Build — branch `feature/GOV-02-phase-2-governance` (from the Phase 1 branch)
- **Baseline:** db-test **pass** 311/311 · mvnw verify **pass** 87/87 (after 2-8b, 2026-11-11)
- **Last commit:** see `git log -1`

## Completed phases
| Phase | Gate result | Summary | Date |
|---|---|---|---|
| 0 — Foundation | Pass locally; approved by the repository owner. Gap: CI not yet run on GitHub (OD-11) | `docs/phases/phase-0/SUMMARY.md` | 2026-11-11 |
| 1 — Core write path | Pass with gaps; **approved by the repository owner** (performance not measured; test gaps listed in the report; CI not run, OD-11) | `docs/phases/phase-1/SUMMARY.md`, `TEST_REPORT.md` | 2026-11-11 |

## Current phase progress
| Increment | Capability | Status | Tests | Notes |
|---|---|---|---|---|
| 1-1 Error codes + Problem Details | PROG | Done `95091fc` | pgTAP 03 (10), JUnit 11 | 68 guards coded; registry extended |
| 1-2 Change-request controls | PROG, HIE-02 | Done `f92fe1a` | pgTAP 04 (19) | + delete-only-drafts guard (LLD updated); 01 fixture submits first |
| 1-3 Roles and privileges | PROG (D-04) | Done `5925522` | pgTAP 05 (17), JUnit 3 | audit trigger and bridge as definer; app runs as nexus_api login |
| 1-4 Entitlements, actor, settings, BusinessClock, `/me` | SEC-01, SEC-02 | Done `69bf05f` | pgTAP 06 (11), JUnit 23 | settings/clock moved here from 1-5 (plan updated) |
| 1-5 Keyset paging, `recordedAsOf`, UTC sessions | HIE-01, NEW-01 | Done `592fb46` | JUnit 5 | offset paging removed (ADR-015) |
| 1-6 Resolved properties with provenance | PRP-01 | Done `6a858f4` | pgTAP 07 (12), JUnit 2 | `node_properties_resolved` in V3 |
| 1-7 Change requests: create, edit, items, withdraw | HIE-02, PRP-01 | Done `27119ab` | pgTAP 08 (8), JUnit 16 | `allocate_node`, `withdraw_change_request` (N1025, N2104); ETag 428/412; Idempotency-Key; expected values across earlier items; ProblemShapeTest slice excludes IdempotencyFilter (setup only) |
| 1-8a Apply: framework, set-from-D, add/insert/move, stale base, events | HIE-02 | Done `da2d9b7` | pgTAP 09 (26) | `apply_fact` generic routine; `change_event`, `change_item_clearance`; new code N2105; stale-base JSON in DETAIL (ADR-020; LLD noted) |
| 1-8b Apply: remove, delete, update node, add hierarchy | HIE-02, HIE-01 | Done `d10e67c` | pgTAP 10 (24), JUnit 1 | delete refused for top node / children / references / scheduled changes; cascade follows primary links (LLD noted); 09 fixture: unavailable action now `clear_property` (setup only) |
| 1-8c Apply: set and clear property, item limit by origin | PRP-01 | Done `f72d738` | pgTAP 11 (18) | limits in `system_setting`; JSON null kept; 09 fixture: unavailable action now `inactivate_node` (setup only) |
| 1-9 Validation (trial apply + rules) and submit | HIE-02, PRP-01 | Done `c1efe3a` | pgTAP 12 (17), JUnit 4 | shared item path for apply and trial; `NEXUS.TRIAL_APPLY` system rule; N2106; 422 keeps findings |
| 1-10 Decision, apply service, sweeper, review queue | HIE-02, PRP-01 | Done `de69b7d` | pgTAP 13 (14), JUnit 6 (SLICE-01 end to end) | `record_apply_failure` added (LLD noted); serialization-retry path not exercised by a test (hard to force; reviewed) |
| 1-11 Performance tests + synthetic generator | HIE-01, PRP-01 | **Deferred** (scaffold committed, not run) | none run | owner deferred performance testing to the end of the build (2026-11-11); `PerfTest` (tag `perf`, excluded from default build) and `SyntheticHierarchy` committed unverified; finding kept below |
| 1-12 Records | PROG | Done (this commit) | — | data model, registry, README, setup, CHANGELOG, patterns, test report, summary |
### Phase 2 progress
| Increment | Capability | Status | Tests | Notes |
|---|---|---|---|---|
| 2-1 Business-day functions, `wf` day boundaries, activation guard | PROG, GOV-12 | Done `19f92c9` | pgTAP 14 (11) | `system_setting` moved V8 → V1; guard in `trg_policy_guard`, `N2225` |
| 2-2 Bitemporal membership, `wf.is_member`, governed changes, config audit | PROG | Done `2409c90` | pgTAP 15 (21) | new V9; only definer functions write membership; D-15 fixed; codes N1026, N2230–N2233 |
| 2-3 Claims (D-12), close rules (D-13), `record_stage_decision` | PROG, GOV-02 | Done `6f7de5b` | pgTAP 16 (24) | functions owned by `nexus_wf`, callable by the API; SoD and human-only proven |
| 2-4 Scope by ancestor walk at the effective date (D-10, D-11) | PROG | Done `fefe066` | pgTAP 17 (9) | old vs new equal on 28 cases; old rule kept only in the test |
| 2-5 Policy row lock for the daily cap (D-14) | GOV-12 | Done `20f3de4` | JUnit 1 (two connections) | activation guard already in 2-1 |
| 2-6 Bridge: D-06 attribution, clearance, governed flag, enrichment, `requires_workflow` | PROG, GOV-02 | Done `b30010f` | pgTAP 18 (16) | draft-only guard split into an invoker check and an owner-run version bump (LLD noted); N2107 |
| 2-7 Stage progression, model activation by a second admin, model loader | GOV-01, GOV-02 | Done `72bf7d0` | pgTAP 19 (19), JUnit 2 | fixtures in 16–18 and the concurrency test name an activator (setup only); N2234, N2235 |
| 2-8a Submit with a workflow model, urgent flag, governed withdraw | GOV-02 | Done `33fcb1e` | JUnit 3 | 2-8 split into a/b/c (size); `start_instance` owner-run with requester and model checks (N2236); OpenAPI regenerated |
| 2-8b Stage decisions, claims, enrichment, instance view, refusals in words | GOV-02 | Done (this commit) | JUnit 3 | `wf.why_cannot_act`; `WorkflowGateway`; N2201 is 422 per ADR-020 (LLD table corrected in a note); OpenAPI operation ids kept unique (test added) |
| 2-8c … 2-12 | GOV-01, GOV-12, GOV-13 | Planned | per plan | |

## Decisions awaiting human review
| ADR | Title | Why it needs review |
|---|---|---|
| ADR-005 | Policy-governed straight-through commit | Needs Audit/Risk sign-off before any policy is activated |
| ADR-006 to ADR-008 | Bitemporal model, ownership graph, AI proposes/humans approve | Proposed; awaiting team confirmation |
| ADR-013 to ADR-034 | Design-track decisions | Accepted by the owner; confirmations pending for ADR-014, 021, 023, 026, 027 (Security / Audit-Risk), see `docs/design/OPEN_DECISIONS.md` |


## Open questions for the human
1. (none blocking) Phase 2 plan, ADR-035 and the Camunda dependencies approved 2026-11-11; building.
2. OD-11: recommended now, before Phase 2 (prove CI green on the Phase 1 baseline). Waiting for a private repository URL; the first push still needs your go-ahead.
3. OD-18a: Audit-Risk review of ADR-021 **skipped for now** by the repository owner (2026-11-11). ADR-021 still asks for it before merge to `main`; merging needs the review or your explicit waiver.

## Scope changes
- **Camunda must stay replaceable** (repository owner, 2026-11-11): ADR-035 proposed with the Phase 2 plan.
- **Phase order kept:** the owner considered building Phase 3 (UI) before Phase 2 and chose Phase 2 first (2026-11-11).
- **OpenAPI added** (springdoc 2.8.6, JSON only; endpoint on only in `local`/`test`), approved by the repository owner 2026-11-11; committed description `docs/api/openapi.json`, kept current by `OpenApiDocumentTest`.
- **Performance testing deferred to the end of the build** by the repository owner on 2026-11-11: Phase 1 increment 1-11 is not run; its tests and generator are kept (`./mvnw -B verify -Dperf`). Phase 1 gate reports the LLD §10 targets as "not measured".
- **Phase 7 (AI assistance) deferred** by the repository owner on 2026-11-11 (OD-38): design approved; the build goes from Phase 6 to Phase 8. The `BUILD_PROTOCOL.md` phase table is updated in design step 5 (wiring).

## Known gaps, stubs and technical debt
- Running the API locally uses the docker-compose owner account; only tests run as the least-privilege login (documented in DEVELOPER_SETUP).
- Perf finding (1-11, before deferral): one statement inserting many placements into a large hierarchy whose statistics are stale runs the cycle-check trigger with an "empty table" plan (measured 29 s per 5 000 rows from empty vs 1.2 s with current statistics; one guarded insert under a 50 000-child parent about 21 ms). Guards unchanged. Phase 4 bulk loading must refresh statistics between batches; the generator does.
- CI has never run on GitHub (no remote; OD-11).
- Mockito dynamic-agent warning in tests (future JDKs will block it).
- `scripts/check-setup.*` still requires a local `mvn`.
- Schema control gaps and untested guards (D-04 to D-07, D-12 to D-15, D-22, D-29, D-33 in `docs/design/DESIGN_STATE.md`; OD-18).

## Next action
Increment 2-8c (model and commit-policy admin endpoints), then 2-9 … 2-12, asking before each commit. Performance tests deferred to the end of the build.
