# ADR-043: Build transaction history and request history (AUD-01, AUD-02) ahead of the Phase 5 order

- **Status:** Accepted (repository owner, 2026-11-19: "Now lets implement Audit functionality as in DRM",
  then "yes" to designing it now). The design, Phase 5 LLD §18.1 to §18.9, was approved with C-1 to C-5 the same day
  ("Approved", OD-50).
- **Date:** 2026-11-19
- **Deciders:** Repository owner
- **Capabilities:** AUD-01, AUD-02 (decided by ADR-039 D2: Parity, Phase 5)
- **Amends:** the Phase 5 order (BUILD_STATE "Next action"; Phase 5 LLD §17.14)

## Context
ADR-039 decided AUD-01 (a paged query over `mdm.audit_log`) and AUD-02 (a read API and a request-page panel over the
request's history) for Phase 5. The plan builds them after 5-16, in the §18 increments, once LLD §18 has been written for
all 21 ADR-039 rows and reviewed.

The repository owner asked for audit as in DRM now. Three facts make it safe to take these two rows first:
- **The history is already recorded.** `mdm.audit_log` (append-only, written only by its trigger), the bitemporal facts,
  `wf.instance_action`, `wf.policy_evaluation` and `wf.config_audit` exist and are append-only. AUD-01 and AUD-02 only
  read them.
- **Nothing they read depends on later increments.** The CEL formulas (5-10 to 5-12) and compares (5-14 to 5-16) write
  through the same apply path and the same audit trigger, so their changes appear in the history when they arrive.
- **Read filtering is the same as every other read until 5-5.** As ADR-041 recorded for queries, every read is filtered
  by hierarchy until 5-5 adds sub-tree scope. The audit search follows that rule and joins 5-5's negative matrix.

## Decision
1. **Order.** Write LLD §18 for AUD-01 and AUD-02 only (§18.1 to §18.9), stop for review, then build them as 5-17a to
   5-17c. The other 19 ADR-039 rows keep their place: §18 gains their sections later, before their build, as planned.
2. **Scope.** Only what ADR-039 D2 decided: the transaction-history search with a page, and the request-history API with
   a request-page panel. CSV download of the search is EXP-05 (Phase 8), which reuses the same query. Job and export run
   history (AUD-03) stays in Phase 8; retention (AUD-04) stays with Audit-Risk (OD-25), and nothing is deleted.
3. **Read scope.** Hierarchy-level until 5-5, as for every read; 5-5 adds `/audit` and `/change-requests/{id}/history`
   to its negative matrix.

## Alternatives considered
- **Keep the order** (after 5-16 and the full §18). Nothing to record, but the owner wants audit now.
- **Write all of §18 first.** It covers 21 rows and would delay audit by the whole design review of unrelated rows.

## Consequences
- 5-17a to 5-17c are added to the Phase 5 build list; 5-5 grows by two endpoints.
- The Phase 5 gate is unchanged.
