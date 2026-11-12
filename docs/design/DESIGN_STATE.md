# Design state

- **Current item:** Design track **complete and approved** (2026-11-11)
- **Status:** Approved. Changes from here follow the LLD rule: update the LLD and write an ADR before code changes
- **Session date:** 2026-11-11 (overview and patterns approved the same day; Phase 0 built and approved first)

## Documents
| Document | Status | Confidence | Last updated |
|---|---|---|---|
| architecture/overview.md | Approved; updated for ADR-019 (apply in SQL) | Medium | 2026-11-11 |
| architecture/patterns.md | Approved (25 entries); P-07, P-09 updated for ADR-019 | Medium | 2026-11-11 |
| design/UI_STANDARD.md | Written by a human (needs design-system details) | Medium | 2026-11-11 |
| design/TRACEABILITY.md | All 91 capabilities; OD-13 decisions and Phase 1 LLD links applied | Medium | 2026-11-11 |
| design/OPEN_DECISIONS.md | Recommendations adopted by the owner moved to Decided; remaining open items listed | — | 2026-11-11 |
| adr/ADR-013 … ADR-018 | Accepted (014 and 017 with confirmations pending) | — | 2026-11-11 |
| adr/ADR-019 … ADR-022 | Accepted (021 with Audit-Risk review pending) | — | 2026-11-11 |
| adr/ADR-023, ADR-024 | Accepted (023 with Audit-Risk review pending) | — | 2026-11-11 |
| adr/ADR-025 | Accepted | — | 2026-11-11 |
| adr/ADR-026, ADR-027 | 026 Accepted (OD-29 open); 027 Proposed (OD-31, OD-32 open) | — | 2026-11-11 |
| adr/ADR-028, ADR-029 | Accepted | — | 2026-11-11 |
| adr/ADR-030 | Accepted (OD-34, OD-35 open) | — | 2026-11-11 |
| adr/ADR-031 | Accepted; implementation deferred (OD-38) | — | 2026-11-11 |
| adr/ADR-032 | Accepted (OD-39, OD-40 open) | — | 2026-11-11 |
| adr/ADR-033, ADR-034 | Accepted (IdP open) | — | 2026-11-11 |
| design/phase-0 | Not written: Phase 0 was built first by your instruction (sequence A); its plan, test report and summary are in `docs/phases/phase-0/` | — | 2026-11-11 |
| design/phase-1-core-write-path/LLD.md | Approved 2026-11-11 (two small corrections made while writing Phase 2: validation also in `in_review`; writing guard triggers run as owner) | Medium | 2026-11-11 |
| design/phase-2-governance/LLD.md | Approved 2026-11-11 | Medium | 2026-11-11 |
| design/phase-3-steward-ui/LLD.md | Approved 2026-11-11 | Medium (structure); Low (visual detail) | 2026-11-11 |
| design/phase-4-data-loading-and-parity/LLD.md | Approved 2026-11-11 | Medium (design); Low (extract format unknown) | 2026-11-11 |
| design/phase-5-remaining-parity/LLD.md | Approved 2026-11-11 | Medium (designed); Low (outlines) | 2026-11-11 |
| design/phase-6-ownership-and-ubo/LLD.md | Approved 2026-11-11 | Medium | 2026-11-11 |
| design/phase-7-ai-assistance/LLD.md | Approved 2026-11-11; **build deferred (OD-38)** | Medium | 2026-11-11 |
| design/phase-8-exports-and-reconciliation/LLD.md | Approved 2026-11-11 | Medium | 2026-11-11 |
| design/phase-9-hardening/LLD.md | Approved 2026-11-11 | Medium | 2026-11-11 |
| design/CONSISTENCY_REVIEW.md | Approved 2026-11-11; 13 findings fixed (CR-01 to CR-13) | — | 2026-11-11 |
| Wiring (`BUILD_PROTOCOL.md` §1–§3, `CLAUDE.md` read-first and rule 3) | Approved 2026-11-11 | — | 2026-11-11 |
| design/phase-3-steward-ui/prototypes/landing.html | Landing-page prototype; combined design chosen (OD-27) | Prototype only: placeholder tokens, synthetic data | 2026-11-11 |

## What exists (verified against the files on 2026-11-11)

**Database (V1–V6, `services/mdm-api/src/main/resources/db/migration`)**
- Schemas: `mdm` (V1–V3), `mdm_stage` (V3, DRM extract staging), `wf` (V4, V6), `wf_bridge` (V5).
- Bitemporal fact tables with `trg_bitemporal_guard` (no delete; only `recorded_period` may change):
  `node_attr`, `node_identifier`, `legal_entity_profile`, `hierarchy_relationship`, `property_value` (V1),
  `ownership_edge` (V2).
- Append-only tables (`mdm.trg_append_only`): `mdm.audit_log`, `wf.stage_group_decision`, `wf.instance_action`,
  `wf.policy_event`, `wf.policy_evaluation`.
- Row audit (`trg_audit_row` into `mdm.audit_log`): `node`, `node_attr`, `node_identifier`, `legal_entity_profile`,
  `hierarchy`, `hierarchy_relationship`, `property_definition`, `property_value`, `change_request`, `version`,
  `ownership_edge`. Actor and request come from `SET LOCAL mdm.actor_id` / `mdm.change_request_id`.
- Guards: `trg_cr_maker_checker`, `trg_hierarchy_integrity` (cycles, top node, shared nodes),
  `trg_property_value_check` (scope and type), `wf.trg_model_status` / `wf.trg_model_frozen`,
  `wf.trg_decision_guard` (membership + `wf.can_act`), `wf.trg_action_guard` (truthful actor kind, human-only
  decisions; extended in V6 for policy commits), `wf.trg_policy_guard`, `wf.trg_policy_scope_frozen`,
  `wf.trg_review_guard`; CHECK hard limits on `wf.commit_policy.allowed_actions`.
- Read functions: `mdm.node_attr_asof`, `mdm.hierarchy_tree`, `mdm.property_value_asof`, `mdm.effective_ownership`,
  `mdm.ubo_ownership_prong`, `mdm.ubo_control_prong`, `mdm.export_drm`, `mdm.run_export`; `wf.worklist`,
  `wf.v_sla_status`, `wf.v_shadow_comparison`, `wf.v_shadow_summary`, `wf.v_commit_policy_daily`.
- Workflow operations in SQL: `wf.start_instance`, `wf.split_instance`, `wf.close_instance`,
  `wf.apply_commit_policy`, `wf.evaluate_commit_policy`, policy lifecycle helpers, `wf.sample_auto_commits`.
  **Not** in SQL (by design, per `docs/data-model.md`): stage activation/advancement, claim/unclaim,
  push-back creating the next iteration, notifications.
- Bridge: `wf_bridge.sync_change_request` (trigger on `wf.workflow_instance`) and `wf_bridge.v_items_to_apply`.
- **No apply function or service exists.** Nothing turns committed change items into bitemporal rows yet.
- Seed data: identifier schemes, property categories, 4 starter validation rules, group `POLICY_APPROVERS`.

**Layer rules verified:** no object in V1–V3 references `wf` or `wf_bridge`; the only write into `mdm` from
outside V1–V3 is `UPDATE mdm.change_request` in `wf_bridge.sync_change_request` (V5:60). V4 and V6 write only `wf.*`.

**Java service (`services/mdm-api`)**: Spring Boot 3.4.5, Java 21, virtual threads, `JdbcClient`.
Endpoints: `GET /api/v1/hierarchies`, `GET /api/v1/hierarchies/{code}`, `GET /api/v1/hierarchies/{code}/children`
(offset paging, `limit` 1–`mdm.api.max-page-size` (1000), default 200), `GET /api/v1/nodes/{nodeId}`.
Errors: `ProblemDetail` for 404 and 400 only. No write endpoints, no security, no OpenAPI.

**Tests:** pgTAP 35 (18 in `01_core_invariants.sql`, 17 in `02_workflow_invariants.sql`); JUnit
`HierarchyApiTest` 6. Baseline on 2026-11-11: db-test 35/35 pass; `mvn verify` 6/6 pass **only** with the
Testcontainers 1.21.4 pin (commit `0c192e7`); see D-01.

**Capabilities (`docs/capabilities.md`):** 91 — 77 undecided (`—`), 2 Retire (BLD-01, BLD-02), 1 Parity (GOV-01),
1 Improve (GOV-12), 10 New (NEW-01 to NEW-10).

## Differences found between code/schema and documents

> **Resolved in Phase 0 (2026-11-11):** D-01 (baseline and build state now current; Testcontainers pin restored),
> D-02 / D-03 (data model and README updated), D-24 (Maven wrapper committed), D-25 / D-26 (duplicates deleted, OD-24).
> The entries below are kept as found.

Controls (each needs a human decision before any guard changes; see OD-18):
- **D-04** `docs/data-model.md` says "restrict write access on `change_request` to the bridge role so the policy
  reference can't be forged". There are no roles, `GRANT`s or row-level security in V1–V6. Any session can set
  `decision_basis = 'approved_policy'` with an arbitrary `decision_policy_ref` on a low-risk request, using the system actor.
- **D-05** `mdm.change_request.requester_kind` is self-declared and never checked against `mdm.app_user.kind`
  (unlike `wf.instance_action.actor_kind`, which `wf.trg_action_guard` checks). Both "AI-originated requests always
  need a human" (`trg_cr_maker_checker`) and the AI check in `wf.evaluate_commit_policy` rely on this column.
- **D-06** `wf_bridge.sync_change_request` chooses the decider as the latest human commit **or reject** across all
  instances of the request. After a split where one branch commits and another is rejected, `decided_by` can be the
  rejecting user, and a policy-committed branch is recorded as `human_review`.
- **D-07** `mdm.change_item` has no guard or audit trigger and cascades on delete; items can be changed after
  submission or approval. `mdm.change_request` status transitions are unguarded (e.g. `applied` → `draft`).
- **D-12** `wf.instance_stage.claimed_by` has no guard: the human-only rule for claims applies only to the
  `instance_action` record, so a direct update can set an AI or non-member claimant that `wf.can_act` then honours.
- **D-13** `wf.close_instance` checks no authorisation for `rejected` or `withdrawn`; any human can reject any open
  instance, and any actor (including an AI agent) can withdraw one.
- **D-14** The daily auto-commit cap in `wf.evaluate_commit_policy` can be exceeded under concurrency:
  `wf.apply_commit_policy` locks only the instance, not the policy.
- **D-15** `wf.engage_kill_switch` checks membership `valid_to` but not `valid_from` (every other membership check
  tests both).
- **D-29** AUD-01 ("every change traceable to actor and request") is not enforced: `audit_log.actor_id` and
  `change_request_id` are NULL when the application does not `SET LOCAL` them, and fact rows accept a NULL `change_request_id`.
- **D-33** `wf.user_group_member` is neither historised nor audited, so approval and SoD group membership at the time of a decision cannot be reconstructed.

Model and behaviour:
- **D-08** Only fact tables are bitemporal. `node`, `hierarchy`, `property_definition`, `version`, `validation_rule`,
  `export_profile` are updated in place (the first four are audited). Regenerating an old version's export uses
  today's hierarchy, property and profile definitions (risk for VER-03 and EXP parity).
- **D-09** Depth limits are hard-coded and inconsistent: inheritance walk `dist < 100` in `property_value_asof`,
  `p_max_depth 25` in `effective_ownership`, none in `hierarchy_tree`.
- **D-10** `wf.worklist(user)` is unpaged, has no filters (GOV-13 needs Assigned, Urgent, Overdue, Claimed,
  Submitted, Drafted, Participated, Notified, All), has no urgent flag, and calls `wf.can_act` → `wf.items_in_scope`
  → `mdm.hierarchy_tree` per row (a full tree walk per scoped stage per row).
- **D-11** `wf.items_in_scope`, `wf.missing_required_properties` and `wf.item_condition_matches` evaluate against
  `current_date`/`now()`, not the request's version or business date.
- **D-16** Time zone is undefined: SQL defaults use `current_date`, `now()` and `date_trunc('day', now())`
  (session time zone); Java uses `LocalDate.now()` (JVM default zone).
- **D-32** `wf.event_outbox` has one `processed_at` column (single consumer), while `docs/data-model.md` and the V4
  header describe several consumers (engine, notifier, bridge).
- **D-36** HIE-02 includes "delete from the version"; `mdm.change_action` has no delete or merge action
  (HIE-07's `merge_node` is listed as "to add"; delete is not).
- **D-38** `mdm.hierarchy_tree.is_leaf` means "has no child rows at this slice"; it ignores `allows_children` and
  inactive children. Parity with DRM unknown (golden test needed).
- **D-39** `property_value_asof` executes admin-authored SQL (`EXECUTE format(...)`) for `sql`-engine derived
  properties; with no DB roles (D-04) this runs with the application's full privileges.
- **D-28** `mdm_stage` (V3) and `mdm.drm_property_map` are outside the `mdm`/`wf`/`wf_bridge` layer rule in `CLAUDE.md`.
- **D-30** `mdm.validation_result`, `mdm.export_run` and `mdm.drm_reconciliation` are neither append-only nor audited (AUD-03).
- **D-31** V1 header says "PostgreSQL 15+"; ADR-011 and `db/Dockerfile` use 16. Testcontainers uses `postgres:16-alpine` without pgTAP.

API and Java:
- **D-17** `GET /api/v1/hierarchies` is unpaged (CLAUDE.md: page every list endpoint); `findByCode` loads all
  hierarchies and filters in memory; children use offset paging, not keyset (UI_STANDARD §6 asks for keyset or virtual scroll).
- **D-18** Reads use only the current recorded time (no `recordedAsOf`), and `NodeDetail.properties` carry no
  provenance (stored / inherited / derived / default), which SLICE-01 S1-R3 and the UI_STANDARD property grid require.
  `property_value_asof` returns only the value.
- **D-19** `GET /api/v1/nodes/{id}?hierarchy=UNKNOWN` silently omits local properties instead of returning 404.
- **D-20** No authentication or authorisation in the API; actuator `metrics` is exposed without authentication.
- **D-21** Database guard violations (`RAISE EXCEPTION`, SQLSTATE `P0001`) and constraint violations surface as HTTP 500.
- **D-40** `NodeRepository` calls `property_value_asof` once per property definition per request (N calls, each with
  its own inheritance walk).

Tests:
- **D-22** No pgTAP coverage for `wf.sod_violation`, `wf.can_act`, `wf.items_in_scope`, `wf.split_instance`,
  `wf_bridge.sync_change_request`, `wf.apply_commit_policy` (shadow and active), freeze windows, daily caps,
  `wf.sample_auto_commits`, property inheritance, `hierarchy_tree` with shared nodes, or exports.

Repository and documents:
- **D-01** `docs/BUILD_STATE.md` says the baseline was never run and there is no commit. Actual: commits `7478a85`,
  `0c192e7`; db-test 35/35 and `mvn verify` 6/6 green on 2026-11-11. The working tree **removes** the Testcontainers
  pin from `pom.xml` (uncommitted), so `mvn verify` fails again with Docker Engine 29 (verified earlier the same day).
  Not corrected here: `BUILD_STATE.md` and `pom.xml` are outside this task's write scope.
- **D-02 / D-03** `docs/data-model.md` "Known gaps" and the `README.md` status still say the schema has never run.
- **D-24** Maven wrapper scripts are absent (only `.mvn/wrapper/maven-wrapper.properties`); a Phase 0 exit criterion.
- **D-25** `docs/capabilities.md` and `knowledge/capabilities.md` are byte-identical copies; `CLAUDE.md` points to `docs/`.
- **D-26** Two ADR-012 files: `ADR-012-ui-framework-angular-with-organisation-design-system.md` (Accepted, indexed)
  and `ADR-012-web-ui-stack.md` (an earlier Proposed draft, not indexed, says `apps/web/`; `CLAUDE.md` says `ui/`).
- **D-34** Phase table in `docs/BUILD_PROTOCOL.md` vs the catalogue: every Phase 1 capability is undecided (so the
  build protocol would build nothing for it); 14 capabilities are in no phase (BLD-03, GOV-08, GOV-10, GOV-11,
  GOV-14, GOV-15, GOV-16, ADM-01, ADM-02, ADM-03, NEW-01, NEW-07, NEW-08, NEW-10); 5 appear in two phases
  (HIE-01/02/06/12 via `HIE-*`, AUD-01 via `AUD-*`, SEC-05 via `SEC-*`, GOV-13, NEW-09). Proposed placement in `TRACEABILITY.md`.
- **D-37** Rules for Python: `docs/data-model.md` says CEL and Python derivations run in a "rules service";
  Accepted ADR-011 limits Python to AI services and analysis tooling.

Claims verified as true: `mdm` never references `wf`; only `wf_bridge` writes into `mdm`; bitemporal guard and
append-only triggers as listed; maker-checker and human-only decisions; policy hard limits, shadow mode default,
one-way kill switch, frozen approved policies and models; 35 pgTAP tests.

## Decisions blocking design (see OPEN_DECISIONS.md)
- **OD-09** remaining capability decisions. Phase 2 outlines GOV-04, GOV-07, GOV-08, GOV-09, GOV-11, GOV-16, AUD-02; Phase 3 needs few new decisions (HIE-12, GOV-13, SLICE-01 are decided).
- **OD-01c** Camunda 8 self-managed or SaaS: deployment only; the design is the same.
- **OD-02 to OD-04** design-system details: block visual sign-off of Phase 3 (the LLD designs against the Nexus token layer and CDK, with adapters).
- **OD-08, OD-17a, OD-18a** Audit-Risk and Security confirmations: block activation and merging, not design.
- **OD-28** external capability working copy.
- **OD-29a, OD-31a, OD-32a** confirmations by Audit-Risk and Security of the adopted load-run, masking and storage choices.
- **OD-34, OD-35** personal data in the ownership graph; UBO methodology per regime (Phase 6 build).
- **OD-07, OD-36, OD-37** AI decisions: no longer blocking while Phase 7 is deferred (OD-38).
- **OD-39, OD-40** DRM file access for reconciliation; who may accept a parity difference (Phase 8 build).
- **OD-06, OD-41, OD-42, OD-43** identity provider; recovery objectives and SLO; security tooling; penetration test (Phase 9 build).

## Wiring done (protocol step 5)
- `docs/BUILD_PROTOCOL.md` §1: the design (`docs/design/`, `docs/architecture/`, consistency review), `OPEN_DECISIONS.md`
  and `TRACEABILITY.md` added as sources of truth, with the rule: each phase plan follows its LLD; any deviation needs the LLD updated and an ADR first.
  Capability decisions in `OPEN_DECISIONS.md` apply where the catalogue still shows `—` (OD-28).
- §2: build order 0–6, 8, 9; Phase 7 deferred (OD-38); phase table rebuilt from `TRACEABILITY.md` (OD-14), with decided and pending capabilities per phase; infrastructure rule.
- §3: Orient reads the LLD, its consistency findings and open decisions, and checks for a shared environment (OD-44, CR-07); Plan starts from the LLD's §1, §13, §16.
- `CLAUDE.md` "Read first": `docs/architecture/`, the LLD, the consistency review and open decisions; the LLD rule; Phase 7 deferred.
- CLAUDE.md rule 3 extended for `mdm_stage` with the owner's explicit approval.

## Next action
None in the design track. The build continues in `docs/BUILD_STATE.md` (Phase 1).
