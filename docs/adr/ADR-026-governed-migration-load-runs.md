# ADR-026: Governed migration load runs; `add_hierarchy` and `update_node` actions

- **Status:** Accepted (repository owner, 2026-11-11), including the Phase 1 amendment. The approval model (OD-29) remains an Audit-Risk decision and is **not** decided here
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** PROG, HIE-01, IMP-01 (outline), ADM-04 (outline)

## Context
The DRM baseline is ~500 000 nodes per large hierarchy and millions of property values. Writing it directly would bypass
change requests, guards and audit for the most important data set. Through change requests it is ~700 requests of 5 000
items per large hierarchy, each needing a human decision under maker-checker. Phase 1 also lacks a change action to create
a hierarchy and its top node, and a handler for `update_node` (renames across versions).

## Decision
- All migrated facts go through change requests (requester: the system actor) and `mdm.apply_change_request`.
- Requests are grouped in an `mdm.load_run` with a manifest hash; a human operator prepares it; a **different** human approves it.
- Phase 1 is amended: `add_hierarchy` (creates the hierarchy and its top node) and an `update_node` handler (name, description); both on the commit-policy hard-limit list.
- New role `nexus_loader` writes `mdm_stage` and calls `mdm` functions only.

## Options for approving a load run (OD-29)
| | A: one human approval of the run, applied to every listed request | B: a human decides each request | C: sampled approval with a reconciliation sign-off |
|---|---|---|---|
| How | Approver reviews counts, profile findings and dry-run results, then approves the manifest hash; the API records a `human_review` decision by that person on each request | Approver opens every request (~700 per large hierarchy) | Approver reviews a random sample plus the reconciliation report; remaining requests decided under the run approval |
| Control strength | Each decision names a real human who explicitly approved that exact manifest | Strongest per request; impractical at volume | Weaker than A on paper |
| Effort | Low | Very high | Low |
**Recommendation:** A, with the manifest hash in each decision note, an Audit-Risk review of the first run, and B for any
run under `LOAD_SMALL_RUN_ITEMS` (500) items.

## Alternatives considered
- **Direct `COPY` into `mdm` tables:** fastest; bypasses every control. Rejected.
- **A bulk-apply mode that disables guards:** contradicts CLAUDE.md rule 1. Rejected.

## Consequences
- Migration speed is bounded by per-row guards; measured in the Phase 4 baseline.
- The same converter serves later user imports (IMP-01, IMP-02, GOV-10) once decided.
