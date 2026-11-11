# ADR-017: Workflow orchestration engine

- **Status:** Accepted (repository owner, 2026-11-11): **Camunda**. Superseded part: the earlier recommendation of an
  in-house worker for Phase 2. **Open:** edition and hosting (OD-01b, options below)
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** GOV-01 to GOV-09, GOV-12, GOV-13

## Context
V4 and V6 hold workflow configuration, state and every control in the database. Stage activation, claims with expiry,
push-back iterations, SLA escalation and notifications need a process manager (P-15). ADR-011 named Temporal or
Camunda as candidates. The repository owner chose Camunda. Whatever runs must call the `wf` functions and never bypass the guards.

## Decision
- **Camunda orchestrates; the database decides.** Camunda drives timers, escalations, notifications and stage
  progression. Every state change is a call to a `wf` SQL function, whose guards stay authoritative (separation of duties,
  human-only decisions, node access, commit-policy limits). Camunda never writes `wf` or `mdm` tables directly.
- **One generic BPMN process, not one per DRG model** (recommended, confirm in the Phase 2 LLD review). The process
  `nexus-request` loops over the stages of the pinned `wf.workflow_model` version: evaluate condition / split → activate
  stage → wait for decisions (message correlation) or SLA timer → outcome (next stage, push back, reject) → commit
  policy evaluation → close. DRG models stay data in `wf.workflow_model`, so there is one source of truth and models
  change without BPMN deployments.
- **Integration through a `WorkflowGateway` port** with a `CamundaWorkflowGateway` adapter; job workers live in the
  workflow worker process (ADR-013). `wf.workflow_instance.engine_ref` stores the Camunda process instance key.
- Human tasks are **not** Camunda user tasks: the worklist stays `wf.worklist()` (GOV-13), so authorisation is checked in
  one place. Camunda waits on a message that the API publishes after a guarded decision commits.

## Open: edition and hosting (OD-01b)
| | Camunda 8 SaaS | Camunda 8 self-managed | Camunda 7 (embedded or remote engine) |
|---|---|---|---|
| Engine | Zeebe (cloud) | Zeebe on the organisation's platform | Java engine on its own database |
| Operations | Vendor-run | Platform team runs Zeebe, its exporters and Operate | Light, but another database |
| Data residency | Process variables leave the network (keep them to ids only) | Inside the network | Inside the network |
| Licensing | Subscription | Production licence terms to confirm with the vendor and procurement | Community edition end of life announced; enterprise support needed for production — confirm |
| Fit with this design | Good (ids only in variables) | Good | Good, but a dated line to start a new system on |

**Recommendation:** Camunda 8, self-managed if the platform team already runs it (or will), otherwise SaaS with process
variables limited to identifiers (no node names, property values or personal data). Avoid starting on Camunda 7.

## Alternatives considered
- **In-house worker** (earlier recommendation): least infrastructure; superseded by the owner's choice of Camunda.
- **Temporal:** strong timers and retries, no BPMN; not chosen.
- **One BPMN per DRG model:** visual per model, but duplicates `wf.workflow_model` and needs a deployment for every model change.

## Consequences
- Phase 2 adds the Camunda client library (dependency to approve in the Phase 2 plan) and a worker process.
- Local development and CI need an engine: Camunda's test support or a container (Testcontainers), decided in the Phase 2 LLD.
- The database schema, guards and `mdm.apply_change_request` are identical whichever edition is chosen.
