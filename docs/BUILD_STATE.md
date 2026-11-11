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
| ADR-006 to ADR-009 | Bitemporal model, ownership graph, AI proposes/humans approve, golden testing | Proposed; awaiting team confirmation |
| ADR-013 to ADR-018 | Modular monolith, DB roles, API conventions, outbox, workflow engine (open), time handling | Proposed in the design track; see `docs/design/OPEN_DECISIONS.md` |

## Open questions for the human
1. Review the architecture overview, pattern catalogue and ADR-013 to ADR-018 (design track, first stop).
2. Should `CLAUDE.md` "Commands" switch to the Maven wrapper? (Not edited; your rules file.)
3. OD-11: where will the repository live, so CI can run on GitHub?

## Known gaps, stubs and technical debt
- CI has never run on GitHub (no remote; OD-11).
- Mockito dynamic-agent warning in tests (future JDKs will block it).
- `scripts/check-setup.*` still requires a local `mvn`.
- Schema control gaps and untested guards (D-04 to D-07, D-12 to D-15, D-22, D-29, D-33 in `docs/design/DESIGN_STATE.md`; OD-18).

## Next action
Step B: wait for review of the architecture overview and pattern catalogue
(`docs/design/DESIGN_STATE.md` next action), followed by the Phase 1 LLD.
