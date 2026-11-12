# Phase 1 — Core write path: summary

## What was built
A steward drafts a change request, adds items, validates and submits it; a second human with the approver role in
scope approves or rejects it; Nexus applies it atomically and bitemporally; reads show the result at any business date
and recorded time. Core mode only (no workflow engine yet), with maker-checker as the control.

| Commit | Increment |
|---|---|
| `6cde7c0` | 1-1 Error codes on every guard (ADR-020), `DbErrorTranslator`, Problem Details |
| `8a29869` | 1-2 Change-request controls: requester kind, status transitions, frozen content, draft-only items and deletes, row version, `origin` |
| `76ecde7` | 1-3 Database roles and privileges (V7); the app runs as a least-privilege login |
| `4b356d1` | 1-4 Entitlements by hierarchy and sub-tree (V8), actor port, startup guard, settings, `BusinessClock`, `GET /me` |
| `411f5f8` | 1-5 Keyset paging, `recordedAsOf`, UTC sessions |
| `f85b9f9` | 1-6 Resolved properties with provenance |
| `8267f23` | 1-7 Change-request drafting API: create, edit, items with expected values, withdraw; ETag; idempotency |
| `d414008` | 1-8a Apply framework (set-from-D), add / insert / move, stale base, change events |
| `c18dba8` | 1-8b Apply remove, delete, update node, add hierarchy |
| `e3ee4d6` | 1-8c Apply set / clear property, item limit by origin |
| `40c837b` | 1-9 Validation by trial apply, submit |
| `6314e63` | 1-10 Decision, apply service with retries, sweeper, review queue |
| `9120776` | 1-11 Performance test scaffold (deferred, not run) |
| 1-12 commit | Records: data model, error-code registry, README, developer setup, CHANGELOG, test report, this summary, build state |

## Decisions taken
- Phase 1 plan approved; recommendations accepted for the open points raised while building:
  `versionName` required on create; the review queue arrived with decisions (1-10); `ProblemShapeTest` excludes the
  idempotency filter from its web slice; delete refuses while anything depends on the node; cascade removal follows
  primary links.
- **Performance testing deferred** to the end of the build (repository owner, 2026-11-11).
- ADRs applied: ADR-014 (roles), ADR-015 (API conventions), ADR-016 (outbox), ADR-018 (time), ADR-019 (definer
  functions), ADR-020 (error codes), ADR-021 (Phase 1 control fixes), ADR-022 (entitlements). No new ADR: the choices
  made while building stay within these and are recorded as *Built in …* notes in the LLD.

## Patterns introduced (see `docs/architecture/patterns.md`)
- **Bitemporal set-from-D** without updates: `mdm.apply_fact` closes the current row and re-states history (V1).
- **Owner-run functions as the only write path** (ADR-019): draft (`nexus_api`), decide/submit/withdraw (`nexus_decider`), facts (`nexus_apply`).
- **Trial apply for validation**: the same item path as apply, always rolled back (`N9999`); findings survive in variables.
- **Optimistic concurrency** with `row_version` ETags under a row lock; **idempotency keys** for POSTs.
- **Transactional outbox**: one `change_event` per applied request (consumers in Phase 2/8).
- **Keyset paging** with opaque cursors.

## Deviations from the plan and the LLD (all recorded in the LLD)
- Settings and `BusinessClock` moved from 1-5 to 1-4 (needed by entitlements).
- Added guards and codes the LLD implied but did not name: only drafts can be deleted; `N1025`, `N2104`, `N2105`, `N2106`.
- Stale-base details in `DETAIL`, not `HINT` (ADR-020 reserves `HINT` for the code).
- `mdm.record_apply_failure` added so a request that keeps failing for technical reasons leaves `approved`.
- System rule `NEXUS.TRIAL_APPLY` holds trial findings (`validation_result.rule_id` is required).
- Rule SQL read positionally, as the V1 rule contract says (the seeded rules depend on it).
- 1-11 deferred.

## Known gaps and technical debt
See `TEST_REPORT.md` → Explicit gaps (performance not measured; three test gaps; retry path untested; golden parity in
Phase 4; metrics; OpenAPI needs a dependency approval; CI never run on GitHub). Also:
- Running locally uses the single docker-compose account (owner); only tests run as the least-privilege login.
- Mockito dynamic-agent warning; `check-setup` still asks for a local `mvn`.
- Rule SQL runs with the fact writer's rights inside a rolled-back trial; once rule authoring is opened to users it needs its own control.
- Open design-state items for later phases: D-06, D-12 to D-15, D-22, D-33 (OD-18).

## What the next phase needs
Phase 2 (workflow with Camunda 8, ADR-017 / ADR-024) builds on: `governed_by_workflow`, `change_item_clearance`
(bridge writes it), the `in_review` transition, `change_event` as the trigger for the engine, and the decision and apply
functions above. Before merging this branch: Audit-Risk review of ADR-021 (OD-18a). To run CI: a GitHub remote (OD-11).
