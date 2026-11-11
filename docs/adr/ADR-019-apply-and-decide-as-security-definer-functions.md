# ADR-019: Apply and decide as security-definer SQL functions; bridge-written clearance

- **Status:** Proposed (Phase 1 LLD)
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** HIE-02, PRP-01, GOV-12, AUD-01, PROG

## Context
The first version of the overview put apply logic in Java behind an `ApprovedItemsSource` port that read
`wf_bridge.v_items_to_apply`. Accepted ADR-014 removes write access to facts and decision columns from the application
login. If apply ran in Java, the application login would need write access to every fact table, so any API defect could
write facts without an approved request. The `mdm` schema also cannot read `wf_bridge` (layer rule), so a SQL apply
function cannot use `v_items_to_apply`.

## Decision
- `mdm.apply_change_request(cr, actor)` and `mdm.validate_change_request(cr, as_of)` are `SECURITY DEFINER` functions
  owned by `nexus_apply`, the only role with write access to fact tables. Apply checks `status = 'approved'` itself.
- `mdm.decide_change_request`, `mdm.submit_change_request`, `mdm.withdraw_change_request` are `SECURITY DEFINER`
  functions owned by `nexus_decider`, which may set only `decision_basis = 'human_review'`. Policy-based decisions stay with `wf_bridge` (`nexus_bridge`).
- Which items a workflow committed is recorded in `mdm.change_item_clearance`, defined in `mdm` and written only by the
  bridge; `mdm.change_request.governed_by_workflow` (set by the bridge) tells apply whether to use only cleared items or all items.
- Java `ApplyService` orchestrates (call, retry, sweep, error mapping); it contains no item logic.
- Amends ADR-014: adds roles `nexus_apply` and `nexus_decider` as owners, the clearance table, and `INSERT` on `mdm.node` for `nexus_apply` (identity allocation).

## Alternatives considered
- **Apply in Java with write access to facts (overview v1, P-09 first version):** easier to unit-test in Java, but the application login could write facts directly; rejected.
- **Apply in Java on a separate login used only by `ApplyService`:** same process, same credentials store; weaker separation for little gain.
- **`mdm` reads `wf_bridge.v_items_to_apply`:** breaks the layer rule (CLAUDE.md rule 3).

## Consequences
- The strongest invariants (only approved requests change facts; decisions are human unless the bridge records a policy) hold for every client of the database.
- Item handlers are PL/pgSQL, tested with pgTAP; Java tests cover orchestration and error mapping.
- `SECURITY DEFINER` functions need fixed `search_path`, schema-qualified bodies and review as high-value code.
- `docs/architecture/overview.md` §4/§6 and `patterns.md` P-09 are updated to match.
