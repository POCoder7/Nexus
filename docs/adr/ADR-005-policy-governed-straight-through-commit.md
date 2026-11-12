# ADR-005: Policy-governed straight-through commit

- **Status:** Proposed
- **Date:** <set when reviewed>
- **Deciders:** <names / roles>
- **Capabilities:** GOV-12

## Context
Some low-risk requests in the legacy product commit with no human approver, as a side effect of configuration rather than an explicit control. Requiring a human for every routine change at high volume risks rubber-stamping.

## Decision
Allow auto-commit only for low-risk requests under versioned commit policies approved by a separate approver group. Hard limits (no moves, removals, inactivations, ownership changes, protected properties, AI-originated requests); validations must pass; freeze windows; daily caps; one-way kill switch; shadow mode before activation; sampled post-commit review. Implemented in V6.

## Alternatives considered
- Human approval for everything.
- Keep the legacy no-assignee behaviour.

## Consequences
Needs Audit/Risk sign-off before any policy is activated. Shadow-mode evidence supports that decision.
