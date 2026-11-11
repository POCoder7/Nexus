# ADR-023: Phase 2 control fixes in `wf` and the bridge (OD-18 group 2)

- **Status:** Proposed — needs Audit-Risk review before the migrations are merged (OD-18a)
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** PROG, GOV-01, GOV-02, GOV-12, GOV-13

## Context
OD-18 (decided) fixes the schema control gaps before the first shared environment. ADR-021 covered `mdm`; this ADR
covers `wf` and `wf_bridge`. Design detail: Phase 2 LLD §4.

## Decision
| Gap | Fix | Strengthens |
|---|---|---|
| D-06 decider attribution after splits | Bridge takes the decider from committed instances only; clearance rows for their items | Audit trail, maker-checker evidence |
| D-12 unguarded claims | Claim guard: claimant is human and could act on the stage | Human-only decisions |
| D-13 unauthorised reject / withdraw | Reject only with a rejecting stage decision, by that decider; withdraw only by requester or submitter | Maker-checker |
| D-14 daily-cap race | Lock the policy row during evaluation | Commit-policy limits |
| D-15 kill-switch membership date | One `wf.is_member` used by every membership check | Commit-policy limits |
| D-33 group membership not historised | Bitemporal `wf.user_group_member`; `wf.config_audit` for workflow configuration | Separation of duties evidence |
| D-10 / D-11 scope cost and dates | `items_in_scope` by ancestor walk at the request's `effective_from`; same rule, proven equal by test | Node-access control at the right date |
| ADR-018 days | Caps, sampling and re-certification use the business day in `America/New_York` from an owner-only setting | Commit-policy limits |
| OD-08 | Approving a policy in `active` mode requires an owner-only setting, set after Audit-Risk sign-off | STP governance |
| GOV-01 | Model activation by an administrator other than the creator | Maker-checker on configuration |
| Enrichment (amends ADR-021) | `mdm.change_item` accepts inserts while `in_review` only from `wf_bridge.add_enrichment_item`, which checks `can_act` and the task's allowed actions | Keeps "frozen after submit" except through the guarded enrich path |

No existing rule is relaxed. All 17 assertions in `02_workflow_invariants.sql` keep passing unchanged.

## Alternatives considered
- **Fix later in V10+:** leaves the gaps while governance is being built on them.
- **Enforce in the worker only:** bypassable by any other client of the database.

## Consequences
- More pgTAP coverage (Phase 2 LLD §13 PROG rows), including the concurrency test for the cap.
- Workflow configuration changes become auditable without `wf` writing `mdm`.
