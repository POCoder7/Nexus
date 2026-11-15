# ADR-041: Build property queries before governed grants and sub-tree read filtering

- **Status:** Accepted (repository owner, 2026-11-15: "lets build queries first")
- **Date:** 2026-11-15
- **Deciders:** Repository owner
- **Capabilities:** QRY-01, SEC-01, SEC-02, PRP-06, VER-04
- **Amends:** the Phase 5 plan's order (Phase 5 LLD §17.14, `docs/phases/phase-5/PLAN.md`)

## Context
The approved Phase 5 order is 5-1 to 5-5, then 5-9 to 5-16. 5-4 governs role grants (SEC-01). 5-5 filters every read
by the reader's sub-tree scope (SEC-02). The LLD puts 5-5 before the new read endpoints (compares, queries, search) "so
the new read endpoints are filtered from their first commit".

After reviewing Nexus against DRM (`docs/DRM_COMPARISON.md`), the repository owner asked for property queries (QRY-01)
next. Queries are 5-9 (shared foundations) plus 5-13a (backend) and 5-13b (UI).

Two facts decide whether that is safe:
- **Today every read is filtered by hierarchy only.** A user with a sub-tree scope can already read every node of a
  hierarchy they can read, through children, node detail and search. A query endpoint filtered the same way exposes
  nothing those endpoints do not already show.
- **No CEL-derived property can exist before 5-11.** The CEL engine is 5-10, and the governed action that defines a CEL
  formula is 5-11. So a query can name no CEL-derived property before then.

## Decision
1. **Order.** Build 5-9, 5-13a and 5-13b now, then return to 5-4 and 5-5, then 5-10 to 5-12 and 5-14 to 5-16. Nothing
   in the design changes; only the order and the two points below do.
2. **Read scope until 5-5.** The query runner filters candidates by the reader's readable hierarchies, the same rule
   every read follows today. 5-5 adds sub-tree filtering to the query endpoints with the others: its negative matrix
   gains `/queries/run` and `/queries/{id}/run`. Until 5-5, the 5-13a test "a shared query run by another user shows
   only that user's scope" is proven at hierarchy level (a user who cannot read the hierarchy gets nothing). Its
   sub-tree case moves to 5-5.
3. **CEL conditions until 5-10 and 5-11.** The planner keeps the `java` class of §17.5.2 behind a port with no
   implementation. Since no CEL-derived property can exist, no condition falls into that class. The 5-13a test "a CEL
   condition" moves to 5-11, when the first CEL property can be defined.

## Alternatives considered
- **Keep the approved order** (5-4 and 5-5 first). Nothing to record, but the owner wants queries now.
- **Build 5-5 together with queries.** Gives sub-tree filtering from the start, but 5-5 covers nine endpoints and the
  tree UI, which doubles the increment. No exposure is avoided, because the other read endpoints are unfiltered at
  sub-tree level anyway.

## Consequences
- SEC-01 and SEC-02 arrive later, so grants still bypass maker-checker for a while: the database owner bootstraps them,
  as today.
- 5-5's scope grows by two endpoints.
- The Phase 5 gate is unchanged: every test still has to pass before it.
