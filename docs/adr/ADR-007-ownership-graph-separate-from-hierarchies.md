# ADR-007: Ownership graph separate from hierarchies

- **Status:** Proposed
- **Date:** <set when reviewed>
- **Deciders:** <names / roles>
- **Capabilities:** NEW-02

## Context
Beneficial ownership needs weighted, many-to-many, evidence-linked edges; reporting hierarchies are curated trees.

## Decision
Store ownership and control edges in their own table, sharing node identity with hierarchies.

## Alternatives considered
- Model ownership as additional hierarchies.

## Consequences
Clean ownership maths and evidence handling; two structures referencing the same entities must stay consistent.
