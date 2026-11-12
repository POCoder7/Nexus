# Phase 2 — Governance: summary

## What was built
A request can now go through a DRG-style workflow: submitted with a workflow model, moved through Enrich, Approve and
Commit stages by an engine, decided by people from their worklist, evaluated by the commit policy in shadow mode,
committed by a human, and applied by the Phase 1 apply function. Every decision is made by a guarded database function;
the engine only drives order and time, and is replaceable (ADR-035).

| Commit | Increment |
|---|---|
| `2115e54` | Plan; ADR-035 engine-neutral workflow driver |
| `19f92c9` | 2-1 Business-day functions, `wf` day boundaries, activation guard (OD-08) |
| `2409c90` | 2-2 Bitemporal group membership, `wf.is_member`, governed membership changes, configuration audit |
| `6f7de5b` | 2-3 Claims (D-12), close rules (D-13), `wf.record_stage_decision` |
| `fefe066` | 2-4 Node-access scope by ancestor walk at the effective date (D-10, D-11) |
| `20f3de4` | 2-5 Policy row lock for the daily cap (D-14) |
| `b30010f` | 2-6 Bridge: decider attribution (D-06), clearance, enrichment items, `requires_workflow` |
| `72bf7d0` | 2-7 Model definitions, four-eyes activation, stage progression |
| `33fcb1e` | 2-8a Submit with a workflow model, urgent flag, governed withdraw |
| `9308ee5`, `8298a6e` | 2-8b Stage decisions, claims, enrichment, instance view, refusals in words; unique operation ids |
| `7fdcdfc` | 2-8c Model and commit-policy administration endpoints |
| `f621347` | 2-9 Worklist: nine views, counts, search, paging |
| `6f610e2` | 2-10a Engine-neutral ports, outbox offsets, relay, in-process driver, contract suite |
| `d928ecb` | 2-10b Camunda adapter (written; run on Camunda deferred) |
| `f2a4f07` | 2-11 Reconciler and resume from database state |
| 2-12 commit | Records, `20_workflow_gaps.sql`, test report, this summary |

## Decisions taken
- Phase 2 plan approved with ADR-035 and the three Camunda dependencies (Camunda 8.7.44 SDK and process test, local image).
- Camunda must stay replaceable (repository owner) → ADR-035 (Accepted).
- Phase order kept (Phase 2 before the UI).
- Camunda contract run deferred to the end of the build (repository owner), with performance testing.
- Audit-Risk review of ADR-021 and ADR-023 skipped for now (OD-18a): merging to `main` needs it or an explicit waiver.

## Patterns introduced or extended (see `docs/architecture/patterns.md`)
- **Ports and adapters for the engine** (P-07, ADR-035): `WorkflowEngine` / `WorkflowSteps`; one contract suite per adapter.
- **Outbox with consumer offsets** (P-06, D-32) and a safety lag.
- **State machine in the database, process manager in the engine** (P-15): the engine never decides.
- **Four-eyes configuration** (P-03): models, policies and group membership.
- **Bitemporal configuration history** (P-01) for group membership; append-only configuration audit in `wf`.
- **Keyset paging** (P-11) for the worklist and admin lists.

## Deviations from the plan and the LLD (all recorded in the LLD as *Built in …* notes)
- 2-8 split into 2-8a, 2-8b and 2-8c (size).
- `mdm.system_setting` moved from V8 to V1 (the V6 day boundaries need it).
- The draft-only guard on change items split into an invoker check and an owner-run version bump, so the bridge can be told apart (ADR-023 exception).
- Approving a membership change applies it (no separate apply function); membership changes cannot be back-dated.
- Conflicting decisions return 422 (ADR-020), not 409.
- The next-stage step reports stages decided while no process listened, so recreated processes resume.
- New error codes: `N1026`, `N1027`, `N2107`, `N2225`, `N2230`–`N2236`; refusal reasons from `wf.why_cannot_act`.
- The worklist performance test deferred with the other performance work.

## Known gaps and technical debt
See `TEST_REPORT.md` → Explicit gaps. Also:
- Camunda 8.7's client cannot query process instances; `isRunning` reads the stored `engine_ref`.
- The relay assumes one worker; a second worker would deliver duplicates, which the engines ignore.
- Camunda licence for self-managed production use and hosting (OD-01c) remain your decisions with Procurement.
- First members of groups and the system actor (`nexus_system`, kind `system_feed`) are created by the database owner.

## What the next phase needs
Phase 3 (steward UI) consumes the Phase 1 and 2 API through `docs/api/openapi.json` (operation ids now explicit). It needs
the UI tooling approved in its plan (ADR-025) and the design-system decisions OD-02 to OD-04.
