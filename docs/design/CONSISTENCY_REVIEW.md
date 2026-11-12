# Cross-phase consistency review

- **Date:** 2026-11-11 · **Status:** Done; fixes applied; awaiting review
- **Scope (DESIGN_PROTOCOL §4 step 4):** interfaces match across phases; no contradictions between the LLDs, ADRs,
  `CLAUDE.md` and the data model; every pattern lists where it is applied; every capability is traced.
- **Inputs:** Phase 1–9 LLDs, ADR-001 to ADR-034, `docs/architecture/overview.md` and `patterns.md`, `TRACEABILITY.md`,
  `OPEN_DECISIONS.md`, `CLAUDE.md`, `docs/data-model.md`, migrations V1–V6.

## 1. How it was checked
- Searched all LLDs for every error code, migration file, setting, limit and new change action and compared them across phases.
- Followed each cross-phase call (e.g. Phase 2 worker → Phase 1 `validate_change_request`; Phase 5 sandbox → Phase 1 apply;
  Phase 4 load runs → Phase 2 `requires_workflow`; Phase 3 UI → Phase 1/2 endpoints) to its definition.
- Re-read each ADR's decision against the LLD that implements it.
- Regenerated `TRACEABILITY.md` and counted rows (91 capabilities, each once; 0 rows pointing at an unwritten LLD).

## 2. Findings and fixes

| ID | Finding | Fix | Where |
|---|---|---|---|
| CR-01 | The business time zone had three sources: a Java property (Phase 1), a database setting (Phase 2), a per-schedule default (Phase 8) | One source: `mdm.system_setting('business_time_zone')`; Java reads it and fails on disagreement; schedules default to it (`time_zone` NULL) | Phase 1 A-8, §3.6; Phase 8 §4.2 |
| CR-02 | Error codes: Phase 7 `N1302` duplicated `N1002`; Phase 8 used class `N2` (422) for a maker-checker refusal; Phase 1's error table omitted `N2004`–`N2006`, `N2103` | Reuse `N1002`; renumber to `N1021`; table completed. Registry in §3 | Phase 1 §5.3; Phase 7 §5; Phase 8 §5, §13 |
| CR-03 | Phase 8 event feed used `after` / `nextAfter` instead of the ADR-015 cursor envelope | `cursor` / `nextCursor` | Phase 8 §5 |
| CR-04 | Sandboxes allow 20 000 items (Phase 5) but apply refused more than 5 000 (Phase 1) | `mdm.change_request.origin` (`user`, `sandbox`, `load`, `ai`), set at creation; apply's limit depends on origin | Phase 1 §4.2, §7.1; Phase 5 §4 |
| CR-05 | Phase 4 load runs decide requests in core mode, which Phase 2 refuses for hierarchies with `requires_workflow` | Loads run before the flag is set; refused if any target has it; after cutover, loads into governed hierarchies use a `LOAD_RUN` workflow model | Phase 4 §4.3 |
| CR-06 | Deferred Phase 7 reserved `V14`; built later, after V15/V16 are applied, Flyway would reject it as out of order | Phase 7's migration number is assigned at build time (next free number) | Phase 7 §4 |
| CR-07 | Phases 2–8 say "edit V1–V6", which CLAUDE.md rule 6 allows only before a shared environment exists; the Phase 4 performance environment may be one | Rule added to every LLD header; definition of "shared" is OD-44 | All LLD headers |
| CR-08 | `link_identity` (Phase 9) was not on the commit-policy hard-limit list, unlike every other governance action | Added | Phase 9 §3.1 |
| CR-09 | Maker-checker on identity links and grants needs two admins before anyone can be linked (bootstrap) | Each environment's provisioning migration creates its first two `SYSTEM_ADMIN`s and links from platform-supplied values, never from git | Phase 9 §3.1 |
| CR-10 | Role grants are maker-checked (ADR-029) but `wf.user_group_member`, which decides approvers and `POLICY_APPROVERS`, was only audited | Governed membership changes: proposed and approved by different `WORKFLOW_ADMIN`s; `POLICY_APPROVERS` changes approved by a member | Phase 2 §4.2 |
| CR-11 | Roles added in Phases 6 and 8 had no permissions in the Phase 1 `Permission` model | Permission list extended; full role catalogue in §4 | Phase 1 §3.1 |
| CR-12 | Overview still showed the AI service as planned, the worker as "OD-01", tracing as proposed and the IdP without ADR-033 | Updated | Overview §3, §6, §18 |
| CR-13 | Pattern entries listed planned locations unevenly | Index of design sections per pattern appended | `patterns.md` |

## 3. Error-code registry (ADR-020)
| Class | Codes |
|---|---|
| `N1` control (403) | `N1001` self-approval · `N1002` non-human decider · `N1003` AI request needs a human · `N1004` policy basis outside the bridge · `N1005` requester kind mismatch · `N1010` claim not allowed · `N1011` reject without a rejecting decision · `N1012` withdraw not allowed · `N1013` item not editable in this stage · `N1014` model activated by its creator · `N1021` reconciliation accepted by its explainer · `N1301` model version not approved · `N1303` prompter decides own AI request · `N1028`–`N1030` version administrator, self-finalize, person only (V11, designed) |
| `N2` integrity (422) | `N2001` cycle · `N2002` top node · `N2003` shared not allowed · `N2004` parent is a leaf · `N2005` remove with children · `N2006` delete of a referenced node · `N2010` bitemporal edit · `N2020` property type/scope · `N2101` status transition · `N2102` request not draft · `N2103` too many items · `N2201` conflicting decision · `N2202` split not enabled · `N2301` sandbox conflicts · `N2302` sandbox too large · `N2303` sandbox not draft · `N2401` edge without evidence or rationale · `N2402` ownership component too large · `N2403` closed ownership loop · `N2404` threshold missing · `N2501` invalid AI output · `N2502` plan outside whitelist · `N2601` profile version not approved · `N2602` DRM file missing · `N2701`–`N2706` version lifecycle (V11, designed) |
| `N3` conflict (409) | `N3001` stale base |
| reserved | `N9999` trial rollback |

**Codes for the existing V1–V6 guards** (added 2026-11-11 while building Phase 1 increment 1-1; messages unchanged):
| Code | Guard (migration) | HINT |
|---|---|---|
| `N1001` | requester decides own request (V1); proposer approves own policy (V6) | `maker_checker.self_decision` |
| `N1002` | non-human decides a request (V1); human-only workflow action (V4, V6); non-human approves a policy (V6); non-human post-commit reviewer (V6) | `human_only` |
| `N1003` | AI-originated request approved by policy (V1) | `ai_requires_human` |
| `N1004` | policy-based approval not recorded by the system actor (V1) | `policy.system_actor_required` |
| `N1006` | decision without a decider (V1) | `maker_checker.decider_required` |
| `N1007` | policy-based rejection (V1) | `policy.approvals_only` |
| `N1008` | policy-based approval of a non-low-risk request (V1) | `policy.low_risk_only` |
| `N1009` | role granted to a non-human user (V8) | `roles.human_only` |
| `N1005` | requester kind does not match the user record (V1, Phase 1) | `requester_kind_mismatch` |
| `N2101`, `N2102` | invalid request status transition; request (or its items) no longer a draft (V1, Phase 1) | `change_request.status_transition`, `change_request.not_draft` |
| `N1025` | withdraw or submit by someone other than the requester (V1, Phase 1) | `change_request.not_requester` |
| `N2004`–`N2006` | parent is a leaf; remove/delete with children; delete of a referenced node (V1 apply, Phase 1) | `hierarchy.parent_is_leaf`, `hierarchy.remove_with_children`, `node.referenced` |
| `N2103` | too many items for the request's origin (V1 apply, Phase 1, CR-04) | `change_request.too_many_items` |
| `N2104`, `N2106` | core-mode action on a workflow-governed request; empty request submitted (V1, Phase 1) | `change_request.governed`, `change_request.empty` |
| `N2105` | item cannot be applied as written, or its action has no handler yet (V1 apply, Phase 1) | `apply.item_invalid`, `apply.action_not_available` |
| `N3001` | stale base; expected and actual in `DETAIL` (V1 apply, Phase 1) | `apply.stale_base` |
| `N1010`–`N1014` | claim not allowed; reject not by the rejecter; withdraw not allowed; item not editable in this stage; model self-activation (V4, Phase 2) | `wf.claim_not_allowed`, `wf.reject_not_allowed`, `wf.withdraw_not_allowed`, `wf.item_not_editable`, `wf.model_self_activation` |
| `N1026`, `N1027` | not a workflow administrator; not a policy administrator (V9, Phase 2) | `wf.not_workflow_admin`, `policy.not_policy_admin` |
| `N2107` | core-mode decision on a `requires_workflow` hierarchy (V1, Phase 2) | `change_request.workflow_required` |
| `N2201`, `N2202` | conflicting decision; conditional split not enabled (V4/V9, Phase 2) | `wf.conflicting_decision`, `wf.split_not_enabled` |
| `N2225` | active policy before Audit-Risk sign-off (V6, Phase 2, OD-08) | `policy.activation_not_allowed` |
| `N2230`–`N2236` | membership change not pending / nothing to end / already a member / back-dated; stage not approved; unknown group; model mismatch (V9, V4, Phase 2) | `wf.membership_not_pending`, `wf.membership_missing`, `wf.membership_exists`, `wf.membership_backdated`, `wf.stage_not_approved`, `wf.unknown_group`, `wf.model_mismatch` |
| `N1015` | decider not a member of the deciding group (V4) | `wf.not_group_member` |
| `N1016` | user cannot act on the stage (V4) | `wf.cannot_act` |
| `N1017` | actor kind does not match the user record (V4, V6) | `wf.actor_kind_mismatch` |
| `N1018` | AI action without model and confidence (V4, V6) | `ai.model_required` |
| `N1019` | clearing a kill switch (V6) | `policy.kill_switch_one_way` |
| `N1020` | policy approver not in `POLICY_APPROVERS` (V6) | `policy.not_approver` |
| `N1022` | policy submitted by someone other than its proposer (V6) | `policy.not_proposer` |
| `N1023` | kill switch engaged by a user not allowed to (V6) | `policy.kill_switch_not_allowed` |
| `N1024` | policy commit recorded by a non-system actor (V6) | `policy.system_actor_required` |
| `N2001`–`N2003` | cycle; top node; shared nodes not allowed (V1) | `hierarchy.cycle`, `hierarchy.top_node`, `hierarchy.shared_not_allowed` |
| `N2010` | bitemporal edit or delete (V1) | `bitemporal.immutable` |
| `N2011` | append-only table changed (V1, used by V4/V6 triggers) | `append_only` |
| `N2020` | property scope (global with hierarchy / local without) (V1) | `property.scope` |
| `N2021` | derived property stored (V1) | `property.derived` |
| `N2022` | value of the wrong type or too long (V1) | `property.type` |
| `N2023` | value not in the property's list (V1) | `property.list_value` |
| `N2024` | reference to an unknown node (V1) | `property.node_ref` |
| `N2205`–`N2207` | model frozen; model cannot be activated; invalid model status change (V4) | `wf.model_frozen`, `wf.model_invalid`, `wf.model_status` |
| `N2208`, `N2209` | unknown property / unsupported type in a stage condition (V4) | `wf.condition_property`, `wf.condition_type` |
| `N2210`–`N2215` | no active model; stage not splitting; bad outcome; commit stage not approved; stages incomplete; instance not open (V4) | `wf.no_active_model`, `wf.not_splitting`, `wf.bad_outcome`, `wf.commit_not_approved`, `wf.stages_incomplete`, `wf.instance_not_open` |
| `N2216`–`N2224` | policy: only drafts deleted; must be submitted first; frozen while pending; overlapping scope; invalid status change; immutable once approved; scope frozen; not pending approval; completed review frozen (V6) | `policy.*` |
| `N2604`–`N2609` | export: unsupported filter op; unknown filter property; unsupported column source; unknown or inactive profile; type not produced in SQL; unknown version (V3) | `export.*` |
| `N1028`–`N1030` | not a version administrator; a version finalized by the person who submitted it; a version transition without an identified person (V11, Phase 3 third extension, designed) | `version.not_admin`, `version.self_finalize`, `version.actor_not_human` |
| `N2701`–`N2706` | version: invalid status change; field frozen in this status; the request's version is not working; requests still in flight at submit; delete refused; a new version not starting as working (V11, designed) | `version.status_transition`, `version.frozen`, `version.not_working`, `version.requests_open`, `version.no_delete`, `version.must_start_working` |
Codes are kept in `docs/data-model.md` when each phase is built (BUILD_PROTOCOL step 6).

## 4. Role catalogue (CR-11)
| Role | Phase | Permissions |
|---|---|---|
| `VIEWER` | 1 | READ |
| `STEWARD` | 1 | READ, PROPOSE |
| `APPROVER` | 1 | READ, DECIDE (core mode); eligible for workflow groups |
| `WORKFLOW_ADMIN` | 1 (used 2) | READ, ADMIN_WORKFLOW (models, governed membership) |
| `POLICY_ADMIN` | 1 (used 2) | READ, ADMIN_POLICY (propose policies) |
| `SYSTEM_ADMIN` | 1 | READ, ADMIN_SYSTEM (grants, identity links: always maker-checked) |
| `VERSION_ADMIN` | 3 (third extension, ADR-037, designed) | READ, ADMIN_VERSION (create, copy, rename, submit, reopen, expire; finalize only a version someone else submitted) |
| `OWNERSHIP_ANALYST` | 6 | READ_OWNERSHIP, PROPOSE_OWNERSHIP, upload evidence |
| `COMPLIANCE_OFFICER` | 6 | READ_OWNERSHIP, DECIDE_OWNERSHIP, thresholds, determinations |
| `EXPORT_ADMIN` | 8 | ADMIN_EXPORT (profile versions; maker-checked) |
| `EXPORT_RUNNER` | 8 | RUN_EXPORT |
| `RECON_REVIEWER` | 8 | REVIEW_RECON (acceptance by a second reviewer) |
| `INTEGRATION_READER` | 8 | READ_EVENTS, READ (scoped) — for integration identities only |
Workflow groups (`wf.user_group`, including `POLICY_APPROVERS`) are a separate, governed membership model (CR-10).

## 5. Verified consistent (no change needed)
- **Layer rule:** no design adds an `mdm` → `wf` reference; `mdm.change_item_clearance` and enrichment items are written only by `wf_bridge`; `wf` audits itself in `wf.config_audit`; `mdm_stage` is written only by `nexus_loader`.
- **Migration numbers** V7–V16 are unique and ordered by phase (V14 now assigned at build time, CR-06).
- **Function contracts across phases:** `apply_change_request(cr, actor)` (Phases 1, 2, 4, 5); `validate_change_request(cr, as_of)` with `in_review` allowed (Phases 1, 2); trial mode used by validation (1) and sandboxes (5); `mdm.business_today()` (2) used by `wf` defaults.
- **Hard-limit list** (never auto-committed): moves, removals, inactivations, ownership actions (V6) + `delete_node` (1), `add_hierarchy`, `update_node` (4), `grant_role`, `revoke_role` (5), `set_ubo_threshold`, `end_ubo_threshold` (6), `link_identity` (9, CR-08).
- **Deterministic calculations:** ownership totals (6), exports (8) and inheritance (1) are SQL/Java; AI (7) produces proposals and query plans only.
- **Phase 7 deferral:** no other phase calls an AI component; Home's AI cards are hidden (3).
- **ADRs vs LLDs:** ADR-013 to ADR-034 each implemented by the LLD named in it; ADR-014 amended by ADR-019 and extended by ADR-026 (`nexus_loader`); ADR-021 amended by ADR-023 (enrichment) — all recorded.
- **Traceability:** 91 capabilities, each exactly once; 2 retired; 69 pending decision (outlined in their phase LLD); 4 designed with build deferred (NEW-03–06); 0 rows without a written LLD section.

## 6. Left for later steps (not design contradictions)
| Item | Owner | When |
|---|---|---|
| `docs/data-model.md` does not yet describe Phase 1–9 objects (by design: updated per phase at build, BUILD_PROTOCOL step 6) | Build | Each phase's step 6 |
| `CLAUDE.md` rule 3 names `mdm`, `wf`, `wf_bridge` but not `mdm_stage` (D-28); proposed wording for step 5: "`mdm_stage` is written only by the loader role; it may read `mdm`" | Design step 5 (with your approval) | Next |
| `BUILD_PROTOCOL.md` phase table: OD-14 placements, SEC-01/02 in Phase 1, Phase 7 deferred (OD-38) | Design step 5 | Next |
| OD-44: what counts as a "shared environment" for CLAUDE.md rule 6 | You | Before the Phase 4 build |
| Confirmations by Security, Audit-Risk, Compliance, Privacy, Platform (OD-17a, OD-18a, OD-29a, OD-31a, OD-32a, OD-34, OD-35, OD-39, OD-40, OD-41–43) | Those teams | Before the builds that need them |
