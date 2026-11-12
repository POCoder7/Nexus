# ADR-029: Role grants as governed change actions

- **Status:** Accepted (repository owner, 2026-11-11)
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** SEC-01, SEC-02 (Improve)

## Context
Phase 1 (ADR-022) lets role grants change only by migration or SQL by a `SYSTEM_ADMIN` (A-7). Access to master data is a
control; changes to it need the same maker-checker and audit as data changes.

## Decision
- New change actions `grant_role` and `revoke_role`; apply writes `mdm.user_role` bitemporally.
- A `SYSTEM_ADMIN` proposes; a different `SYSTEM_ADMIN` decides (maker-checker trigger); both actions are on the commit-policy hard-limit list.
- The Phase 1 SQL path is removed by revoking `INSERT`/`UPDATE` on `mdm.user_role` from every application role except `nexus_apply`.
- DRM access groups migrate as a load run of `grant_role` items (ADR-026); unmappable rules are reported, not approximated.

## Alternatives considered
- **Direct admin edits with an audit trail:** detective only; no second person.
- **Group sync from the identity provider only:** right for "who is a steward", not for sub-tree scopes; can be added in Phase 9 as a source of proposals.

## Consequences
- Grant changes appear in the worklist like any request; emergency access needs a documented break-glass procedure (Phase 9 runbooks).
