# Build state

- **Current phase:** 0 — Foundation
- **Step in loop:** Plan (awaiting approval) — `docs/phases/phase-0/PLAN.md`
- **Baseline:** db-test **pass** 35/35 (PowerShell; Bash with `MSYS_NO_PATHCONV=1`) · mvn verify **fail** — `HierarchyApiTest` cannot reach Docker (Testcontainers 1.20.x vs Docker Engine 29; pin removed in working tree) · UI tests n/a (as of 2026-11-11)
- **Last commit:** `0c192e7` PROG: pin Testcontainers 1.21.4 for Docker Engine 29 (the working tree reverts this pin, uncommitted)

## Completed phases
| Phase | Gate result | Summary | Date |
|---|---|---|---|

## Current phase progress
| Increment | Capability | Status | Tests | Notes |
|---|---|---|---|---|
| P0-1 Commit documentation baseline | PROG | Planned | `git status` | Needs approval to commit |
| P0-2 Testcontainers vs Docker Engine 29 | PROG | Planned | mvn verify 6/6 | Needs OD-23 decision |
| P0-3 Maven wrapper | PROG | Planned | mvnw verify 6/6 | |
| P0-4 Executable bit on `scripts/*.sh` | PROG | Planned | `git ls-files -s` | CI `db-tests` would fail today |
| P0-5 Wrapper in CI | PROG | Planned | local Bash run | CI change needs approval |
| P0-6 Git Bash path fix in `db-test.sh` | PROG | Optional | Bash db-test 35/35 | |
| P0-7 Records (README, data-model, setup guide, CHANGELOG, test report, summary) | PROG | Planned | review | |

## Decisions awaiting human review
| ADR | Title | Why it needs review |
|---|---|---|
| ADR-005 | Policy-governed straight-through commit | Needs Audit/Risk sign-off before any policy is activated |
| ADR-006 to ADR-009 | Bitemporal model, ownership graph, AI proposes/humans approve, golden testing | Proposed; awaiting team confirmation |
| ADR-013 to ADR-018 | Modular monolith, DB roles, API conventions, outbox, workflow engine (open), time handling | Proposed during the design orient step; see `docs/design/OPEN_DECISIONS.md` |

## Open questions for the human
1. OD-23: fix Testcontainers by restoring the 1.21.4 pin (recommended), upgrading Spring Boot, or a laptop-only setting?
2. Approve the CI change in P0-5 (use `./mvnw` in the `api` job)?
3. Include optional P0-6 (Git Bash path fix)?
4. OD-24: delete the duplicate draft ADR-012 and `knowledge/capabilities.md` before committing?

## Known gaps, stubs and technical debt
- CI has never run (no remote; OD-11). "CI workflow valid" can only be checked locally until a push is approved.
- `scripts/*.sh` committed without the executable bit.
- Mockito dynamic-agent warning in tests (future JDKs will block it).
- Control gaps in the schema recorded as D-04 to D-07, D-12 to D-15, D-29, D-33 in `docs/design/DESIGN_STATE.md` (OD-18); not in Phase 0 scope.

## Next action
Wait for approval of `docs/phases/phase-0/PLAN.md` and answers to the four questions; then build P0-1 to P0-7 in order, asking before each commit.
