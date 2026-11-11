# ADR-021: Phase 1 control fixes in `mdm` (OD-18 group 1)

- **Status:** Accepted (repository owner, 2026-11-11); Audit-Risk review required before the migrations are merged (OD-18a). Amended by ADR-023
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** PROG, HIE-02, AUD-01, GOV-12

## Context
The design orient step found control gaps in V1–V6 (`docs/design/DESIGN_STATE.md`). The repository owner decided
(OD-18) to fix them before the first shared environment, editing V1–V6 where the object is defined, one ADR per group,
each fix with pgTAP tests. This ADR covers the gaps on the `mdm` side; the `wf` side is the Phase 2 group.

## Decision
| Gap | Fix | Strengthens |
|---|---|---|
| D-04 forgeable policy approval | ADR-014 roles; decision columns writable only by `nexus_decider` (human basis only) and `nexus_bridge` (ADR-019) | Maker-checker, policy limits |
| D-05 self-declared requester kind | Trigger: `change_request.requester_kind` must equal `app_user.kind` | Human-only decisions; AI requests need a human |
| D-07 mutable items and unguarded status | Draft-only trigger on `change_item`; transition matrix on `change_request.status`; content frozen after draft; `change_item` audited | Maker-checker (what is approved is what is applied) |
| D-29 untraced changes | Facts written only by `apply_change_request`, which always sets actor and request; `nexus_api` has no write access to facts | Audit trail |
| D-36 no delete action | `delete_node` added to `mdm.change_action`, and to the commit-policy hard-limit list | Commit-policy limits |

Every existing guard keeps its rule; none is relaxed. Existing tests keep their assertions; the `01_core_invariants.sql`
maker-checker fixture adds a `submitted` step before approval because the new transition guard requires it (Phase 1 LLD §13).

## Alternatives considered
- **Fix later in V7+:** same result, but leaves the gaps in place while the first features are built on them.
- **Accept the gaps with a recorded reason:** the gaps undermine controls Audit relies on (maker-checker, AI-needs-human, traceability).

## Consequences
- Bulk loads (Phase 4) must also go through change requests (they already must, by the import design).
- The pgTAP suite grows by the cases in the Phase 1 LLD §13 (PROG rows).
