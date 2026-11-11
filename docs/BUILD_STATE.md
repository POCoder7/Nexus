# Build state

- **Current phase:** 1 — Core write path
- **Step in loop:** Build — branch `feature/HIE-02-phase-1-core-write-path`
- **Baseline:** db-test **pass** 211/211 · mvnw verify **pass** 77/77 (after 1-10, 2026-11-11)
- **Last commit:** see `git log -1`

## Completed phases
| Phase | Gate result | Summary | Date |
|---|---|---|---|
| 0 — Foundation | Pass locally; approved by the repository owner. Gap: CI not yet run on GitHub (OD-11) | `docs/phases/phase-0/SUMMARY.md` | 2026-11-11 |

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
| 1-12 Records | PROG | Planned | per plan | |
## Decisions awaiting human review
| ADR | Title | Why it needs review |
|---|---|---|
| ADR-005 | Policy-governed straight-through commit | Needs Audit/Risk sign-off before any policy is activated |
| ADR-006 to ADR-008 | Bitemporal model, ownership graph, AI proposes/humans approve | Proposed; awaiting team confirmation |
| ADR-013 to ADR-034 | Design-track decisions | Accepted by the owner; confirmations pending for ADR-014, 021, 023, 026, 027 (Security / Audit-Risk), see `docs/design/OPEN_DECISIONS.md` |


## Open questions for the human
1. (none blocking) Phase 1 plan approved 2026-11-11; building.
2. OD-11: create the GitHub remote when ready; CI runs only after a push you approve.
3. OD-18a: Audit-Risk review of ADR-021 before the Phase 1 branch is merged to `main`.

## Scope changes
- **Performance testing deferred to the end of the build** by the repository owner on 2026-11-11: Phase 1 increment 1-11 is not run; its tests and generator are kept (`./mvnw -B verify -Dperf`). Phase 1 gate reports the LLD §10 targets as "not measured".
- **Phase 7 (AI assistance) deferred** by the repository owner on 2026-11-11 (OD-38): design approved; the build goes from Phase 6 to Phase 8. The `BUILD_PROTOCOL.md` phase table is updated in design step 5 (wiring).

## Known gaps, stubs and technical debt
- Running the API locally now needs the `local` profile and a user (`-Dspring-boot.run.profiles=local`, `mdm.api.local-user`); README quick start to update in 1-12.
- V1, V5, V6 edited on the branch: local `docker compose` databases must be recreated (`docker compose down -v`); note in 1-12.
- New error codes N1025, N2104, N2105, N2106, hints for N2004–N2006 (`hierarchy.parent_is_leaf`, `hierarchy.remove_with_children`, `node.referenced`) and API rule codes (`change_item.*`, `change_request.not_draft`) to add to the registry (CONSISTENCY_REVIEW §3) in 1-12.
- Perf finding (1-11, before deferral): one statement inserting many placements into a large hierarchy whose statistics are stale runs the cycle-check trigger with an "empty table" plan (measured 29 s per 5 000 rows from empty vs 1.2 s with current statistics; one guarded insert under a 50 000-child parent about 21 ms). Guards unchanged. Phase 4 bulk loading must refresh statistics between batches; the generator does.
- CI has never run on GitHub (no remote; OD-11).
- Mockito dynamic-agent warning in tests (future JDKs will block it).
- `scripts/check-setup.*` still requires a local `mvn`.
- Schema control gaps and untested guards (D-04 to D-07, D-12 to D-15, D-22, D-29, D-33 in `docs/design/DESIGN_STATE.md`; OD-18).

## Next action
Increment 1-12 (records), then the Phase 1 test gate (stop for approval). Performance tests deferred to the end, asking before each commit
