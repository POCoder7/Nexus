# ADR-009: Golden testing against the legacy system as the parity standard

- **Status:** Proposed
- **Date:** <set when reviewed>
- **Deciders:** <names / roles>
- **Capabilities:** ALL

## Context
Parity requirements need objective proof, and the same comparison is needed for the parallel run.

## Decision
Capture legacy outputs (exports, inherited and derived values, validation results) for masked datasets and compare automatically in CI.

## Alternatives considered
- Manual user acceptance testing only.

## Consequences
Objective progress measure; requires capturing legacy outputs early, inside the organisation's network.
