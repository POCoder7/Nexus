# Phase 0 — Foundation: test report

- **Date:** 2026-11-11 · **Code state:** `cf3fe35` (all Phase 0 code changes; P0-7 only adds documentation)
- **Machine:** Windows 11 Home, Docker Desktop with Engine 29.9.2 on WSL 2, JDK Temurin 21.0.13, Maven 3.9.9 via the wrapper

## Commands and results

| Suite | Command | Passed | Failed | Skipped |
|---|---|---|---|---|
| Migrations V1–V6 + pgTAP (Windows) | `scripts\db-test.ps1` | 35 (18 `01_core_invariants.sql` + 17 `02_workflow_invariants.sql`) | 0 | 0 |
| Migrations V1–V6 + pgTAP (Bash, the CI script) | `bash scripts/db-test.sh` (Git Bash, no extra variables) | 35 | 0 | 0 |
| API build + tests (Windows) | `services\mdm-api\mvnw.cmd -B verify` | 6 (`HierarchyApiTest`) | 0 | 0 |
| API build + tests (Bash, the CI command) | `cd services/mdm-api && ./mvnw -B verify` | 6 | 0 | 0 |
| Wrapper version | `mvnw.cmd -v`, `./mvnw -v` | Maven 3.9.9 both | — | — |
| File modes | `git ls-files -s scripts/*.sh services/mdm-api/mvnw` | all `100755` | — | — |

## Traceability

| Capability | Exit criterion | Evidence | Result |
|---|---|---|---|
| PROG | `scripts/db-test` green locally | Both scripts 35/35 | Pass |
| PROG | `mvn verify` green locally | Wrapper on Windows and Bash, 6/6 | Pass |
| PROG | Maven wrapper committed | `09c7cd9` | Pass |
| PROG | CI workflow valid | `ci.yml` reviewed; both job commands run locally in Bash and pass; scripts executable (`2595c9f`); wrapper used in CI (`48847eb`) | **Pass locally; explicit gap:** no GitHub Actions run yet (no remote, OD-11) |

## Failures and skipped tests
None. No test was added, removed, disabled or weakened. No migration, trigger or constraint changed.

## Explicit gaps
1. **CI has not run on GitHub.** It needs a push, which needs your approval and a repository location (OD-11).
   The runner's Docker version is unknown; the Testcontainers pin works with older and newer engines.
2. **Mockito warning** about loading its agent dynamically appears during tests; future JDKs will block this. Not fixed (Surefire configuration change), recorded as technical debt.
