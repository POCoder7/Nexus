# ADR-035: Engine-neutral workflow driver — Camunda behind a port, with an in-process reference driver

- **Status:** Proposed (raised in the Phase 2 plan, 2026-11-11, after the repository owner asked that Camunda stay replaceable)
- **Date:** 2026-11-11
- **Deciders:** repository owner
- **Capabilities:** GOV-01, GOV-02, GOV-12, PROG
- **Amends:** ADR-017 (integration detail), ADR-024 (where the job logic lives); neither decision is reversed

## Context
ADR-017 chose Camunda 8 and ADR-024 kept the API away from it: the database holds state and every guard, the API writes
events to `wf.event_outbox`, and a worker relays them to Camunda, whose job workers call guarded `wf` functions. That
already keeps the decisions in Nexus. Three couplings remain in the design:

1. The worker's logic (next stage, complete stage, evaluate policy, close, apply) is written as Camunda job handlers, so a
   different engine would mean rewriting it.
2. The relay and reconciler talk to the Camunda client directly.
3. Every workflow test needs the Camunda test engine, so nothing shows that another engine could run the same process,
   and the default build depends on a heavy container.

The repository owner asked that Camunda stay replaceable later. Licence terms for self-managed Camunda 8 (OD-01c) and
hosting are also still open, which makes an exit path worth having.

## Decision
1. **Two ports in the worker, both engine-neutral:**
   - `WorkflowEngine` (Nexus → engine): `startProcess(instanceId, changeRequestId)`, `publish(EngineMessage)` (for
     `stage-decided` and `request-withdrawn`, with the outbox `event_id` as the message id), `isRunning(instanceId)`, `deploy()`.
   - `WorkflowSteps` (engine → Nexus): `nextStage(instanceId)`, `completeStage(instanceStageId)`, `evaluatePolicy(instanceId)`,
     `close(instanceId, outcome, actorId)`, `apply(changeRequestId, actorId)`. Each is one guarded, idempotent database call,
     exactly the ADR-024 job list. All workflow behaviour lives here, not in an adapter.
2. **`OutboxRelay` and `EngineReconciler` use only `WorkflowEngine`.**
3. **Adapters, chosen by `mdm.workflow.engine`:**
   - `camunda`: the generic BPMN `nexus-request` plus thin job adapters that map job variables to `WorkflowSteps` calls,
     in the package `com.mdm.api.workflow.engine.camunda`. It is the only package that may import Camunda classes, and a
     test enforces that.
   - `inprocess`: a reference driver in the worker that runs the same generic process loop (ADR-024 §6.2) in Java,
     driven by the outbox. It is used by the default build and CI, so every workflow scenario runs without Camunda, and it
     shows that the process does not depend on the engine.
4. **One contract suite** (the same scenarios: add-leaf end to end, enrichment, rejection, withdrawal, policy in shadow
   mode, reconciler recovery) runs against both adapters. The Camunda run is tagged `camunda` and kept out of the default
   build. It runs with `-Dcamunda` and later in CI, once you approve that CI change.
5. **Engine state stays opaque:** `wf.workflow_instance.engine_ref` is text; no `wf` or `mdm` object names an engine.

Replacing Camunda later means writing one adapter (`WorkflowEngine` plus the binding of its jobs or activities to
`WorkflowSteps`) and passing the contract suite. Nothing changes in the database, the API, the guards or the steps.

## Alternatives considered
- **Camunda adapter only (ADR-024 as written).** Simpler, but the logic would sit in job handlers and nothing would prove
  replaceability; every workflow test would need the Camunda container. Rejected given the requirement.
- **An abstraction over BPMN itself, for example generating BPMN for any engine.** Over-engineered: the generic process is
  one small loop, and the models are data in `wf`, not BPMN.
- **Drop Camunda and use only the in-process driver (the earlier in-house recommendation).** Contradicts the accepted
  ADR-017; the timers, escalation and operations tooling planned for GOV-07 and GOV-08 come from the engine. Kept only as
  the reference driver and fallback.

## Consequences
- The default build and CI run all workflow behaviour on the in-process driver: they are faster and need no Camunda container.
- The process loop exists twice, as BPMN and as Java. The contract suite is what keeps them equal, and the BPMN stays minimal
  (a loop with waits; no business logic).
- Timers and escalation (GOV-07, outline only in Phase 2) will need an equivalent in each adapter when they are built.
- The in-process driver must not become a second production engine by drift: it is a supported fallback only if you decide so later.
- One extra test enforces the package boundary (no `io.camunda` import outside `…engine.camunda`).
