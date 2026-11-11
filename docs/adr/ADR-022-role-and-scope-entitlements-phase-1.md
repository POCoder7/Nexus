# ADR-022: Role-and-scope entitlements, Phase 1 model

- **Status:** Proposed (Phase 1 LLD)
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** SEC-01, SEC-02 (both Improve, OD-13)

## Context
The API has no authorisation (D-20). The repository owner decided to bring basic RBAC forward to Phase 1 and to treat
SEC-01 and SEC-02 as Improve: a simpler model than DRM's, mapped from DRM's access groups at migration. The identity
provider is open (OD-06).

## Decision
- Six roles as data (`mdm.role`): `VIEWER`, `STEWARD`, `APPROVER`, `WORKFLOW_ADMIN`, `POLICY_ADMIN`, `SYSTEM_ADMIN`;
  permissions per role fixed in code (`Permission` matrix, Phase 1 LLD §3.1).
- Grants (`mdm.user_role`) are bitemporal and scoped: all hierarchies, one hierarchy, or one sub-tree of a hierarchy.
  Nobody can grant a role to themselves (CHECK); only human users hold roles.
- `EntitlementService` checks before every write and decision and filters reads. Maker-checker, separation of duties
  and human-only decisions stay in database guards; entitlements never replace them.
- Identity is resolved behind `CurrentActor`. Until OD-06 is implemented only a development adapter exists, active in
  `local` and `test` profiles; the API refuses to start in any other profile without a real adapter.
- Grants change by migration or `SYSTEM_ADMIN` SQL in Phase 1; a governed grant API is Phase 5.

## Alternatives considered
- **Reproduce DRM's access groups exactly (Parity):** more complex; rejected by the Improve decision.
- **PostgreSQL row-level security for reads:** strong, but awkward for recursive sub-tree scopes with pooled connections; revisit in Phase 9.
- **Wait for the identity provider:** leaves write endpoints unprotected while they are built.

## Consequences
- Every endpoint has a parameterised role × endpoint test from the start.
- Property-level access (SEC-03) and object sharing (SEC-04) are added in Phase 5 without changing this model.
- The API cannot run in a shared environment until OD-06 is implemented.
