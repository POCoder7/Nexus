# ADR-017: Workflow orchestration engine

- **Status:** Accepted (repository owner, 2026-11-11): **in-house worker behind `WorkflowGateway` for Phase 2**; switch to Temporal if the platform team already runs it (OD-01a)
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** GOV-01 to GOV-09, GOV-12, GOV-13

## Context
V4 and V6 hold workflow configuration, state and every control in the database. Stage activation, claims with expiry,
push-back iterations, SLA escalation and notifications need a process manager (P-15). ADR-011 names Temporal or
Camunda as candidates "to be chosen in a later ADR". Whatever runs must call the `wf` functions and never bypass the guards.

## Options
| | Temporal | Camunda (7 or 8) | In-house worker (Spring + outbox polling) |
|---|---|---|---|
| Fit with DB-held state | Workflows hold only ids and call `wf` functions as activities | BPMN process mirrors stages; risk of duplicating state in two places | Native: reads the outbox, calls `wf` functions |
| Timers, retries, escalation | Strong, durable | Strong (BPMN timers) | Must build (scheduled scan of `due_at`, `claim_expires_at`) |
| Visual model for business users | No | Yes (BPMN), but DRG models are already data in `wf.workflow_model` | No |
| Operations | Temporal cluster (or managed) | Camunda engine + DB (or SaaS) | None beyond mdm-api |
| Licensing | MIT (server); managed service paid | Camunda 8 self-managed licence terms need review; 7 CE end of life | None |
| Effort for Phase 2 | Medium | Medium–high | Low–medium |

## Recommendation
Start Phase 2 with the **in-house worker** behind `WorkflowGateway`, because the models, stages and guards already live
in `wf` and the remaining orchestration (activate, claim expiry, push-back, SLA scan) is small. Choose Temporal if the
platform team already runs it or if escalation and long-running timers grow beyond a scheduled scan. Camunda only
if the organisation requires BPMN modelling for governance.

## What changes under each option
- **In-house:** a `WorkflowWorker` module polling `wf.event_outbox` (ADR-016) and a scheduler for due dates; no new infrastructure.
- **Temporal:** a `TemporalWorkflowGateway` adapter, one workflow type per instance, activities = `wf` functions; `wf.workflow_instance.engine_ref` = workflow id; Temporal SDK dependency and cluster.
- **Camunda:** a `CamundaWorkflowGateway` adapter, BPMN generated from `wf.workflow_model`; external task workers call `wf` functions; engine database and licence.
The database schema, guards and `ApplyService` are identical in all three.

## Consequences
Phase 2 LLD is written against `WorkflowGateway` and marks engine-specific parts as conditional on this decision.
