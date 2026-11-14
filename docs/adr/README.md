# Architecture decision records

| ADR | Title | Status |
|---|---|---|
| ADR-001 | Build a custom AI-enabled MDM to replace the legacy product | Accepted |
| ADR-002 | Build the application first; legacy-compatible exports late | Accepted |
| ADR-003 | Workflow as a separate layer with a single bridge | Accepted |
| ADR-004 | Retire blending | Accepted |
| ADR-005 | Policy-governed straight-through commit | Proposed |
| ADR-006 | Bitemporal data model | Proposed |
| ADR-007 | Ownership graph separate from hierarchies | Proposed |
| ADR-008 | AI proposes, humans approve, code calculates | Proposed |
| ADR-009 | Golden testing against the legacy system as the parity standard | Accepted |
| ADR-010 | Track the programme in Excel for now | Accepted |
| ADR-011 | Technology stack | Accepted |
| ADR-012 | UI framework — Angular with the organisation's design system | Accepted |
| ADR-013 | mdm-api as a modular monolith with ports and adapters | Accepted |
| ADR-014 | Least-privilege database roles per layer | Accepted (Security, Audit-Risk confirmation pending) |
| ADR-015 | API conventions — keyset paging, Problem Details, concurrency, idempotency, versioning | Accepted |
| ADR-016 | Transactional outboxes with per-consumer offsets | Accepted |
| ADR-017 | Workflow orchestration engine — Camunda 8 | Accepted (hosting fact open, OD-01c) |
| ADR-018 | Time handling — business time zone `America/New_York`, UTC recorded time | Accepted |
| ADR-019 | Apply and decide as security-definer SQL functions; bridge-written clearance | Accepted |
| ADR-020 | Database error codes for guards | Accepted |
| ADR-021 | Phase 1 control fixes in `mdm` | Accepted (Audit-Risk review pending) |
| ADR-022 | Role-and-scope entitlements, Phase 1 model | Accepted |
| ADR-023 | Phase 2 control fixes in `wf` and the bridge | Accepted (Audit-Risk review pending) |
| ADR-024 | Camunda 8 integration | Accepted |
| ADR-025 | UI toolchain: tests, stories, accessibility checks, style lint, generated API client | Accepted |
| ADR-026 | Governed migration load runs; `add_hierarchy` and `update_node` actions | Accepted (Audit-Risk confirmation pending, OD-29a) |
| ADR-027 | Golden datasets: masking and storage | Accepted (Security/Audit-Risk confirmation pending) |
| ADR-028 | Sandboxes as draft requests with a trial-apply overlay | Accepted |
| ADR-029 | Role grants as governed change actions | Accepted |
| ADR-030 | Ownership calculation: exact rational solve, methodology per regime, recorded determinations | Accepted (OD-34, OD-35 open) |
| ADR-031 | AI service boundary, model governance, prompted-by maker-checker | Accepted (implementation deferred, OD-38) |
| ADR-032 | Governed export profile versions, streaming export runs, reconciliation review | Accepted (OD-39, OD-40 open) |
| ADR-033 | Authentication: OIDC resource server; identities mapped, roles in Nexus | Accepted (IdP open, OD-06) |
| ADR-034 | Observability: structured logs, Micrometer metrics, OpenTelemetry traces | Accepted |
| ADR-035 | Engine-neutral workflow driver: Camunda behind a port, with an in-process reference driver | Accepted |
| ADR-036 | Property edit rights by category | Accepted (Security confirmation pending with ADR-022) |
| ADR-037 | Versions: create, copy and status lifecycle | Accepted (OD-45); D4 Audit-Risk confirmation pending (OD-45a) |
| ADR-038 | Imports, derived properties, queries and compares, scenarios and exports | Accepted (OD-46); D3 amended: Phase 5 before Phase 4 |
| ADR-039 | Decisions for the remaining undecided capabilities (Phases 1, 2 and 5) | Accepted (OD-47) |

New decisions: copy `ADR_TEMPLATE.md`, take the next number, open a PR.
