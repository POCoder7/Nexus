# AI-enabled MDM: data model (Oracle DRM replacement)

PostgreSQL 16. The files are Flyway migrations in `services/mdm-api/src/main/resources/db/migration`, applied automatically when the API starts, or by `scripts/db-test` for the pgTAP tests.

V1–V3 form the core model and work on their own. V4–V6 are the workflow layer, its bridge, and commit policies.

## What's in each file

| File | Contents |
|---|---|
| `V1__core_schema.sql` | Versions, change requests (maker-checker, AI as requester), nodes, identifiers, legal entity profile, hierarchies (shared nodes, cycle protection), properties (global/local, inheritance, derived, typed validation), validation rules, append-only audit log |
| `V2__ownership_ubo.sql` | Evidence documents, weighted ownership and control graph, UBO thresholds, deterministic effective-ownership calculation, UBO ownership and control prongs, starter validation rules |
| `V3__drm_export.sql` | Export profiles that reproduce DRM hierarchy and generation exports, as-of tree walk, property resolution with inheritance, export file generation with SHA-256, parallel-run reconciliation, DRM migration staging tables |
| `V4__workflow.sql` | DRG-equivalent workflow layer in schema `wf`: versioned workflow models, tasks, Submit/Enrich/Approve/Commit stages, approval groups and methods, node access scopes, separation of duties, conditional stages with request splitting, claims, SLAs, append-only request history, event outbox, user worklist |
| `V5__wf_mdm_bridge.sql` | The only code that writes from `wf` into `mdm`: keeps change request status in sync (including whether a decision was human or policy-based) and exposes the items cleared to apply |
| `V6__wf_commit_policy.sql` | Governed straight-through commit: approved commit policies, hard limits, protected properties, freeze windows, daily caps, kill switch, shadow mode with comparison views, and sampled post-commit review |

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

## Straight-through commit (06)

Maker-checker moves from each request to the policy: humans approve a narrow rule set, and the system commits a request only when every check passes, recording which policy allowed it.

- **Who approves a policy:** a human in `POLICY_APPROVERS` who did not propose it. Content is frozen once submitted; approved policies are immutable (change = new version). Policies lapse if not re-certified by `review_due`.
- **Never eligible, whatever the policy says:** moves, removals, inactivations, ownership changes, protected properties, non-low risk tiers, requests an AI originated or contributed to, requests with blocking validation errors or open enrich/approve stages, anything during a freeze window, or beyond the daily cap.
- **Kill switch:** any owner-group member or approver can stop a policy instantly. It can only be cleared by approving a new version.
- **Shadow mode (default for new policies):** the policy is evaluated and recorded, but humans still decide. `v_shadow_summary` shows how often the policy would have committed something a human rejected or pushed back (`too_loose_pct`). That's the evidence for Audit before switching to active.
- **Detective control:** `sample_auto_commits()` draws a daily random sample of auto-commits for human review; `v_commit_policy_daily` tracks volumes, issues and outstanding reviews.
- **Core safety net:** `mdm.change_request` records `decision_basis` (`human_review` or `approved_policy`) and the policy reference. The core trigger accepts a non-human decider only for low-risk, non-AI approvals with a policy reference. Restrict write access on `change_request` to the bridge role so the policy reference can't be forged.

Engine flow for a covered model: submit → run full validation → `wf.apply_commit_policy(instance, validation_start_time, system_actor)` → either committed, or left with the human Commit stage.

## DRM concept mapping

| DRM | New model |
|---|---|
| Version | `version` (business date plus recorded-time slice) |
| Hierarchy / top node / group | `hierarchy` |
| Node, name, description, inactive | `node` + `node_attr` (bitemporal, so renames are tracked) |
| Leaf / limb | `node_attr.allows_children`; `is_leaf` derived per hierarchy |
| Parent-child, sort order | `hierarchy_relationship` |
| Shared node | `hierarchy_relationship.is_primary = false` |
| Global / local property | `property_definition.scope` |
| Inheritance and overrides | `inheritance` + `property_value_asof()`; a JSON null value blocks inheritance |
| Derived property | `derivation_expr` (original formula kept in `drm_formula_orig`) |
| Validation | `validation_rule` (original kept in `drm_validation_orig`) |
| Query / node filter | `export_profile.node_filter` (declarative JSON) |
| Hierarchy and generation exports | `export_profile` + `export_profile_column` + `export_drm()` |
| DRG request | `change_request` + `change_item` |
| Transaction log | `audit_log` |

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

During a change, the application sets the actor so the audit log captures who did what:

```sql
SET LOCAL mdm.actor_id = '<user uuid>';
SET LOCAL mdm.change_request_id = '<cr uuid>';
```

## Known gaps and next steps

- **Not yet run against a live database.** `scripts/db-test` and the pgTAP suites in `db/tests` are the first check.
- Compare, difference, transaction-log and version exports belong in the export service; only hierarchy and generation exports are in SQL.
- Derived properties are evaluated in SQL only for the `sql` engine. CEL and Python run in the rules service.
- Cross-holdings (cycles) are flagged and excluded from totals. Exact treatment needs a matrix solve in the ownership service.
- Exports call functions row by row, which is fine for tens of thousands of nodes. For very large hierarchies, move generation into a set-based query or the export service.
- `ubo_threshold` is intentionally empty. Compliance should load and sign off the values.
- Workflow: stage advancement, push-back (creating the next iteration) and notification templates live in the orchestration engine; only the atomic operations and guards are in SQL.
- Next build step: a loader from `mdm_stage.*` into the core tables, plus the AI inventory job that proposes `drm_property_map` rows and translates DRM formulas and validations.
