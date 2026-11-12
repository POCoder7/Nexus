# ADR-006: Bitemporal data model

- **Status:** Proposed
- **Date:** <set when reviewed>
- **Deciders:** <names / roles>
- **Capabilities:** VER-01, VER-03

## Context
The legacy product's versions are full copies; as-of views require rebuilding from history; audit needs "what did we know, when".

## Decision
Every fact carries valid time and recorded time. Versions are named (business date, recorded time) slices. Rows are never updated or deleted, only closed and superseded.

## Alternatives considered
- Physical version copies.
- Current state plus audit log only.

## Consequences
Any date is queryable; finalized versions are immutable; no per-period copies. Queries are more complex and need care with indexing.
