# ADR-013: mdm-api as a modular monolith with ports and adapters

- **Status:** Proposed
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** PROG

## Context
`services/mdm-api` is one Spring Boot service with feature packages (`hierarchy`, `node`, `common`). Phases 1–8 add
change requests, apply, validation, workflow integration, ownership, AI integration and exports. All state is in one
PostgreSQL database, and the strongest controls are database guards. Several external dependencies are undecided
(workflow engine OD-01, identity provider OD-06, AI provider OD-07, object storage OD-16).

## Decision
- Keep one deployable Java service, organised as feature modules under `com.mdm.api.<module>` (`hierarchy`, `node`,
  `changerequest`, `apply`, `validation`, `workflow`, `policy`, `audit`, `ownership`, `export`, `ai`, `security`, `common`).
- Modules call each other only through public service interfaces; each module owns its SQL (P-25).
- External dependencies sit behind ports with at least one deterministic local adapter for tests:
  `ApprovedItemsSource`, `WorkflowGateway`, `RuleEngine`, `DerivationEngine`, `CurrentActor`, `AiProposalPort`,
  `DocumentStore`, `DeliveryTarget` (`docs/architecture/overview.md` §4).
- The workflow worker runs as a separate process from the same codebase (separate Spring profile or artefact) so an
  engine outage does not stop reads or drafting.
- Python stays limited to AI services and analysis tooling (ADR-011), as separate processes behind internal APIs.

## Alternatives considered
- **Microservices per capability area:** independent scaling, but distributed transactions across apply, workflow and
  audit would replace today's single-transaction guarantees; more operations work for a small team.
- **Packages without ports:** simplest, but code would bind to an engine, IdP or AI SDK before those decisions are made.

## Consequences
- One transaction can span request, items, apply, audit and events.
- Module boundaries must be policed by review and an architecture test (planned: ArchUnit-style rule, dependency to approve, or a simple package-import check in the build).
- If a module later needs independent scaling (exports, AI orchestration), its port is the seam to extract it.
