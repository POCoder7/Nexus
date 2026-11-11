# Nexus pattern catalogue

- **Status:** First version, awaiting review (2026-11-11). Extended as each phase LLD is written.
- Each entry: intent · problem in Nexus · solution · where applied · trade-offs and failure modes · alternatives ·
  when not to use · related ADR. **Verdict** is Adopted, Adapted (used in a changed form) or Rejected.
- "Exists" = verified in the repository; file paths are real. "Planned" paths are proposals for the phase LLDs.

## Summary

| # | Pattern | Verdict | Phases |
|---|---|---|---|
| P-01 | Bitemporal append-only facts | Adopted (exists) | 1–9 |
| P-02 | Named version slices | Adopted (exists), extended | 1, 5, 8 |
| P-03 | Maker-checker | Adopted (exists), to harden | 1, 2, 6, 7 |
| P-04 | Policy as data with shadow mode | Adopted (exists) | 2 |
| P-05 | Layered schemas with a single bridge (anti-corruption layer) | Adopted (exists), to enforce | 1, 2 |
| P-06 | Transactional outbox | Adapted | 2, 8 |
| P-07 | Ports and adapters | Adopted | 1–9 |
| P-08 | Command path separated from read path | Adapted (same store) | 1–5 |
| P-09 | Change items as commands with atomic apply (unit of work) | Adopted | 1, 4, 5, 7 |
| P-10 | Optimistic concurrency and idempotency keys | Adopted | 1, 2, 4 |
| P-11 | Keyset pagination and lazy tree loading | Adopted | 1, 3, 5 |
| P-12 | Tree storage: adjacency list with recursive queries | Adopted; closure table and materialised path rejected as source of truth | 1, 3, 5, 8 |
| P-13 | Specification / rules engine for validations | Adapted | 1, 5 |
| P-14 | Strategy for derived-property engines | Adopted | 1, 5 |
| P-15 | State machine and process manager for workflow | Adopted | 2 |
| P-16 | Event-driven notifications | Adopted (pending capability decision) | 2 |
| P-17 | Role- and scope-based entitlements | Adopted (pending capability decision) | 1, 5, 9 |
| P-18 | Evidence-linked provenance | Adopted (exists), extended to reads | 1, 3, 6, 7 |
| P-19 | Human-in-the-loop AI with a provider adapter | Adopted | 7 |
| P-20 | Chunked and streaming batch processing with backpressure | Adopted | 4, 5, 8 |
| P-21 | Caching and invalidation | Adapted: immutable slices only | 3, 5, 8 |
| P-22 | Golden-master testing | Adopted | 4, 5, 8 |
| P-23 | Strangler migration and parallel run | Adapted: consumer-by-consumer cutover | 4, 8 |
| P-24 | Database-enforced invariants (guards) | Adopted (exists) | 1–9 |
| P-25 | Repository per aggregate with explicit SQL | Adopted (exists) | 1–9 |
| P-26 | Feature store with signals (UI state) | Adopted | 3, 5–8 |
| P-27 | Generated API client from OpenAPI | Adopted | 3, 5–8 |

---

## P-01 Bitemporal append-only facts — Adopted (exists)

- **Intent:** never lose what was believed, and answer "what did we know on date T about date D?".
- **Problem in Nexus:** DRM rebuilds old versions from transaction logs (VER-03). Regulators and UBO reviews ask what
  Nexus knew at onboarding time (NEW-01). Corrections must not erase earlier beliefs.
- **Solution:** each fact row has `valid_period daterange` and `recorded_period tstzrange`. The current belief is
  `upper_inf(recorded_period)`. A correction closes `recorded_period` and inserts a replacement. Guards:
  `mdm.trg_bitemporal_guard` (no delete; only `recorded_period` may change) and `EXCLUDE USING gist (key WITH =,
  valid_period WITH &&) WHERE (upper_inf(recorded_period))` so current beliefs never overlap.

  ```sql
  -- correct a node name from 01 Mar onwards (sketch of what ApplyService does)
  UPDATE mdm.node_attr SET recorded_period = tstzrange(lower(recorded_period), now())
   WHERE node_id = :id AND upper_inf(recorded_period) AND valid_period && daterange(:from, NULL);
  INSERT INTO mdm.node_attr (..., valid_period) VALUES (..., daterange(:from, NULL));
  -- plus re-insert the unaffected part [old_lower, :from) with the old values
  ```
- **Invariants:** no current overlap per key; no physical delete; history rows immutable.
- **Where applied:** exists in V1 (`node_attr`, `node_identifier`, `legal_entity_profile`, `hierarchy_relationship`,
  `property_value`) and V2 (`ownership_edge`). Planned: `ApplyService` (Phase 1) owns the split-and-close logic;
  all reads take `asOf` + `recordedAsOf` (Phase 1, D-18).
- **Trade-offs / failure modes:** writes touch up to three rows per change (close, before-part, after-part); queries
  must always filter both periods or they return history. Definitions (`hierarchy`, `property_definition`,
  `export_profile`) are not bitemporal (D-08), so old exports use current definitions; decide in Phase 5 whether to
  historise them. Table growth is unbounded; partitioning by `recorded_period` may be needed (benchmark in Phase 4).
- **Alternatives:** uni-temporal history tables (lose "what we knew"); event sourcing (rebuild cost, harder SQL for exports); copying data per version (DRM's model; storage and drift).
- **When not to use:** configuration and workflow state (`wf.*`), which have their own frozen-version or append-only rules.
- **Related ADR:** ADR-006 (Proposed).

## P-02 Named version slices — Adopted (exists), extended

- **Intent:** give DRM's "versions" a meaning without copying data.
- **Problem in Nexus:** stewards and exports work on named versions (FY26_Oct); copying whole hierarchies per period is slow and drifts.
- **Solution:** `mdm.version(business_as_of, recorded_as_of)`. A working version reads recorded time = now; a finalized
  version pins `recorded_as_of` (CHECK exists). Every read takes a version or an explicit (asOf, recordedAsOf) pair.
  Planned additions: version aliases (VER-05, "to add"), version-level properties (VER-07), status-transition guard
  (VER-02: edits rejected in submitted/finalized versions).
- **Invariants:** a finalized version's reads never change; `version_name` unique.
- **Where applied:** exists in V1 `mdm.version` and V3 `mdm.export_drm`. Planned: Phase 1 read API, Phase 5 VER-*, Phase 8 exports.
- **Trade-offs / failure modes:** a slice only freezes facts, not definitions (D-08). Two working versions with
  different business dates share the same current recorded beliefs; a change for one is visible to the other at its date.
- **Alternatives:** physical copies (rejected: volume, VER-01 "no physical copy"); database snapshots per version (operationally heavy).
- **When not to use:** sandboxes with unapproved edits (NEW-08, BLD-03), which need an overlay of draft changes, not a slice.
- **Related ADR:** ADR-006.

## P-03 Maker-checker — Adopted (exists), to harden

- **Intent:** no one changes governed data alone.
- **Problem in Nexus:** DRG governance and Audit require that requesters never approve their own changes and that AI agents never decide.
- **Solution:** `mdm.trg_cr_maker_checker` (decider ≠ requester; human decider unless a low-risk, non-AI,
  policy-based approval by the system actor). Policies themselves are maker-checked (`wf.trg_policy_guard`:
  approver ≠ proposer, human, in `POLICY_APPROVERS`). `wf.can_act` blocks requester and submitter on approve/commit stages.
- **Invariants:** decided_by ≠ requester_id; non-human deciders only under `approved_policy`; AI requests always human-decided.
- **Where applied:** exists in V1, V4, V6; tested in `db/tests/01_core_invariants.sql` and `02_workflow_invariants.sql`.
  Planned hardening (OD-18): check `requester_kind` against `app_user.kind` (D-05), freeze `change_item` after
  submit (D-07), guard status transitions (D-07), restrict decision columns to the bridge role (D-04, ADR-014).
- **Trade-offs / failure modes:** the self-declared `requester_kind` (D-05) lets a mislabelled AI request pass the AI rule today.
- **Alternatives:** application-only checks (bypassable by any SQL client); four-eyes on every edit with no policy path (rejected by ADR-005 for low-risk volume).
- **When not to use:** read-only actions and drafts.
- **Related ADR:** ADR-005, ADR-008.

## P-04 Policy as data with shadow mode — Adopted (exists)

- **Intent:** move maker-checker from each request to a human-approved rule, safely.
- **Problem in Nexus:** GOV-12: DRG commits some requests with no approver; Nexus must allow this only under evidence-backed, revocable control.
- **Solution:** `wf.commit_policy` rows (allowed actions, item conditions, caps, review date, owner group), approved by a
  human and immutable afterwards; `wf.evaluate_commit_policy` returns every failed check;
  `wf.apply_commit_policy` records a `wf.policy_evaluation` always, and commits only in `active` mode when eligible.
  Shadow results feed `wf.v_shadow_summary.too_loose_pct`, the evidence Audit reviews before activation.
  Detective control: `wf.sample_auto_commits`.
- **Invariants:** hard-limit CHECK on actions; one approved version per policy code; one approved policy per model;
  kill switch one-way; a system commit needs an unused `auto_committed` evaluation (`wf.trg_action_guard` V6).
- **Where applied:** exists in V6; Phase 2 wires the engine call after validation (BUILD_PROTOCOL Phase 2 exit: shadow mode runs).
- **Trade-offs / failure modes:** cap race (D-14); evaluation uses `now()` and `current_date` (D-16); activating any policy needs Audit/Risk sign-off (OD-08).
- **Alternatives:** hard-coded rules in Java (no Audit visibility, no versioning); no STP at all (fails GOV-12).
- **When not to use:** anything on the hard-limit list or touching protected properties.
- **Related ADR:** ADR-005.

## P-05 Layered schemas with a single bridge (anti-corruption layer) — Adopted (exists), to enforce

- **Intent:** keep the core model independent of the workflow product.
- **Problem in Nexus:** DRG-style governance is complex and the engine is undecided (OD-01); the core must run without it.
- **Solution:** `mdm` never references `wf` (verified); `wf` reads `mdm` and writes only `wf` (verified); `wf_bridge`
  is the only writer across (`sync_change_request` → `mdm.change_request`; `v_items_to_apply` → apply service).
  In Java, `ApprovedItemsSource` has two adapters (workflow bridge, core maker-checker) so the apply path is the same.
- **Invariants:** no FK, view or function in `mdm` names `wf`/`wf_bridge`; no write into `mdm` from `wf`.
- **Where applied:** exists V4–V6; planned enforcement by privileges (ADR-014) and a CI check that greps V1–V3 and the
  `mdm` Java modules for `wf.` references (Phase 0 LLD).
- **Trade-offs / failure modes:** the rule is enforced only by review today (no roles, D-04). Bridge attribution after splits is wrong (D-06).
- **Alternatives:** workflow tables in `mdm` (rejected in ADR-003); commercial workflow product only (rejected in ADR-003).
- **When not to use:** within one layer.
- **Related ADR:** ADR-003, ADR-014.

## P-06 Transactional outbox — Adapted

- **Intent:** publish events exactly when the state change commits.
- **Problem in Nexus:** the engine, notifications (GOV-08/16) and downstream events (NEW-07) must see every change without dual writes.
- **Solution:** events are inserted in the same transaction as the change: `wf.event_outbox` (exists) for workflow;
  `mdm.change_event` (planned) for applied data, so `mdm` stays independent of `wf`. Adaptation: each consumer keeps
  its own position in `wf.outbox_consumer(consumer_code, last_event_id)` instead of the single `processed_at` (D-32).
  Consumers poll with `WHERE event_id > :last ORDER BY event_id LIMIT :batch`, process idempotently, then advance.
- **Invariants:** an event exists iff its transaction committed; consumers process each event at least once; event ids are monotonic per table (identity).
- **Where applied:** exists in V4/V6 (`wf.event_outbox` and its writers); planned Phase 2 (worker, notifier) and Phase 8 (NEW-07 relay).
- **Trade-offs / failure modes:** identity values can commit out of order, so a consumer reading `> last` may skip a
  late-committing lower id; mitigate by reading only events older than `OUTBOX_SAFETY_LAG` (2 s) or by a per-batch gap check. Table growth needs pruning after all consumers pass an id.
- **Alternatives:** logical decoding / CDC (Debezium; heavier platform dependency, OD-20); direct broker publish (dual write).
- **When not to use:** synchronous reads; data needed inside the same request.
- **Related ADR:** ADR-016.

## P-07 Ports and adapters — Adopted

- **Intent:** keep domain logic independent of replaceable externals.
- **Problem in Nexus:** the workflow engine, identity provider, AI provider, storage and delivery targets are open decisions; code must not wait for them.
- **Solution:** interfaces in the owning module, adapters in `…/adapter/…`. List in `overview.md` §4
  (`ApprovedItemsSource`, `WorkflowGateway`, `RuleEngine`, `DerivationEngine`, `CurrentActor`, `AiProposalPort`,
  `DocumentStore`, `DeliveryTarget`). Each port has a deterministic in-memory or local adapter for tests.
- **Where applied:** planned from Phase 1, e.g. `services/mdm-api/src/main/java/com/mdm/api/security/CurrentActor.java` (Phase 1 LLD §3.1); `WorkflowGateway` in Phase 2.
- **Trade-offs / failure modes:** interfaces for things that never change add indirection; only externals and the two apply sources get ports.
- **Alternatives:** direct SDK use (locks in OD choices); microservice per external (operational cost, ADR-013).
- **When not to use:** the database: SQL stays explicit in repositories (P-25); the database is not abstracted.
- **Related ADR:** ADR-013.

## P-08 Command path separated from read path — Adapted (same store)

- **Intent:** keep writes strictly governed while reads stay fast and simple.
- **Problem in Nexus:** writes must pass change requests, validation and guards; reads are large (trees, as-of views) and need different query shapes.
- **Solution:** separate Java components (`*Service` for commands, `*Repository`/`*Query` for reads) over the same
  PostgreSQL schema. No separate read store. Commands never return read models beyond ids and versions; reads never write.
- **Where applied:** exists in shape (`HierarchyRepository`, `NodeRepository` are read-only); planned `ChangeRequestService`, `ApplyService` (Phase 1).
- **Trade-offs / failure modes:** heavy reads share the database with writes; if benchmarks fail, add a read replica for reads with `recordedAsOf` in the past (safe by construction: history never changes).
- **Alternatives:** full CQRS with event-sourced projections (rejected: bitemporal tables already give history; projections add lag and a second truth).
- **When not to use:** within a single command that must read its own writes.
- **Related ADR:** ADR-013.

## P-09 Change items as commands with atomic apply (unit of work) — Adopted

- **Intent:** every data change is a reviewable command applied all-or-nothing.
- **Problem in Nexus:** DRG requests contain many actions; partial application would leave hierarchies inconsistent (HIE-02, IMP-03 "apply atomically").
- **Solution:** `mdm.change_item(action, hierarchy_id, node_id, target_parent_id, property_id, payload)` (exists).
  `mdm.apply_change_request(cr, actor)` (SQL, `SECURITY DEFINER`, ADR-019) locks the request, takes its items in `seq`
  order (all items, or only those in `mdm.change_item_clearance` when a workflow governs it), checks each item's expected
  base, writes bitemporal rows, writes `mdm.change_event`, sets `status = 'applied'`, all in one transaction; rule
  failures are caught and recorded as `apply_failed`. Java `ApplyService` only orchestrates. Design: Phase 1 LLD §7.1.
- **Invariants:** applied iff every item applied; items frozen after submit (to add, D-07); actor and request set on every row (D-29).
- **Where applied:** planned Phase 1 `mdm.apply_change_request` (in V1) and `com.mdm.api.apply.ApplyService`; Phase 4 imports and Phase 7 AI proposals produce the same items.
- **Trade-offs / failure modes:** very large requests hold locks long (`MAX_ITEMS_PER_CHANGE_REQUEST`); one bad item fails the whole request (intended).
- **Alternatives:** apply items individually (breaks atomicity); apply in Java (the first version of this entry; rejected in ADR-019 because the application login would need write access to facts).
- **When not to use:** reference data seeding by migrations.
- **Related ADR:** ADR-003, ADR-013, ADR-019.

## P-10 Optimistic concurrency and idempotency keys — Adopted

- **Intent:** safe concurrent editing and safe retries.
- **Problem in Nexus:** several stewards edit drafts; requests are approved days after drafting; UI and engine retry calls.
- **Solution:** ETag/`If-Match` on mutable resources (`mdm.change_request.row_version`, proposed); stale-base check on
  apply (`payload.expected`, overview §8.2); `Idempotency-Key` on POSTs stored in `mdm.idempotency_key` (proposed).
- **Where applied:** planned Phase 1 API; Phase 2 decision endpoints; Phase 4 import batches.
- **Trade-offs / failure modes:** conflicts surface to users as "someone changed this"; key storage needs pruning.
- **Alternatives:** pessimistic locks held across user think-time (rejected); last-writer-wins (loses changes silently).
- **When not to use:** append-only records (decisions, actions), which are guarded by uniqueness instead.
- **Related ADR:** ADR-015.

## P-11 Keyset pagination and lazy tree loading — Adopted

- **Intent:** constant-time paging over very large sets.
- **Problem in Nexus:** sibling sets can hold thousands of leaves (comment in `HierarchyRepository.findChildren`); offset paging degrades and skips rows under change.
- **Solution:** cursor = last `(sort_order, node_name, child_node_id)`; query `WHERE (r.sort_order, a.node_name,
  r.child_node_id) > (:s, :n, :id) ORDER BY 1,2,3 LIMIT :limit+1` (the extra row tells whether there is a next page).
  Index planned: `(hierarchy_id, parent_node_id, sort_order, child_node_id) WHERE upper_inf(recorded_period)`.
  UI loads one parent at a time with virtual scroll.
- **Where applied:** exists as offset paging in `HierarchyController.children`; planned keyset in Phase 1 (API) and Phase 3 (UI tree, worklist table).
- **Trade-offs / failure modes:** no "jump to page N"; cursor tied to sort order. `node_name` comes from `node_attr`,
  so the index cannot cover it; benchmark `MAX_SIBLINGS` in Phase 4.
- **Alternatives:** offset (exists; rejected for scale); load whole subtree (rejected for size).
- **When not to use:** small bounded lists (hierarchy list may stay simple if `MAX_HIERARCHIES` stays small; still paged per CLAUDE.md).
- **Related ADR:** ADR-015.

## P-12 Tree storage and traversal — adjacency list with recursive queries (Adopted); closure table and materialised path rejected as source of truth

- **Intent:** store bitemporal trees so that moves are cheap and history is exact.
- **Problem in Nexus:** a move in a bitemporal tree must be a single fact change; descendants, inheritance and exports must follow it at any (asOf, recordedAsOf).
- **Solution:** `mdm.hierarchy_relationship` adjacency list (exists) with recursive CTEs: `trg_hierarchy_integrity`
  (ancestor walk), `hierarchy_tree`, `property_value_asof` (primary-ancestor walk). Depth bounded by
  `MAX_HIERARCHY_DEPTH` (one setting instead of today's 100/25/none, D-09).
- **Evaluation:**

  | Option | Move cost | Subtree read | Bitemporal fit | Verdict |
  |---|---|---|---|---|
  | Adjacency list + recursive CTE | 1 row | O(subtree) per query | Natural: one fact per edge | **Adopted** |
  | Closure table | O(subtree × ancestors) rows, each bitemporal | O(1) lookup | Every move rewrites history rows for all descendants | Rejected as truth |
  | Materialised path | O(subtree) rows rewritten | Prefix scan | Same rewrite problem; paths change on rename if name-based | Rejected as truth |
  | Non-authoritative cache (e.g. per-version ancestor table rebuilt after apply) | Rebuild cost | Fast | Only for frozen slices | Keep as fallback if Phase 4 benchmarks fail |
- **Where applied:** exists V1/V3; planned Phase 3 lazy loading uses one level at a time; Phase 8 exports may need a set-based rewrite (data-model "Known gaps").
- **Trade-offs / failure modes:** full-tree walks inside per-row functions (D-10 worklist, export row-by-row) are the main risk.
- **When not to use:** the ownership graph (P-18, Phase 6), which is a weighted DAG with cycles, solved by matrix methods.
- **Related ADR:** ADR-006; a performance ADR in Phase 4 if the fallback is needed.

## P-13 Specification / rules engine for validations — Adapted

- **Intent:** validations as versioned, testable data, not hidden code.
- **Problem in Nexus:** DRM validations are formulas (VAL-04); they must run in real time (VAL-01), in batch (VAL-02) and at the right level (VAL-03).
- **Solution:** `mdm.validation_rule(level, severity, engine, expression, hierarchy_id, rule_version)` (exists, with
  the `sql` contract `$1 = as_of, $2 = recorded_as_of` returning `(node_id, hierarchy_id, message)`).
  `ValidationRunner` selects active rules by level and scope and runs them via `RuleEngine` (strategy per `engine`).
  Adaptation: real-time validation runs the same rules against the *proposed* state (items applied in a savepoint,
  then rolled back) so there is one rule definition for both modes. Results go to `mdm.validation_result`.
- **Where applied:** exists V1/V2 (table, 4 starter rules); planned Phase 1 `com.mdm.api.validation`.
- **Trade-offs / failure modes:** savepoint trial-apply costs a write per validation; admin-authored SQL needs a read-only role (D-39).
- **Alternatives:** a general rules engine product (Drools: another language to govern); Java-coded validations (not data, not versioned per rule).
- **When not to use:** structural invariants that must never be bypassed (cycles, types): those stay database guards (P-24).
- **Related ADR:** OD-19 (CEL/Python engines).

## P-14 Strategy for derived-property engines — Adopted

- **Intent:** one place that decides how a derived value is computed.
- **Problem in Nexus:** PRP-06 derived properties are DRM's key golden test; formulas need a deterministic, auditable engine.
- **Solution:** `property_definition.derivation_engine in ('sql','cel','python')` (exists CHECK). `DerivationEngine`
  strategy per engine; `sql` exists inside `mdm.property_value_asof`. `cel` and `python` are open (OD-19; ADR-011 limits Python).
  Every engine is deterministic: same inputs → same output, no network, no clock.
- **Where applied:** exists V1/V3 (`sql`); planned Phase 5 (PRP-06) with golden tests per derived property.
- **Trade-offs / failure modes:** derivations computed per node per read are slow for exports; Phase 8 may batch them.
- **Alternatives:** store derived values (stale on ancestor change); AI-computed values (forbidden by CLAUDE.md rule 4).
- **When not to use:** stored properties.
- **Related ADR:** ADR-008.

## P-15 State machine and process manager for workflow — Adopted

- **Intent:** the database owns state and invariants; a process manager drives time and progression.
- **Problem in Nexus:** DRG stages, claims, SLAs, push-back and splits (GOV-02…09) need timers and orchestration, but the controls must hold whatever the engine does.
- **Solution:** state in `wf.workflow_instance.status` and `wf.instance_stage.status` with atomic transition functions
  (`wf.start_instance`, `wf.split_instance`, `wf.close_instance`, `wf.apply_commit_policy`, exist). The process manager
  (workflow worker) consumes `wf.event_outbox` and calls planned operations for what SQL does not do yet: activate the
  next included stage, claim/unclaim with expiry, push back (new iteration per `reapproval`), escalate on SLA.
  Every planned operation is a SQL function with its own guard, so an engine bug cannot skip a control.

  ```text
  instance: draft → in_flight ⇄ pushed_back → committed | rejected | withdrawn
  stage:    pending → active → claimed → completed | rejected ; pending → skipped
  ```
- **Where applied:** exists V4/V6; Phase 2 LLD: `wf.advance_instance`, `wf.complete_stage`, `wf.record_stage_decision`,
  `wf.claim_stage` (V4/V9), and Camunda 8 job workers in `com.mdm.api.workflow.engine` driving one generic BPMN process (ADR-017, ADR-024).
- **Trade-offs / failure modes:** two places to look (SQL + worker); missing guards today on claim and close (D-12, D-13).
- **Alternatives:** all logic in the engine (controls bypassable); all logic in SQL including timers (`pg_cron`; weak escalation and notification support).
- **When not to use:** core-only maker-checker (no stages).
- **Related ADR:** ADR-003, ADR-017, ADR-023, ADR-024.

## P-16 Event-driven notifications — Adopted (pending capability decision)

- **Intent:** tell the right people without coupling notification logic to the transaction.
- **Problem in Nexus:** GOV-08 (notifications), GOV-16 (alerts), kill-switch and SLA breaches.
- **Solution:** a notifier consumer on `wf.event_outbox` (P-06) resolves recipients from `workflow_stage.notify` and
  groups, writes `wf.notification` rows (in-app inbox, planned) and sends e-mail through a delivery adapter (OD-20/platform).
- **Where applied:** planned Phase 2 (outline until GOV-08/GOV-16 are decided).
- **Trade-offs / failure modes:** at-least-once → recipients may see duplicates unless deduplicated on `(event_id, recipient)`.
- **Alternatives:** synchronous e-mail in the request (slow, fails the request on mail errors).
- **When not to use:** anything needing action: that goes to the worklist (UI_STANDARD §6).
- **Related ADR:** ADR-016.

## P-17 Role- and scope-based entitlements — Adopted (pending capability decision)

- **Intent:** decide who may see and change what, by role and by data scope.
- **Problem in Nexus:** DRM node access groups (SEC-02), property access (SEC-03), roles (SEC-01), DRG node access (`wf.stage_access_scope`).
- **Solution:** planned `mdm.role`, `mdm.user_role(scope: hierarchy_id, top_node_id, category_code)`; an
  `EntitlementService` answers `canRead/canPropose(actor, node, hierarchy, property)` and produces SQL filters for
  reads. Workflow permissions stay in `wf.can_act`. Database roles (ADR-014) are a separate, coarser layer.
- **Where applied:** planned Phase 1 (minimal: authenticated actor + propose right), Phase 5 (SEC-01…04 once decided), Phase 9 (IdP groups).
- **Trade-offs / failure modes:** sub-tree scopes need ancestor checks per node (P-12 cost); cache per request.
- **Alternatives:** row-level security in PostgreSQL (strong, but hard with recursive scopes and one pooled login; revisit in Phase 9).
- **When not to use:** to enforce maker-checker or SoD: those stay in database guards.
- **Related ADR:** to write in Phase 5.

## P-18 Evidence-linked provenance — Adopted (exists), extended to reads

- **Intent:** every value says where it came from.
- **Problem in Nexus:** UBO results need paths and evidence (NEW-02); AI facts must cite a source (ADR-008); stewards need to see whether a value is stored, inherited, derived or defaulted (UI_STANDARD provenance tokens).
- **Solution:** exists: `mdm.evidence_document` (SHA-256 unique), `ownership_edge.evidence_document_id` and
  `evidence_locator`, CHECK "no evidence, no AI fact", `change_item.evidence_document_id`. Planned:
  `mdm.property_value_resolved(...)` returning `(value, provenance, source_node_id, property_value_id)` so the read API
  reports provenance (D-18); UBO API returns `paths` (exists in `ubo_ownership_prong`).
- **Where applied:** exists V2; planned Phase 1 (read provenance), Phase 6 (ownership API), Phase 7 (AI evidence viewer).
- **Trade-offs / failure modes:** provenance doubles the payload of node detail; return it per value, compactly.
- **Alternatives:** provenance only in audit log (not answerable per value at read time).
- **When not to use:** system properties computed per read (level, child count), labelled `system`.
- **Related ADR:** ADR-008.

## P-19 Human-in-the-loop AI with a provider adapter — Adopted

- **Intent:** use AI to propose; humans decide; code calculates.
- **Problem in Nexus:** NEW-03 to NEW-06; the model provider is open (OD-07); outputs must be testable and never pre-applied.
- **Solution:** AI services (Python, ADR-011) behind `AiProposalPort`. Each output becomes a change request by an
  `ai_agent` user with `rationale`, `ai_model`, `ai_confidence` (CHECK exists) or an `ai_suggestion` action
  (`wf.instance_action`, exists). Guards already forbid AI decisions (`trg_cr_maker_checker`, `wf.trg_action_guard`)
  and AI-originated requests from policy commit (`evaluate_commit_policy`). A deterministic stub adapter drives tests;
  an evaluation harness measures accuracy on synthetic, labelled data.
- **Where applied:** planned Phase 7.
- **Trade-offs / failure modes:** D-05 must be fixed first, or an AI request can be mislabelled as human.
- **Alternatives:** AI writing data directly (forbidden); AI only in the UI with no record (no audit trail).
- **When not to use:** any calculation (ownership %, inheritance, exports) — CLAUDE.md rule 4.
- **Related ADR:** ADR-008; provider ADR in Phase 7 (OD-07).

## P-20 Chunked and streaming batch processing with backpressure — Adopted

- **Intent:** move large volumes without exhausting memory or holding long locks.
- **Problem in Nexus:** DRM extracts and imports (IMP-01/02), batch validation (VAL-02), exports of very large hierarchies (Phase 8).
- **Solution:** stream with JDBC cursors (`fetchSize = BATCH_FETCH_SIZE`, 1 000); stage raw rows in `mdm_stage.*` in
  chunks of `STAGE_CHUNK_SIZE` (5 000) per transaction; convert staged data into change requests of at most
  `MAX_ITEMS_PER_CHANGE_REQUEST`; producers block on a bounded queue (`BATCH_QUEUE_CAPACITY`) so a slow writer slows
  the reader. Exports stream lines to the `DeliveryTarget` while hashing.
- **Where applied:** planned Phase 4 (loader, synthetic generator), Phase 5 (batch validation), Phase 8 (exports).
- **Trade-offs / failure modes:** a chunked load is not atomic as a whole; each change request is, and the import run records which requests succeeded so it can resume.
- **Alternatives:** load whole files in memory (fails at scale); bypass change requests for bulk (breaks governance).
- **When not to use:** interactive requests.
- **Related ADR:** to write in Phase 4.

## P-21 Caching and invalidation — Adapted: immutable slices only

- **Intent:** speed up repeat reads without serving stale data.
- **Problem in Nexus:** tree and node reads repeat heavily; invalidating caches of bitemporal current data is error-prone.
- **Solution:** no application cache for reads at recorded time = now. Cache only reads whose key includes a pinned
  `recordedAsOf` (finalized versions, explicit past instants): they can never change. HTTP `ETag` on those responses;
  in-process cache with size bound `READ_CACHE_MAX_ENTRIES`. Definitions (`property_definition`, rules) cached per
  request only.
- **Where applied:** planned Phase 3 (tree reads of finalized versions), Phase 8 (exports of finalized versions).
- **Trade-offs / failure modes:** current-time reads hit the database every time; acceptable until Phase 4 benchmarks say otherwise.
- **Alternatives:** distributed cache with event-driven invalidation (complex, risk of stale governed data).
- **When not to use:** anything an approver decides on.
- **Related ADR:** none yet.

## P-22 Golden-master testing — Adopted

- **Intent:** prove parity with the legacy system objectively.
- **Problem in Nexus:** "same as DRM" is the acceptance criterion for most capabilities.
- **Solution:** capture DRM outputs inside the organisation's network, mask consistently, store under `tests/golden/`
  (README exists), and compare Nexus outputs byte for byte (exports) or row for row (inherited values, validations).
  Reconciliation in production uses `mdm.export_run.file_sha256` vs `mdm.drm_reconciliation.drm_sha256` (exists).
- **Where applied:** planned Phase 4 (framework), Phase 5 (per capability), Phase 8 (exports).
- **Trade-offs / failure modes:** masking must preserve sort order and lengths where exports depend on them (open question in SLICE-01); never real data in the repository (CLAUDE.md rule 5).
- **Alternatives:** hand-written expected values (do not prove parity).
- **When not to use:** new capabilities (NEW-*) with no legacy output.
- **Related ADR:** ADR-009.

## P-23 Strangler migration and parallel run — Adapted

- **Intent:** replace DRM without a big-bang cutover.
- **Problem in Nexus:** DRM is a packaged product; its calls cannot be intercepted, but its outputs feed downstream systems.
- **Solution:** strangle by consumer: Nexus produces each downstream export alongside DRM in pre-production; daily
  reconciliation (NEW-09, `drm_reconciliation`) must stay exact for `PARALLEL_RUN_DAYS` (assumption 30) before that
  consumer cuts over (ADM-04). Data flows DRM → `mdm_stage` → change requests until cutover, then Nexus is master.
- **Where applied:** planned Phase 4 (loader), Phase 8 (export parity, reconciliation).
- **Trade-offs / failure modes:** dual maintenance during the parallel run; edits in DRM must be re-loaded or frozen.
- **Alternatives:** big-bang cutover (high risk); request routing proxy (not possible with a packaged product).
- **When not to use:** new capabilities with no DRM equivalent.
- **Related ADR:** ADR-002, ADR-009.

## P-24 Database-enforced invariants (guards) — Adopted (exists)

- **Intent:** controls that hold for every client, including scripts and future services.
- **Problem in Nexus:** Audit-relevant rules must not depend on application code paths.
- **Solution:** triggers and constraints listed in `docs/design/DESIGN_STATE.md` ("What exists"). Each guard has a
  pgTAP test (`BEGIN … ROLLBACK`); CLAUDE.md rule 1 forbids weakening them.
- **Where applied:** V1–V6; every phase adds guards with tests. Coverage gaps in D-22.
- **Trade-offs / failure modes:** error messages are free text (D-21; ERRCODE proposal in overview §9); per-row triggers cost on bulk loads (Phase 4 benchmark).
- **Alternatives:** application-only validation (bypassable).
- **When not to use:** user-facing business validations that need warnings or overrides: those are rules (P-13).
- **Related ADR:** ADR-003, ADR-005, ADR-006.

## P-25 Repository per aggregate with explicit SQL — Adopted (exists)

- **Intent:** visible, reviewable SQL with one owner per aggregate.
- **Problem in Nexus:** bitemporal queries must filter both periods correctly; ORMs hide that.
- **Solution:** `JdbcClient` with named parameters, schema-qualified names, explicit row mappers, records as DTOs
  (CLAUDE.md conventions; `HierarchyRepository`, `NodeRepository` exist). One repository per aggregate: hierarchy,
  node, change request, workflow instance, policy, export profile, ownership graph.
- **Where applied:** exists in `com.mdm.api.hierarchy` and `com.mdm.api.node`; every phase.
- **Trade-offs / failure modes:** more SQL to maintain; mitigated by Testcontainers tests against real migrations.
- **Alternatives:** JPA/Hibernate (rejected: bitemporal semantics, explicit SQL convention).
- **When not to use:** —
- **Related ADR:** ADR-011.

## P-26 Feature store with signals (UI state) — Adopted

- **Intent:** one place per feature for client state, with predictable change detection.
- **Problem in Nexus:** the tree, tray and worklist hold large, paged, frequently changing state shared by several components; ad-hoc component state would duplicate requests and break `OnPush`.
- **Solution:** an injectable store per feature (`HierarchyStore`, `NodeStore`, `TrayStore`, `WorklistStore`, `ContextStore`,
  `PreferencesStore`) exposing read-only signals and `computed` views (e.g. `visibleRows()`); containers call store
  methods; presentational components receive inputs and emit outputs only. Stores call the generated client (P-27).
- **Where applied:** Phase 3 LLD §3.2, `ui/src/app/*/`; later UI phases.
- **Trade-offs / failure modes:** stores can grow into god objects; keep one per feature and no cross-store writes (stores read `ContextStore` only).
- **Alternatives:** NgRx (more ceremony; UI_STANDARD §2 requires an ADR to adopt a state library); component-local state (duplication).
- **When not to use:** purely local UI state (an open menu).
- **Related ADR:** ADR-012, ADR-025.

## P-27 Generated API client from OpenAPI — Adopted

- **Intent:** the UI and the API cannot drift silently.
- **Problem in Nexus:** many endpoints with Problem Details, cursors and ETags; hand-written DTOs would diverge.
- **Solution:** the API build publishes an OpenAPI document (`springdoc-openapi`); the UI build generates TypeScript
  clients and models into `ui/src/app/api` (never edited by hand); a contract change fails the UI build.
- **Where applied:** Phase 3 LLD §5, increment 3-2.
- **Trade-offs / failure modes:** generator quirks for `oneOf` and headers; thin facades wrap ETag and idempotency handling.
- **Alternatives:** hand-written services (drift); GraphQL codegen (no GraphQL API, ADR-015).
- **When not to use:** —
- **Related ADR:** ADR-015, ADR-025.
