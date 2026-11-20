# AI-enabled MDM: data model (Oracle DRM replacement)

PostgreSQL 16. The files are Flyway migrations in `services/mdm-api/src/main/resources/db/migration`, applied automatically when the API starts, or by `scripts/db-test` for the pgTAP tests.

V1–V3 form the core model and work on their own. V4–V6 are the workflow layer, its bridge, and commit policies.
V7 sets the database roles and privileges; V8 adds entitlements and idempotency keys (Phase 1). V9 holds the Phase 2
workflow objects (configuration audit, governed membership, stage progression, worklist, outbox offsets, admin functions).
V10 holds the Phase 3 UI support: user preferences and the trigram search indexes. V11 adds versions (VER-01, VER-02):
the version lifecycle, its guard and transition log, and the freeze lock. V12 holds the sandbox overlay (Phase 5, NEW-08).

## What's in each file

| File | Contents |
|---|---|
| `V1__core_schema.sql` | Versions, change requests (maker-checker, AI as requester, guarded status transitions, frozen content after draft, row version for ETags, origin; Phase 5 sandboxes: `kind`, `sandbox_name`, `sandbox_base_recorded_at`, the kind guard `trg_cr_sandbox_kind` (`N2303`: origin `'sandbox'` only through a sandbox, kind moves once from sandbox to request while a draft) and the item limit at insert `change_item_sandbox_limit` (`N2302`)), nodes, identifiers, legal entity profile, hierarchies (shared nodes, cycle protection), properties (global/local, inheritance, derived, typed validation), validation rules, append-only audit log (since Phase 5, AUD-01: each row also records its subject, `hierarchy_id`, `node_id` and `property_id`, and its request from apply or from the row itself, with indexes for the transaction-history search); the write path: node allocation, withdraw, submit, decide, validate (trial apply), apply with its handlers, change events (outbox) and item clearance  ADR-046 (2026-11-20): `node_attr.display_name`, `hierarchy.description`, and the `add_node`, `update_node` and `add_hierarchy` handlers write them |
| `V2__ownership_ubo.sql` | Evidence documents, weighted ownership and control graph, UBO thresholds, deterministic effective-ownership calculation, UBO ownership and control prongs, starter validation rules |
| `V3__drm_export.sql` | Export profiles that reproduce DRM hierarchy and generation exports, as-of tree walk, property resolution with inheritance, export file generation with SHA-256, parallel-run reconciliation, DRM migration staging tables |
| `V4__workflow.sql` | DRG-equivalent workflow layer in schema `wf`: versioned workflow models, tasks, Submit/Enrich/Approve/Commit stages, approval groups and methods, node access scopes, separation of duties, conditional stages with request splitting, claims, SLAs, append-only request history, event outbox, user worklist |
| `V5__wf_mdm_bridge.sql` | The only code that writes from `wf` into `mdm`: keeps change request status in sync (including whether a decision was human or policy-based) and exposes the items cleared to apply |
| `V6__wf_commit_policy.sql` | Governed straight-through commit: approved commit policies, hard limits, protected properties, freeze windows, daily caps, kill switch, shadow mode with comparison views, and sampled post-commit review |
| `V7__roles_and_privileges.sql` | Database roles (ADR-014, ADR-019): `nexus_api` (drafts only), `nexus_apply` (the only writer of facts), `nexus_decider` (status and decision columns), `nexus_bridge`, `nexus_wf`, `nexus_readonly`; owner-run functions and who may call them |
| `V8__entitlements.sql` | Roles and bitemporal role grants scoped to all hierarchies, one hierarchy or a sub-tree (ADR-022), idempotency keys (ADR-015). (`system_setting` moved to V1 in Phase 2.) Since ADR-042 (Phase 5, 5-4a): the five roles `VIEWER`, `EDITOR`, `APPROVER`, `ADMIN`, `CONSUMER` with `holder_kind` (people, or service accounts for CONSUMER only, `N1032`); groups (`mdm.user_group`, `user_group_member`, in V1) gain a role and `mdm.user_group_scope`; `mdm.effective_grants` (direct grants plus group role × scope) and `mdm.holds_role` are what every entitlement check reads; `user_role.category_codes` (moved from V10) and `change_request_id` |
| `V9__workflow_phase2.sql` | Phase 2 workflow: `wf.config_audit`, governed membership changes (removed in Phase 5: groups moved to `mdm` and their changes are V14 change actions, ADR-042), stage progression (`advance_instance`, `complete_stage`), model loading and four-eyes activation, refusal reasons (`why_cannot_act`), worklist functions, commit-policy administration, outbox consumer offsets, and the owner-run grants for all of these |
| `V10__ui_support.sql` | Phase 3 UI support: `mdm.user_preference` (start page, last hierarchy, density; not governed; the API writes values of the caller's own row only, no delete, `wf` cannot write it), `pg_trgm` and trigram indexes on `node_attr.node_name` and `description` (and `display_name`, ADR-046) (current belief) for in-tree search; `mdm.user_role.category_codes` (NULL = every property category; ADR-036 property edit rights by category) |
| `V11__versions.sql` | Versions (VER-01, VER-02; ADR-037): version administrators are ADMINs since ADR-042 (`is_version_admin` reads `holds_role`; `VERSION_ADMIN` folded in); `mdm.version` gains created and submitted (by, at), `revision` (the ETag) and the CHECK `version_lifecycle_fields` (the pin, submit and finalize fields agree with the status); `mdm.version_transition` (append-only log written only by the guard); `trg_version_guard` (lifecycle, frozen fields, four eyes to finalize `N1029`, people only `N1030`, no delete, submit refused while requests are in flight `N2704`); `trg_cr_version_working` (a request is created in, moved to or advanced in a working version only, `N2703`, and an apply under a pin taken after its transaction began is refused with `40001` so it retries); the freeze lock (advisory key 11, 37: submit exclusive, apply shared); `create_version`, `update_version`, `transition_version`, `is_version_admin` (EXECUTE for `nexus_api`, no direct write on `mdm.version`); `user_preference.working_version_id`; column privilege `UPDATE (version_id)` on `change_request` (drafts only, through N2102); warning rule `NEXUS.VERSION_DATE` in `validate_change_request` |
| `V12__sandboxes.sql` | Sandbox overlay (NEW-08; ADR-028): `mdm.sandbox_delta_relationship`, `sandbox_delta_node_attr`, `sandbox_delta_value`, the rows applying (the node attribute rows carry `display_name`, ADR-046) a sandbox's items would close (`-`) and insert (`+`), each with its valid period. Derived, not governed: rebuilt by a rolled-back trial apply, removed with its sandbox, never read as a fact; only `nexus_apply` writes it, every role reads it; no `wf` reference. Functions (5-1b): the capture hook `apply_capture` (body replaces V1's no-op); `sandbox_trial` (invoker, run only by `nexus_apply`); `refresh_sandbox_delta`, `sandbox_conflicts` and `rebase_sandbox` (definer, owned by `nexus_apply`, called by the API); the reads `sandbox_children`, `sandbox_node`, `sandbox_placements` and `sandbox_node_properties` (invoker, `STABLE`) over the helpers `sandbox_children_of`, `sandbox_parent_of`, `sandbox_attr_of` and `sandbox_value_of`; `sandbox_require` and `sandbox_base`; setting `sandbox_incremental_threshold` (1000). Functions (5-2): `convert_sandbox` (refused with conflicts, `N2301`; turns the kind into `request` and clears the overlay) and `discard_sandbox` (withdraws, clears the overlay), both definer, owned by `nexus_apply`; setting `sandbox_max_active_per_user` (5). V9's worklist `drafted` view leaves sandboxes out |
| `V14__access_changes.sql` | Governed access changes (ADR-042 D3; Phase 5 5-4b): the eight change actions `create_group`, `update_group`, `add_group_scope`, `end_group_scope`, `add_group_member`, `remove_group_member`, `grant_role`, `revoke_role` (in V1's `change_action`; all eight in V6's hard-limit CHECK). `trg_change_item_access` (proposer is an ADMIN `N1033`; never for oneself `N1034`; no hierarchy or node on the item, never mixed with other actions, not in a sandbox `N2237`); `trg_cr_access_decision` (decider is an ADMIN `N1033`; never approves access for themselves `N1034`; a `POLICY_APPROVERS` change needs a member `N1020`; never governed by a workflow `N2237`); apply handlers `apply_create_group` and the rest (no back-dating `N2233`, nothing to end `N2231`, already a member or granted `N2232`), dispatched by `apply_item`; `nexus_apply` gains INSERT and UPDATE (`recorded_period`) on the three bitemporal tables and column rights on `user_group`. Replaces V9's `wf.membership_change` |
| `V15__workflow_override.sql` | Workflow override (ADR-042 D4; Phase 5 5-4c): `wf.override_stage` (definer, owned by `nexus_wf`, EXECUTE for `nexus_api`) writes one `stage_group_decision` per undecided group with `override = true` (new column) and one `instance_action` `override` (new `wf_action` value, V4) with the reason; refusals `N1031` (`wf.override_refused.*`: not an ADMIN over the request's hierarchies, reason under 10 characters, stage not open, own request, not a person, separation of duties). `trg_decision_guard` accepts an override row only while `override_stage` writes it; `wf.admin_covers_request` |
| `V16__hackathon_load.sql` | Hackathon CSV load (ADR-046; Phase 4 LLD §17), built in increments. H-2: `property_hierarchy` (the hierarchies a property applies to; none = every hierarchy; audited) and `property_definition.node_filter` (`any`, `leaf`, `limb`); `property_applies(property, node, hierarchy, date)`, the one definition of "applies", used by the guard `property_value_applies` (N2025, checked on a value's first day; re-stated history and explicit blanks pass) and by the node property grid |
| `V17__ledgers.sql` | Hackathon CSV load, H-3 (ADR-046 D4): `ledger` (id, name, currency, finance country, active; checks on id, currency and required fields; audited; `nexus_api` may insert and update, never delete). Each increment of the hackathon load has its own migration file, so a kept demo database only gains new files |
| `V13__queries_formulas_compares.sql` | Phase 5 §17 (QRY-01, PRP-06, VER-04, QRY-02; ADR-038, ADR-041). Built so far (5-9, 5-13a): `resolve_properties_batch` (set-based property resolution, equal to `node_properties_resolved` row for row); `saved_query` (a person's own object, audited, ETag by trigger, owner fixed); settings for the §17.15 limits. V13 also depends on edits made with it: `change_action` gains `set_property_derivation` (V1) and the commit-policy hard limit lists it (V6); `version.version_type` (V1) with its guard and a typed `create_version` (V11); the filter language in V3 (`filter_compile`, `filter_holds`, `filter_node_attrs`, `node_passes_filter` with groups, operators and attributes; `export_drm` refuses CEL-derived properties, N2805). Compares (5-12, built first by ADR-044): `compare_run` and `compare_row` (derived, expiring results; written by `nexus_api`), `compare_side` and `compare_fill` (structure, property and rename differences, set-based). Search indexes (5-14, ADR-045): full text on node names, display names (ADR-046) and descriptions, identifiers by lower-case value, request titles by trigram. Formula history and the formula apply handler are added here in 5-10 and 5-11 |

## Write path (Phase 1)

A change reaches the facts only through a change request, and only through owner-run functions:

| Step | Function (owner) | Rules |
|---|---|---|
| Draft | `INSERT` into `change_request` / `change_item` (`nexus_api`); `allocate_node` (`nexus_apply`) for new node identities | Items change only while the request is a draft; every change bumps `row_version` |
| Validate | `validate_change_request(cr, as_of)` (`nexus_apply`) | Trial apply plus active node and hierarchy rules, always rolled back; findings stored in `validation_result` (trial failures under the system rule `NEXUS.TRIAL_APPLY`) |
| Submit | `submit_change_request(cr, actor)` (`nexus_decider`) | Requester only, draft only, not empty; the API validates first in the same transaction |
| Decide | `decide_change_request(cr, decider, approve\|reject, note)` (`nexus_decider`) | Submitted only; basis always `human_review`; maker-checker trigger refuses self-decisions and non-humans |
| Apply | `apply_change_request(cr, actor)` (`nexus_apply`) | Approved only; all items or none; rule failures leave the request `apply_failed` with the reason; writes one `change_event` |
| Withdraw | `withdraw_change_request(cr, actor)` (`nexus_decider`) | Requester only, before a decision |

Apply never updates a fact: `apply_fact` closes the current row in recorded time and re-states the parts that stay true
before the effective date (and after an end date), then inserts the new row. Every row it writes carries the request id,
and the audit log carries the actor and the request. Each item stores in `payload.expected` what it assumed when it was
drafted; apply refuses an item whose base has changed since (`N3001`, stale base).

| Action | Effect from the effective date |
|---|---|
| `add_node` | New node's attributes and its primary placement |
| `insert_node` | Primary placement, or a shared one if the node already has a primary parent |
| `move_node` | Primary placement moves; descendants follow |
| `remove_node` | Leaves one hierarchy; with children only with `cascade` (removes the primary sub-tree) |
| `delete_node` | Ends attributes, stored values and placements everywhere; refused for a top node, a node with children, a referenced node or one with changes scheduled later |
| `update_node` | Name and/or description |
| `add_hierarchy` | New hierarchy and its top node |
| `set_property` / `clear_property` | Stored value from the date (optionally until `validTo`; JSON null is an explicit blank) / value ends, so inheritance or the default applies again |

Item limits by origin (`system_setting`): `max_items_per_change_request` 5 000, `sandbox_max_items` 20 000 (`N2103`).

### Error codes added in Phase 1

| Code | Guard | HINT |
|---|---|---|
| `N1025` | someone other than the requester withdraws or submits | `change_request.not_requester` |
| `N2004` | parent is a leaf (apply) | `hierarchy.parent_is_leaf` |
| `N2005` | remove or delete a node that has children | `hierarchy.remove_with_children` |
| `N2006` | delete a node still referenced by a `node_ref` value | `node.referenced` |
| `N2103` | more items than the limit for the request's origin | `change_request.too_many_items` |
| `N2104` | withdraw, submit or decide in core mode a request governed by a workflow | `change_request.governed` |
| `N2105` | item cannot be applied as written (parent not in the hierarchy, node missing, change scheduled later); action has no handler yet | `apply.item_invalid`, `apply.action_not_available` |
| `N2106` | submit an empty request | `change_request.empty` |
| `N3001` | stale base: the fact changed since the item was drafted (expected and actual in `DETAIL`) | `apply.stale_base` |
| `22023` | decision other than approve or reject | `decision.invalid` |

API-only rule codes (422): `change_item.action_not_available`, `change_item.not_in_hierarchy`, `change_item.parent_is_leaf`,
`change_item.already_under_target`, `change_item.node_not_found`, `change_request.not_draft`, `change_request.validation_failed`,
`hierarchy.code_exists`, `property.derived`.

## Workflow layer: how the separation works

- `mdm` never references `wf`. The core model runs without workflow (with its built-in maker-checker as the minimum control).
- `wf` reads from `mdm` but never writes to it.
- `wf_bridge` is the single integration point. Drop or replace it to swap in a different workflow product.
- The database enforces the rules that must never be bypassed: who may act, separation of duties across stages, human-only decisions, append-only history, frozen model versions. An orchestration engine (Temporal or Camunda, for example) handles timers, escalations, notifications and stage advancement, driven by `wf.event_outbox`.

| DRG | Workflow layer |
|---|---|
| Workflow model, model filters | `workflow_model` (versioned; in-flight requests stay on their version), `model_scope` |
| Workflow task | `workflow_task`, `task_property` (editable/required), `task_validation` |
| Submit / Enrich / Approve / Commit | `workflow_stage.stage_type` |
| Approval groups, workflow method | `user_group`, `stage_group`, `approval_method` (any, all, sequential) |
| Node access | `stage_access_scope` + `items_in_scope()` |
| Separation of duties | `workflow_stage.separation_of_duties` + `sod_violation()`, which also covers split parents |
| Push-back and re-approval | `reapproval` + `instance_stage.iteration` |
| Conditional stages, split requests | `workflow_stage.condition` + `split_instance()` |
| Claim / unclaim | `instance_stage.claimed_by`, `claim_expires_at` |
| Request and stage durations | `request_duration`, `stage_duration`, `v_sla_status` |
| Notifications | `workflow_stage.notify` + `event_outbox` |
| Request history | `instance_action` |

AI agents can submit requests, add suggestions and pre-fill enrichment (recorded with model and confidence), but claim, approve, reject, push back and commit are human-only, enforced by trigger.

### Workflow in Phase 2 (how it runs)

| Step | Who | Function |
|---|---|---|
| Submit with a model | requester (API) | `mdm.submit_change_request`, then `wf.start_instance` in the same transaction; the bridge marks the request governed and in review |
| Move between stages | workflow worker (engine) | `wf.advance_instance`, `wf.complete_stage`; the engine (Camunda or the in-process driver, ADR-035) only drives order |
| Decide, claim, enrich | people (API) | `wf.record_stage_decision`, `wf.claim_stage` / `unclaim_stage`, `wf_bridge.add_enrichment_item`; refusals explained by `wf.why_cannot_act` |
| Policy before Commit | worker | `mdm.validate_change_request`, then `wf.apply_commit_policy` (policy row locked; shadow mode records only) |
| Close and apply | worker | `wf.close_instance` (commit action recorded first), the bridge records the decider (D-06) and clears the committed items, then Phase 1 `mdm.apply_change_request` |
| Worklist | people (API) | `wf.worklist_page` / `worklist_counts`: nine views filtered by `wf.can_act` |
| Configuration | workflow and policy administrators | `wf.load_model` / `activate_model` (second administrator), `wf.propose_commit_policy` and the V6 lifecycle, `wf.propose_membership_change` / `decide_membership_change` (second administrator) |

Group membership (`wf.user_group_member`) is bitemporal by business date and checked by `wf.is_member` everywhere;
changes to it, to models and to policies are logged in the append-only `wf.config_audit`. The relay reads
`wf.event_outbox` after its offset in `wf.outbox_consumer`. Business-day boundaries everywhere use
`mdm.business_today()` / `business_day_start()` (ADR-018).

### Error codes added in Phase 2

| Code | Guard | HINT |
|---|---|---|
| `N1010` | claim by someone who cannot act on the stage; unclaim by someone else | `wf.claim_not_allowed` |
| `N1011`, `N1012` | close as rejected without being the rejecter; withdraw by someone other than the requester or submitter | `wf.reject_not_allowed`, `wf.withdraw_not_allowed` |
| `N1013` | enrichment item the stage's task does not allow | `wf.item_not_editable` |
| `N1014` | model activated by its creator or without an activator | `wf.model_self_activation` |
| `N1026`, `N1027` | not a workflow administrator; not a policy administrator | `wf.not_workflow_admin`, `policy.not_policy_admin` |
| `N2107` | core-mode decision on a hierarchy that requires a workflow | `change_request.workflow_required` |
| `N2201`, `N2202` | conflicting decision on a stage; conditional split (GOV-04 not enabled) | `wf.conflicting_decision`, `wf.split_not_enabled` |
| `N2225` | active policy approved before Audit-Risk sign-off (OD-08) | `policy.activation_not_allowed` |
| `N2230`–`N2233` | membership change not pending; nothing to end; already a member; back-dated | `wf.membership_*` |
| `N2234`, `N2235`, `N2236` | stage not approved; unknown group; request chose another model | `wf.stage_not_approved`, `wf.unknown_group`, `wf.model_mismatch` |

Refusal reasons (`wf.why_cannot_act`, 403 `code`): `human_only`, `wf.instance_not_open`, `wf.stage_not_open`,
`wf.claimed_by_other`, `maker_checker.own_request`, `sod.violation`, `wf.out_of_scope`, `wf.not_group_member`.

### Error codes added in Phase 5 (users, roles and groups, ADR-042)

| Code | Guard | HINT |
|---|---|---|
| `N1031` | workflow override refused: not an ADMIN over the request's hierarchies; reason under 10 characters; stage not open; own request; not a person; separation of duties; an override row not written by `wf.override_stage` (V15) | `wf.override_refused.not_admin`, `.reason_required`, `.stage_closed`, `.own_request`, `.not_human`, `.separation_of_duties`, `.not_through_override` |
| `N1032` | role holder kind: a person given CONSUMER, a service account given any other role, directly or through a group (V8) | `roles.holder_kind` |
| `N1033` | access change proposed or decided by someone who is not an ADMIN (V14) | `access.not_admin` |
| `N1034` | access change for oneself: proposing, or approving, a membership or a role for oneself (V14) | `access.self_grant` |
| `N1005` | also: a service account raising a change request (V1) | `requester.service` |
| `N2231`–`N2233` | reused by the access actions (V14): nothing to end; already a member or granted; back-dated | `access.nothing_to_end`, `access.already_member` / `access.already_granted`, `access.backdated` |
| `N2237` | access request shape: mixed with other actions; in a sandbox; a hierarchy or node on the item; governed by a workflow (V14) | `access.mixed_request`, `access.not_in_sandbox`, `access.item_shape`, `access.core_only` |

`N2230` (membership change not pending) is retired with V9's `wf.membership_change`.

## Straight-through commit (06)

Maker-checker moves from each request to the policy: humans approve a narrow rule set, and the system commits a request only when every check passes, recording which policy allowed it.

- **Who approves a policy:** a human in `POLICY_APPROVERS` who did not propose it. Content is frozen once submitted; approved policies are immutable (change = new version). Policies lapse if not re-certified by `review_due`.
- **Never eligible, whatever the policy says:** moves, removals, inactivations, ownership changes, protected properties, non-low risk tiers, requests an AI originated or contributed to, requests with blocking validation errors or open enrich/approve stages, anything during a freeze window, or beyond the daily cap.
- **Kill switch:** any owner-group member or approver can stop a policy instantly. It can only be cleared by approving a new version.
- **Shadow mode (default for new policies):** the policy is evaluated and recorded, but humans still decide. `v_shadow_summary` shows how often the policy would have committed something a human rejected or pushed back (`too_loose_pct`). That's the evidence for Audit before switching to active.
- **Detective control:** `sample_auto_commits()` draws a daily random sample of auto-commits for human review; `v_commit_policy_daily` tracks volumes, issues and outstanding reviews.
- **Core safety net:** `mdm.change_request` records `decision_basis` (`human_review` or `approved_policy`) and the policy reference. The core trigger accepts a non-human decider only for low-risk, non-AI approvals with a policy reference. Since V7 only the bridge role may write `decision_policy_ref`, and the API's own decision function always records `human_review`, so the policy reference can't be forged (D-04).

Engine flow for a covered model: submit → run full validation → `wf.apply_commit_policy(instance, validation_start_time, system_actor)` → either committed, or left with the human Commit stage.

## DRM concept mapping

| DRM | New model |
|---|---|
| Version | `version` (business date plus recorded-time slice) |
| Hierarchy / top node / group | `hierarchy` |
| Node, name, description, inactive | `node` + `node_attr` (bitemporal, so renames are tracked). `node_name` is the business key (a code in the hackathon data set); `display_name` is the name people read, not unique, NULL = show `node_name` (ADR-046 D1; written by `add_node`, `update_node` and `add_hierarchy`) |
| Leaf / limb | `node_attr.allows_children`; `is_leaf` derived per hierarchy |
| Property applies to some hierarchies, or to leaves or limbs only | `property_hierarchy`, `property_definition.node_filter`; enforced by N2025 (ADR-046 D2) |
| Parent-child, sort order | `hierarchy_relationship` |
| Shared node | `hierarchy_relationship.is_primary = false` |
| Global / local property | `property_definition.scope` |
| Inheritance and overrides | `inheritance` + `property_value_asof()`; a JSON null value blocks inheritance |
| Derived property | `derivation_expr` (original formula kept in `drm_formula_orig`) |
| Validation | `validation_rule` (original kept in `drm_validation_orig`) |
| Query / node filter | `export_profile.node_filter` (declarative JSON) |
| Hierarchy and generation exports | `export_profile` + `export_profile_column` + `export_drm()` |
| DRG request | `change_request` + `change_item` |
| Transaction log | `audit_log`; read by `GET /audit` (AUD-01) and `GET /change-requests/{id}/history` (AUD-02), Phase 5 LLD §18 |

## Key design decisions

1. **Bitemporal everywhere.** Every fact records both when it was true and when the system knew it. Rows are never updated or deleted; corrections close `recorded_period` and insert a new row. This answers "what did we know on the onboarding date?" and lets any old DRM version be regenerated.
2. **Ownership is separate from hierarchies.** Hierarchies are curated reporting trees. Ownership is a weighted many-to-many graph built from evidence. They share the same `node` identity.
3. **AI proposes, humans approve, code calculates.** AI agents are `app_user` rows of kind `ai_agent`. They can only raise change requests, which must include a rationale, model and confidence score. Only humans can approve, and never their own requests. AI-extracted ownership edges must cite an evidence document. All percentage math is deterministic SQL.
4. **Byte-for-byte export parity.** Delimiter, quoting, booleans, null token, line endings, encoding and column order are all configurable per profile. `run_export()` hashes the output, and `drm_reconciliation.is_exact_match` compares it with the DRM file during the parallel run.

## Example usage

```sql
-- Generate a DRM-compatible export as of a version
SELECT line FROM mdm.export_drm('LE_CONSOL_HIER', 'FY26_Oct') ORDER BY line_no;

-- Record a run (with hash) for reconciliation
SELECT mdm.run_export('LE_CONSOL_HIER', 'FY26_Oct');

-- Beneficial owners of an entity at a 10% threshold
SELECT * FROM mdm.ubo_ownership_prong('<entity uuid>', 10);
SELECT * FROM mdm.ubo_control_prong('<entity uuid>');
```

`apply_change_request` sets the actor and the request for the transaction, so the audit log captures who did what.
Anything written outside it (for example by the owner role in tests) is audited with a NULL actor.

## Known gaps and next steps

- **Runs on PostgreSQL 16** (verified 2026-11-15, Phase 5 increments 5-9 and 5-13a): `scripts/db-test` applies V1–V13 to a fresh database and the
  570 pgTAP tests in `db/tests` pass. Phase 1 closed D-04, D-05, D-07 and D-29; Phase 2 closed D-06, D-10 to D-15, D-32 and D-33; the remaining
  gaps (D-22 and later-phase items) are listed in `docs/design/DESIGN_STATE.md` (OD-18).
- Bulk inserts of many placements into a large hierarchy with stale statistics are slow (the cycle-check plan); loads
  must refresh statistics between batches (Phase 4).
- Compare, difference, transaction-log and version exports belong in the export service; only hierarchy and generation exports are in SQL.
- Derived properties are evaluated in SQL only for the `sql` engine. CEL and Python run in the rules service.
- Cross-holdings (cycles) are flagged and excluded from totals. Exact treatment needs a matrix solve in the ownership service.
- Exports call functions row by row, which is fine for tens of thousands of nodes. For very large hierarchies, move generation into a set-based query or the export service.
- `ubo_threshold` is intentionally empty. Compliance should load and sign off the values.
- Workflow: stage advancement, push-back (creating the next iteration) and notification templates live in the orchestration engine; only the atomic operations and guards are in SQL.
- Next build step: a loader from `mdm_stage.*` into the core tables, plus the AI inventory job that proposes `drm_property_map` rows and translates DRM formulas and validations.
