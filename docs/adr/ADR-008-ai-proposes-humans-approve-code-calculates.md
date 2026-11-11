# ADR-008: AI proposes, humans approve, code calculates

- **Status:** Proposed
- **Date:** <set when reviewed>
- **Deciders:** <names / roles>
- **Capabilities:** NEW-03, NEW-04

## Context
AI assistance is wanted without weakening controls.

## Decision
AI agents can draft change requests and suggestions only. Approvals are human (or an approved commit policy, ADR-005). Calculations are deterministic. Enforced by database triggers.

## Alternatives considered
- Let AI apply low-risk changes directly.

## Consequences
Clear accountability; AI accuracy is measured before its role grows.
