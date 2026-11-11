# ADR-024: Camunda 8 integration — generic process, outbox-driven start, message-correlated decisions

- **Status:** Proposed (Phase 2 LLD)
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** GOV-01, GOV-02, GOV-07, GOV-09, GOV-12

## Context
ADR-017 chose Camunda 8 to orchestrate, with the database holding state and guards. The integration must not create a
second source of truth, must survive engine outages, and must keep personal data out of the engine if SaaS is used (OD-01c).

## Decision
- **One generic BPMN process `nexus-request`**, versioned with the code, loops over the stages of the pinned
  `wf.workflow_model` version. DRG models remain data in `wf`.
- **The API never calls Camunda.** It writes `wf` state and `wf.event_outbox` in its transaction. The worker's
  `OutboxRelay` (per-consumer offset, ADR-016) creates process instances (business key = `instanceId`) and publishes
  messages (`stage-decided`, `request-withdrawn`, message id = `event_id`).
- **Job workers call guarded `wf` / `mdm` functions only:** `nexus.next-stage` → `wf.advance_instance`,
  `nexus.complete-stage` → `wf.complete_stage`, `nexus.evaluate-policy` → validation + `wf.apply_commit_policy`,
  `nexus.close` → `wf.close_instance`, `nexus.apply` → `mdm.apply_change_request`. Every function is idempotent.
- **Approvals are not Camunda user tasks.** Humans act through the Nexus worklist; `wf.can_act` stays the only permission check.
- **Process variables are identifiers only** (`instanceId`, `changeRequestId`, `instanceStageId`, `stageType`, `dueAt`, `outcome`, `actorId`).
- **Reconciliation:** an `EngineReconciler` recreates a process for any `in_flight` instance without one; the generic
  process resumes from database state.
- **Testing:** Camunda's process-testing library (Testcontainers-based) in CI; a fake `EngineClient` for relay unit tests.

## Alternatives considered
- **One BPMN per DRG model:** visual per model, but duplicates `wf.workflow_model` and needs deployments for model changes.
- **API calls Camunda synchronously:** dual write between the database and the engine.
- **Camunda user tasks and Tasklist:** a second permission model.
- **Temporal / in-house worker:** not chosen (ADR-017).

## Consequences
- New dependencies to approve in the Phase 2 plan: the Camunda 8 Java client or Spring SDK, the process-testing library, and a Camunda image for local development.
- A few seconds of latency between a decision and the next stage (relay poll + safety lag).
- Camunda Operate shows the generic process; per-model stage names come from the Nexus instance view.
