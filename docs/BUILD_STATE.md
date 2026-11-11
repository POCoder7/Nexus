# Build state

- **Current phase:** 0 — Foundation
- **Step in loop:** Phase 0 approved 2026-11-11. Build paused for step B (design track); Phase 1 starts only after its LLD is approved
- **Baseline:** db-test **pass** 35/35 (PowerShell and Bash) · mvnw verify **pass** 6/6 (Windows and Bash) · UI tests n/a (as of 2026-11-11)
- **Last commit:** see `git log -1` (P0-7 records commit, after `cf3fe35` PROG: make db-test.sh work in Git Bash on Windows)

## Completed phases
| Phase | Gate result | Summary | Date |
|---|---|---|---|
| 0 — Foundation | Pass locally; approved by the repository owner. Gap: CI not yet run on GitHub (OD-11) | `docs/phases/phase-0/SUMMARY.md` | 2026-11-11 |

## Current phase progress
| Increment | Capability | Status | Tests | Notes |
|---|---|---|---|---|
| P0-1 Documentation baseline | PROG | Done (`5ae1707`, `e53847b`) | `git status` clean | Duplicates deleted (OD-24) |
| P0-2 Testcontainers pin | PROG | Done (pin restored; matches `0c192e7`) | mvn verify 6/6 | OD-23 option A |
| P0-3 Maven wrapper | PROG | Done (`09c7cd9`) | mvnw verify 6/6 | Also `*.cmd` CRLF rule |
| P0-4 Executable scripts | PROG | Done (`2595c9f`) | `100755` | |
| P0-5 Wrapper in CI | PROG | Done (`48847eb`) | Bash run 6/6 | Approved CI change |
| P0-6 Git Bash path fix | PROG | Done (`cf3fe35`) | Bash db-test 35/35 | |
| P0-7 Records | PROG | Done (this commit) | review | |

## Decisions awaiting human review
| ADR | Title | Why it needs review |
|---|---|---|
| ADR-005 | Policy-governed straight-through commit | Needs Audit/Risk sign-off before any policy is activated |
| ADR-006 to ADR-008 | Bitemporal model, ownership graph, AI proposes/humans approve | Proposed; awaiting team confirmation |
| ADR-013 to ADR-034 | Design-track decisions | Accepted by the owner; confirmations pending for ADR-014, 021, 023, 026, 027 (Security / Audit-Risk), see `docs/design/OPEN_DECISIONS.md` |


## Open questions for the human
1. Review the wiring of the design into `BUILD_PROTOCOL.md` and `CLAUDE.md` (design step 5). Design track otherwise complete.
3. OD-44: what counts as a shared environment (needed before the Phase 4 build; affects whether "edit Vn" stays allowed).
2. OD-11 decided (enterprise GitHub organisation, private): create the remote and say when to push; CI runs only after that.

## Scope changes
- **Phase 7 (AI assistance) deferred** by the repository owner on 2026-11-11 (OD-38): design approved; the build goes from Phase 6 to Phase 8. The `BUILD_PROTOCOL.md` phase table is updated in design step 5 (wiring).

## Known gaps, stubs and technical debt
- CI has never run on GitHub (no remote; OD-11).
- Mockito dynamic-agent warning in tests (future JDKs will block it).
- `scripts/check-setup.*` still requires a local `mvn`.
- Schema control gaps and untested guards (D-04 to D-07, D-12 to D-15, D-22, D-29, D-33 in `docs/design/DESIGN_STATE.md`; OD-18).

## Next action
After approval of the wiring: **Phase 1 — Core write path**, Step 1 (Orient) and Step 2 (Plan) per `docs/BUILD_PROTOCOL.md`,
following `docs/design/phase-1-core-write-path/LLD.md`; then stop for plan approval.
