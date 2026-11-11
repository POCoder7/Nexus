# Phase 2 — Governance: plan

- **Status:** Awaiting approval (2026-11-11)
- **Follows:** `docs/design/phase-2-governance/LLD.md` (approved), ADR-017, ADR-023, ADR-024, and **ADR-035 (Proposed with
  this plan)**: Camunda behind engine-neutral ports with an in-process reference driver, so Camunda stays replaceable (your
  requirement). The LLD carries the change as §3.3 and a note under §16, marked proposed until you approve this plan.
- **Exit criteria (BUILD_PROTOCOL §2, LLD):** a request moves Submit → (Enrich/Approve) → Commit through the `wf` layer;
  worklist API; separation of duties and human-only decisions proven; commit policy runs in shadow mode. Added by ADR-035:
  the same end-to-end scenarios pass on both engine adapters.

## Orient (baseline, 2026-11-11)
| Check | Result |
|---|---|
| `git status` | clean; branch `feature/HIE-02-phase-1-core-write-path` at `5f851e8` (Phase 1 approved, not merged to `main`: ADR-021 Audit-Risk review skipped for now); no remote (OD-11) |
| `scripts\db-test.ps1` | pass: V1–V8, 211/211 pgTAP (migrations unchanged since the Phase 1 gate) |
| `mvnw.cmd -B verify` | pass: 78/78 (after OpenAPI, `caf96ec`; later commits are documentation only) |
| Shared environment (OD-44) | none → editing V1–V8 is allowed (CLAUDE.md rule 6) |
| Already built in Phase 1 | `mdm.system_setting` with `business_time_zone` (LLD §4.1 lists it; CR-01 moved it forward) |
| Open decisions this phase waits on | OD-01c (Camunda hosting): deployment only, not the build. OD-08: policies stay `shadow`; `active` refused by a guard. OD-09: GOV-04/07/08/09/11/16 and AUD-02 stay outline. OD-18a: Audit-Risk review of ADR-023, skipped for now like ADR-021, so merging to `main` needs it or your waiver |

## Scope
**In (decided):** GOV-01 (Parity), GOV-02 (Parity), GOV-12 (Improve, shadow mode only), GOV-13 (Parity); PROG: ADR-023
control fixes D-06, D-10, D-11, D-12, D-13, D-14, D-15, D-32, D-33; business-day boundaries in `wf` (ADR-018); Camunda
integration (ADR-024) behind the engine-neutral ports (ADR-035).

**Infrastructure only (parity pending):** GOV-03 editable/required properties as the Enrich stage needs them; GOV-05
separation of duties proven as a control; GOV-06 `any_group` / `all_groups` outcomes as they exist.

**Outline only (OD-09):** GOV-04 conditions and splits (split raises `N2202`), GOV-07 SLAs and claim expiry, GOV-08 / GOV-16
notifications, GOV-09 push-back, GOV-11 comments and attachments, AUD-02 history API.

**Out:** UI (Phase 3), bulk requests (Phase 4), performance runs (deferred to the end of the build by you; perf tests
written as tagged and not run, like Phase 1).

## Way of working
- New branch `feature/GOV-02-phase-2-governance` from the Phase 1 branch (Phase 1 is not on `main` yet). One local commit
  per increment with its capability ID; I ask before each commit; nothing is pushed.
- Tests first; `db-test` and `mvnw verify` green before every commit. The default build runs all workflow scenarios on
  the in-process driver; the Camunda runs are tagged `camunda` (`./mvnw -B verify -Dcamunda`).

## Work breakdown (LLD §16, with ADR-035 changes in **bold**)
| # | Increment | Size | Capabilities | Tests written first |
|---|---|---|---|---|
| 2-1 | `mdm.business_today()` / `business_day_start()`; `wf` day boundaries (caps, sampling, `review_due`); `policy_activation_allowed` guard | S | PROG, GOV-12 | pgTAP: boundary at midnight `America/New_York` (EST and EDT); `active` approval refused |
| 2-2 | Bitemporal `wf.user_group_member` (D-33), governed membership changes (CR-10), `wf.is_member` used everywhere (D-15), `wf.config_audit` | M | PROG | pgTAP: past membership reconstructable; no update/delete; future-dated member cannot engage the kill switch; four-eyes on membership |
| 2-3 | Claim guard and functions (D-12); close rules (D-13); `wf.record_stage_decision` | M | PROG, GOV-02 | pgTAP: AI or non-member claim refused; reject without a rejecting decision refused; AI withdraws a human's request refused; SoD on/off; idempotent decision, conflicting decision `N2201` |
| 2-4 | `items_in_scope` by ancestor walk at `effective_from` (D-10, D-11), same for required-property and condition checks | M | PROG | pgTAP: old vs new results equal on fixtures (before the old one is replaced); node moved into scope after `effective_from` |
| 2-5 | Policy row lock (D-14); activation guard | S | GOV-12 | JUnit: two connections at cap − 1 → exactly one auto-commit (setting enabled in a test database only); pgTAP: `active` refused without the setting |
| 2-6 | Bridge: decider attribution (D-06), clearance rows, `governed_by_workflow`, enrichment items, draft-only exception for the bridge; `requires_workflow` refuses core-mode decisions (B-3) | M | PROG, GOV-02 | pgTAP: two-instance fixture → right decider; Phase 1 apply uses only cleared items; `nexus_wf` cannot write `mdm`; core-mode decision refused on a `requires_workflow` hierarchy |
| 2-7 | `wf.advance_instance`, `wf.complete_stage`; model activation by a second admin (N1014); model loader from definition files | M | GOV-01, GOV-02 | pgTAP: advance through Submit → Approve → Commit; idempotent calls; self-activation refused; JUnit: load file → draft → activate; in-flight request keeps v1 after v2 |
| 2-8 | API: submit with model, stage decisions, claims, enrichment items, instance view, model and policy admin endpoints | M | GOV-01, GOV-02, GOV-12 | JUnit per endpoint: SoD refusal explained in words; 409 `N2201`; 403 `N1013`, `N1014`; withdraw closes the instance |
| 2-9 | `wf.worklist_page` and `GET /worklist` (nine views, counts, search, model filter, keyset); urgent flag | M | GOV-13 | JUnit: each view for a sample user; SoD stage absent from ASSIGNED, present in PARTICIPATED; paging across equal `due_at`; counts. Perf test written, tagged, not run |
| **2-10a** | **Ports `WorkflowEngine` and `WorkflowSteps`; outbox consumer offsets (D-32); `OutboxRelay`; in-process reference driver; contract suite** | M | GOV-02, PROG | **Contract suite on the in-process driver:** add-leaf end to end, enrichment, rejection, withdrawal, policy evaluated in shadow mode; relay resumes from its offset; duplicate events ignored; **package-boundary test** (no `io.camunda` import outside `…engine.camunda`) |
| **2-10b** | **Camunda adapter:** client configuration, `nexus-request.bpmn`, job adapters mapping variables to `WorkflowSteps`; local Camunda in `docker-compose.yml` (profile `workflow`) | M | GOV-02 | **Same contract suite on Camunda's process-test engine** (tag `camunda`); variables are ids only |
| 2-11 | `EngineReconciler`; resilience cases | S | PROG | On both adapters: process lost → recreated → request completes; engine down → decisions still recorded, stages resume |
| 2-12 | Records: data model, error-code registry, OpenAPI regenerated, patterns, changelog, test report, summary, build state | S | PROG | review |

## Decisions I expect to need
- **ADR-035** (this plan): engine-neutral ports plus the in-process reference driver. Please accept or change it.
- Error codes beyond the registry are added as the LLD names them (`N1010`–`N1014`, `N2201`, `N2202` exist; new ones
  recorded in the registry in 2-12). No other new ADR expected; anything else goes into the LLD as *Built in …* notes.

## New dependencies (your approval needed, CLAUDE.md rule 8)
| Dependency | Why | Where |
|---|---|---|
| Camunda 8 Spring SDK (`io.camunda:spring-boot-starter-camunda-sdk`, latest patch of the 8.x line compatible with Spring Boot 3.4.5, version pinned and checked before adding) | Zeebe client, job workers, deployment | main, used only in `…engine.camunda` |
| Camunda process test (`io.camunda:camunda-process-test-spring`, same 8.x line) | Runs the contract suite on a real engine (Testcontainers) | test scope, tag `camunda` |
| Camunda 8 container image for local runs | `docker compose --profile workflow up` | `docker-compose.yml` (local only) |
No CI change now. Running the `camunda` tag in CI is a later CI change that I'll ask you about separately.

## Risks, assumptions and questions
| # | Item | Handling |
|---|---|---|
| R-1 | **Camunda licence:** recent Camunda 8 self-managed releases need a commercial licence for production use; hosting is still open (OD-01c) | Your call with the vendor and Procurement; ADR-035 keeps the exit path open, and nothing in Phases 2–9 depends on Camunda outside the adapter |
| R-2 | The process loop exists twice (BPMN and the in-process driver) | Contract suite on both; BPMN kept minimal (no business logic) |
| R-3 | Camunda image through the internal registry (DEVELOPER_SETUP §2) | If it cannot be pulled, 2-10b waits; everything else, including the contract suite on the in-process driver, does not |
| R-4 | Test time: Camunda's test engine is heavy | Tagged `camunda`, out of the default build |
| R-5 | Merging to `main` | Phases 1 and 2 edit guards; ADR-021 and ADR-023 ask for an Audit-Risk review before merge (OD-18a), skipped for now, so a merge needs the review or your explicit waiver |
| A-1 | LLD assumptions B-1 to B-7 hold (stages sequential; requester picks the model; and so on) | As the LLD says |

**Questions for you**
1. Do you approve this plan and ADR-035 (Camunda replaceable through ports, with an in-process reference driver)?
2. Do you approve the three Camunda dependencies above (SDK, process-test library, local container image)?
3. GitHub remote (OD-11): my recommendation stands, create a private repository before Phase 2 code is pushed anywhere. Send the URL when it's ready.
