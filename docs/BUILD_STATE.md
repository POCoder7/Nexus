# Build state

- **Current phase:** 1 — Core write path
- **Step in loop:** Plan (awaiting approval) — `docs/phases/phase-1/PLAN.md`
- **Baseline:** db-test **pass** 35/35 · mvnw verify **pass** 6/6 · UI tests n/a (as of 2026-11-11, commit `d808b01`)
- **Last commit:** see `git log -1`

## Completed phases
| Phase | Gate result | Summary | Date |
|---|---|---|---|
| 0 — Foundation | Pass locally; approved by the repository owner. Gap: CI not yet run on GitHub (OD-11) | `docs/phases/phase-0/SUMMARY.md` | 2026-11-11 |

## Current phase progress
| Increment | Capability | Status | Tests | Notes |
|---|---|---|---|---|
| 1-1 … 1-12 | HIE-01, HIE-02, PRP-01, SEC-01, SEC-02, NEW-01, PROG | Planned | per plan | Plan awaiting approval |
## Decisions awaiting human review
| ADR | Title | Why it needs review |
|---|---|---|
| ADR-005 | Policy-governed straight-through commit | Needs Audit/Risk sign-off before any policy is activated |
| ADR-006 to ADR-008 | Bitemporal model, ownership graph, AI proposes/humans approve | Proposed; awaiting team confirmation |
| ADR-013 to ADR-034 | Design-track decisions | Accepted by the owner; confirmations pending for ADR-014, 021, 023, 026, 027 (Security / Audit-Risk), see `docs/design/OPEN_DECISIONS.md` |


## Open questions for the human
1. Approve the Phase 1 plan (`docs/phases/phase-1/PLAN.md`) and its branch/merge approach.
2. OD-11: create the GitHub remote when ready; CI runs only after a push you approve.
3. OD-18a: Audit-Risk review of ADR-021 before the Phase 1 branch is merged to `main`.

## Scope changes
- **Phase 7 (AI assistance) deferred** by the repository owner on 2026-11-11 (OD-38): design approved; the build goes from Phase 6 to Phase 8. The `BUILD_PROTOCOL.md` phase table is updated in design step 5 (wiring).

## Known gaps, stubs and technical debt
- CI has never run on GitHub (no remote; OD-11).
- Mockito dynamic-agent warning in tests (future JDKs will block it).
- `scripts/check-setup.*` still requires a local `mvn`.
- Schema control gaps and untested guards (D-04 to D-07, D-12 to D-15, D-22, D-29, D-33 in `docs/design/DESIGN_STATE.md`; OD-18).

## Next action
Wait for approval of the Phase 1 plan; then build increments 1-1 to 1-12 on `feature/HIE-02-phase-1-core-write-path`, asking before each commit.
