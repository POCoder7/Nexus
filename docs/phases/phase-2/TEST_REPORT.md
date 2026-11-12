# Phase 2 — Governance: test report

- **Date:** 2026-11-11 · **Code state:** `2a814a8` plus `db/tests/20_workflow_gaps.sql` (added with the records, test only)
- **Machine:** Windows 11 Home, Docker Desktop with Engine 29 on WSL 2 (3.7 GiB for Docker), JDK Temurin 21, Maven 3.9.9 via the wrapper
- **Data:** synthetic only (fixture names such as `CT leaf`, `WL urgent`, users such as `ct_approver`; no client, account or personal data)

## Commands and results

| Suite | Command | Passed | Failed | Skipped |
|---|---|---|---|---|
| Migrations V1–V9 + pgTAP | `scripts\db-test.ps1` (fresh database) | 319 | 0 | 0 |
| API build + tests | `cd services/mdm-api; .\mvnw.cmd -B verify` (Testcontainers; API as `nexus_api_test`, worker as `nexus_wf_test`) | 100 | 0 | 0 |
| Engine contract on Camunda (tag `camunda`) | `./mvnw -B verify -Dcamunda` | — | — | **not run** (deferred by the repository owner; see gaps) |
| Performance (tag `perf`) | `./mvnw -B verify -Dperf` | — | — | **not run** (deferred) |

New this phase: pgTAP `14_business_day` 11 · `15_membership` 21 · `16_stage_decisions` 24 · `17_scope` 9 · `18_bridge` 16 ·
`19_model_lifecycle` 21 · `20_workflow_gaps` 6 (108; Phase 1 files unchanged in their assertions). JUnit: `WorkflowSubmitApiTest` 3 ·
`WorkflowStageApiTest` 3 · `WorkflowAdminApiTest` 3 · `WorklistApiTest` 2 · `CommitPolicyConcurrencyTest` 1 ·
`ModelDefinitionLoaderTest` 2 · `InProcessEngineContractTest` 7 · `EngineBoundaryTest` 1 (22).

## Traceability (LLD §13)

| Capability | Criterion | Tests | Result |
|---|---|---|---|
| GOV-01 | Load file → draft → activate by a second admin; creator refused; invalid model refused | pgTAP 19; `ModelDefinitionLoaderTest`; `WorkflowAdminApiTest.modelsAreLoadedByOneAdministratorAndActivatedByAnother` | Pass |
| GOV-01 | In-flight request keeps v1 after v2 activates; active model cannot be edited | pgTAP 19, 20 | Pass |
| GOV-02 | Submit → Approve → Commit end to end through the engine | `InProcessEngineContractTest.addLeafEndToEnd` | Pass (in-process); **Camunda run deferred** |
| GOV-02 | Enrichment item allowed / not allowed by the task (`N1013`) | pgTAP 18; `WorkflowStageApiTest.enrichmentItemsAreCheckedByTheStagesTask`; contract `enrichmentThenCommitAppliesBothItems` | Pass |
| GOV-02 | Decision on a stage that has not started | pgTAP 20 (`N1016`, reason `wf.stage_not_open`) | Pass |
| GOV-02 | Model with only Submit and Commit | `CommitPolicyConcurrencyTest` (CC_MODEL) | Pass |
| GOV-02 | Same as DRG (golden) | — | **Gap**: Phase 4 framework (as planned) |
| GOV-12 | Shadow evaluation on every covered request; shadow summary | contract `addLeafEndToEnd` (shadow outcome recorded); pgTAP 20 (`v_shadow_summary`) | Pass |
| GOV-12 | `active` approval refused without the sign-off setting | pgTAP 14; `WorkflowAdminApiTest` (`policy.activation_not_allowed`) | Pass |
| GOV-12 | Two evaluations at cap − 1 → one auto-commit (D-14) | `CommitPolicyConcurrencyTest` | Pass |
| GOV-12 | AI-originated request never eligible | — | **Gap**: an AI cannot start a workflow yet (its submit action needs model and confidence); belongs with Phase 7 (deferred). The V6 check exists |
| GOV-12 | Evaluation at the business-day boundary | pgTAP 14 (boundary functions used by the cap and sampling) | Pass (functions), evaluation itself not run at a boundary |
| GOV-13 | Each view returns the right requests; SoD stage absent from ASSIGNED, present in PARTICIPATED; paging across equal due dates; counts | `WorklistApiTest` (2) | Pass |
| PROG D-06 | Correct decider after a split | pgTAP 18 (two-instance fixture) | Pass |
| PROG D-10 / D-11 | Scope by ancestor walk equals the old rule; effective date decides | pgTAP 17 (28 cases) | Pass |
| PROG D-12 / D-13 | Claims human and eligible; reject and withdraw authorised | pgTAP 16; `WorkflowStageApiTest` | Pass |
| PROG D-14 / D-15 / D-33 | Cap under concurrency; kill switch uses membership dates; membership history and four-eyes | `CommitPolicyConcurrencyTest`; pgTAP 15 | Pass |
| PROG D-32 | Consumer offsets; relay resumes from its offset | `InProcessEngineContractTest` (repeated deliveries, failing step) | Pass |
| Controls | SoD, human-only, maker-checker on models and policies, layer separation (`nexus_wf` cannot write `mdm`), append-only audit | pgTAP 15, 16, 18, 19; `WorkflowStageApiTest`; `WorkflowAdminApiTest` | Pass |
| ADR-035 | Camunda replaceable: no Camunda type outside its adapter; same contract on both engines | `EngineBoundaryTest`; contract on in-process | Pass (boundary, in-process); **Camunda run deferred** |
| Resilience | Process lost → recreated → request completes; failing step keeps the decision and resumes | contract `aProcessLostWhileItsStageWasDecidedIsRecreatedAndResumes`; `aFailingStepKeepsTheDecisionAndResumesWhenFixed` | Pass (in-process) |
| Performance | LLD §10 (worklist, decision, stage advance, policy evaluation) | — | **Not measured** (deferred) |

## Failures and skipped tests
None in the suites that ran. No test was disabled or weakened. Changes to existing tests this phase, setup or shape only:
- Fixtures that activate models by `UPDATE` (pgTAP 16–18, `CommitPolicyConcurrencyTest`) now name an activator, which the new GOV-01 rule requires.
- `WorkflowStageApiTest` expects 422 for a conflicting decision (`N2201`): ADR-020 maps class `N2` to 422; the LLD table said 409 (corrected in a note).
- `OpenApiDocumentTest` now also refuses duplicate operation ids (a strengthening).

## Defects found by tests during the phase (fixed)
1. `wf.close_instance` changed the status before recording the commit action, so the bridge found no decider and the maker-checker guard refused the approval (`N1006`). The action is now recorded first. Regression in pgTAP 19.
2. The in-process driver marked a message handled before handling it, so a failed delivery was skipped on retry. Fixed; covered by the failing-step test.
3. Commit `c99dea1` was made with `OpenApiDocumentTest` failing (operation-id clashes from Phase 1); fixed in `138c50f`, and commits now run only after a green check.

## Explicit gaps
1. **Engine contract on Camunda not run** (deferred to the end of the build by the repository owner, 2026-11-11). Camunda's test runtime needs Elasticsearch (2 GB heap) and Camunda in Docker; this machine gives Docker 3.7 GiB. The adapter, BPMN and test are written; the variable set (ids only) is not asserted by a test on Camunda yet.
2. **Performance not measured** (deferred), including the worklist test.
3. **AI-originated request never eligible** has no test (Phase 7).
4. **Golden parity** for GOV-02 and GOV-13 waits for Phase 4.
5. **Metrics and alerts (LLD §11)** are structured log lines (`alert=true`); the Micrometer metrics are not built.
6. **Timers, escalation, notifications, push-back, splits** (GOV-04, 07, 08, 09, 16) are outline only, as planned (OD-09).
7. **CI has never run on GitHub** (no remote, OD-11).

## Gate result
All suites that ran are green; every in-scope criterion is covered by a passing test or listed above as an explicit, explained gap.
**Gate: pass with the gaps above**, subject to your approval.
