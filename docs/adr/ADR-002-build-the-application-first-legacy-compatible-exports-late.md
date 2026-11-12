# ADR-002: Build the application first; legacy-compatible exports late

- **Status:** Accepted
- **Date:** <set when reviewed>
- **Deciders:** <names / roles>
- **Capabilities:** EXP-01

## Context
Compatible exports only matter at cutover, while visible progress matters for funding and feedback.

## Decision
Sequence: core model, application, workflow, AI features, then exports and parallel run. A thin real-data load stays early, and the downstream-consumer inventory is done in discovery.

## Alternatives considered
- Exports first: proves parity early but delays anything users can see.

## Consequences
Export parity is proven late, so the downstream inventory must be complete early to size the parallel run.
