# ADR-015: API conventions — keyset paging, Problem Details, concurrency, idempotency, versioning

- **Status:** Proposed
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** PROG, HIE-12, ADM-02

## Context
The read API exists (`/api/v1/hierarchies`, `/children`, `/nodes/{id}`). It returns bare arrays, pages children by
offset, leaves the hierarchy list unpaged (D-17), maps only 404 and 400 (D-21) and has no write endpoints yet.
Phase 1 adds commands; Phase 3 generates the Angular client from OpenAPI.

## Decision
- **Paging:** every list returns `{ "items": [...], "nextCursor": string|null }`; `limit` default 200, max
  `mdm.api.max-page-size` (1000); opaque keyset cursors. Children sort by `(sort_order, node_name, child_node_id)`.
- **Errors:** RFC 9457 Problem Details with `type = urn:nexus:problem:<code>`, `correlationId`, and `errors[]`; the
  mapping table in `docs/architecture/overview.md` §9.
- **Concurrency:** `ETag` / `If-Match` on mutable resources; `412` on mismatch.
- **Idempotency:** `Idempotency-Key` header on every creating or transitioning `POST`; replay returns the stored response.
- **Time parameters:** `asOf` (ISO date, business) and `recordedAsOf` (ISO instant, UTC) on every read.
- **Versioning:** major version in the path; additive changes in place; breaking changes in a new major version.
  Because v1 has no external consumers yet, the switch to the paging envelope happens within v1 in Phase 1.
- **Contract:** OpenAPI generated from code and published per build (generator library needs approval).

## Alternatives considered
- **Offset paging (current):** simple, but slow and unstable on large, changing sibling sets.
- **GraphQL:** flexible reads, but harder to page bitemporal trees, cache and authorise per field; ADM-02 mentions "REST/GraphQL" — REST chosen for v1, GraphQL can be added for read-only integrations later.
- **Bare arrays with `Link` headers:** less discoverable for generated clients.

## Consequences
- `HierarchyController.children` and `list` change response shape in Phase 1 (tests in `HierarchyApiTest` updated, not weakened).
- Clients cannot jump to page N; the UI uses "Show next 200" and virtual scroll (UI_STANDARD §5).
- An idempotency-key table and a `row_version` column on `mdm.change_request` are needed (Phase 1 LLD data design).
