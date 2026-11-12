# Phase 0 — Foundation: summary

## What was built
Everything that existed now runs, locally on Windows and in the Bash commands CI uses.

| Commit | Increment |
|---|---|
| `737f3ea` | P0-1a Protocols, capability catalogue, UI standard, ADR-012 committed; duplicate `knowledge/capabilities.md` deleted (OD-24) |
| `5326bf1` | P0-1b Design orient work committed (overview, patterns, traceability, open decisions, ADR-013 to ADR-018, prototype); superseded draft ADR-012 deleted before commit (OD-24) |
| (`4202370`, existing) | P0-2 Testcontainers 1.21.4 pin restored in the working tree (OD-23 option A); identical to the committed version, so no new commit |
| `87ce6ea` | P0-3 Maven wrapper (3.9.9) |
| `131ec84` | P0-4 Shell scripts executable |
| `6e9fde1` | P0-5 CI uses the wrapper |
| `1c73e90` | P0-6 `db-test.sh` works in Git Bash |
| P0-7 commit | Records: README, data model, developer setup, CHANGELOG, this summary, test report, build state |

## Decisions taken
- OD-23: restore the Testcontainers pin (your choice, option A).
- OD-24: delete both duplicates (your choice).
- CI change in P0-5 and optional P0-6 approved by you.
No new ADR: no non-trivial technical choice was made beyond these.

## Patterns introduced
None new. Phase 0 changed no application code.

## Deviations from the plan
- **P0-3:** added `*.cmd text eol=crlf` to `.gitattributes`. The plan did not mention it; without it, `mvnw.cmd`
  would get LF endings from the `* text=auto eol=lf` rule, which can break Windows batch files.
- **P0-3:** pinned the wrapper plugin to 3.3.2 instead of using whatever version Maven resolves for `wrapper:wrapper`, for reproducibility.
- **P0-3:** the regenerated `maven-wrapper.properties` drops the old comment line ("Generate the wrapper scripts once with…"), which no longer applies.
- **P0-7:** `CLAUDE.md` still lists `mvn -B -f services/mdm-api/pom.xml verify`. That command still works; I did not edit your rules file. Say if you want it changed to the wrapper.

## Known gaps and technical debt
- CI not yet run on GitHub (OD-11).
- Mockito dynamic-agent warning.
- `scripts/check-setup.*` still requires a local `mvn`, although the wrapper makes it optional.
- Schema control gaps and missing guard tests (D-04 to D-07, D-12 to D-15, D-22, D-29, D-33; OD-18): out of Phase 0 scope.

## What the next step needs
Per your sequence, step B (the design track) follows. Its first stop, the architecture overview and pattern catalogue
(committed in `5326bf1`), is still awaiting your review. Then the Phase 1 LLD, which depends on OD-13 (capability decisions for Phases 1–3) and OD-18.
