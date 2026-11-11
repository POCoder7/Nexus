# Phase 0 — Foundation: plan

- **Status:** Awaiting approval (2026-11-11)
- **Goal (BUILD_PROTOCOL §2):** everything that exists runs.
- **Exit criteria:** `scripts/db-test` and `mvn verify` green locally; Maven wrapper committed; CI workflow valid.

## Baseline (2026-11-11, Windows 11, Docker Engine 29.9.2, JDK Temurin 21.0.13, Maven 3.9.9)

| Suite | Command | Result | Cause |
|---|---|---|---|
| Migrations + pgTAP (PowerShell) | `scripts\db-test.ps1` | **Pass**: V1–V6 applied; 35/35 tests (18 + 17) | — |
| Migrations + pgTAP (Bash, as CI runs it) | `bash scripts/db-test.sh` | **Pass**: 35/35 with `MSYS_NO_PATHCONV=1`; fails in Git Bash without it | Git Bash on Windows rewrites `/workspace/...` into a Windows path. Linux CI is not affected |
| API build + tests | `mvn -B -f services/mdm-api/pom.xml verify` | **Fail**: `HierarchyApiTest` errors before start, "Could not find a valid Docker environment" (HTTP 400 from Docker) | Spring Boot 3.4.5 manages Testcontainers 1.20.x, whose Docker client requests API 1.32; Docker Engine 29 accepts ≥ 1.40. The pin to 1.21.4 (commit `0c192e7`) has been removed in the working tree (uncommitted change to `pom.xml`). With the pin, 6/6 passed earlier today |
| Maven wrapper | — | **Missing** | Only `services/mdm-api/.mvn/wrapper/maven-wrapper.properties` exists; `mvnw` / `mvnw.cmd` not generated |
| CI workflow | `.github/workflows/ci.yml` (read, not run) | **Would fail** in `db-tests` | `scripts/*.sh` are committed with mode `100644`, so `./scripts/db-test.sh` gets "Permission denied" on Linux. The `api` job would also hit the Testcontainers issue if the runner's Docker is ≥ 29 |

Other observations: `.gitattributes` gives `.sh` and SQL files LF endings (correct). The Mockito warning about
dynamic agent loading appears in the test run; harmless today, blocked by a future JDK. Working tree has
uncommitted documentation (protocols, capability catalogue, design documents, ADR-012 to ADR-018) and the `pom.xml` change.

## Scope

**In:** PROG only (foundation). **Out:** every capability; the control gaps in `docs/design/OPEN_DECISIONS.md`
OD-18 (they change guards and need your decision); the design track (B). **Needs decision:** OD-23 (how to fix
Testcontainers), approval to change CI (CLAUDE.md rule 8).

## Work breakdown

| # | Increment | Size | Change | Test that proves it |
|---|---|---|---|---|
| P0-1 | Commit the current documentation as the starting point | S | Two local commits, no code: (a) `PROG: add build and design protocols, capability catalogue, UI standard` — your files; (b) `PROG: architecture overview, pattern catalogue, ADR-013 to ADR-018 (proposed)` — the design work. `pom.xml` is **not** included | `git status` shows only `pom.xml` modified |
| P0-2 | Make Testcontainers work with Docker Engine 29 (**OD-23, your choice**) | S | Option A (recommended): restore `<testcontainers.version>1.21.4</testcontainers.version>` with the comment explaining why. Option B: upgrade the Spring Boot parent to a 3.5.x release that manages a compatible Testcontainers (larger change; verified only by running). Option C: no repo change; `api.version=1.44` in `%USERPROFILE%\.docker-java.properties` (fixes this laptop only, not CI) | Plain `mvn -B -f services/mdm-api/pom.xml verify` → `HierarchyApiTest` 6/6, BUILD SUCCESS |
| P0-3 | Generate and commit the Maven wrapper | S | In `services/mdm-api`: `mvn -N wrapper:wrapper -Dmaven=3.9.9` → `mvnw`, `mvnw.cmd`, updated `maven-wrapper.properties` (same 3.9.9 distribution as today) | `services/mdm-api/mvnw.cmd -v` shows 3.9.9; `mvnw.cmd -B verify` green; `git ls-files -s` shows `mvnw` as `100755` |
| P0-4 | Mark shell scripts executable in git | S | `git update-index --chmod=+x scripts/db-test.sh scripts/check-setup.sh` (file mode only, content unchanged) | `git ls-files -s scripts` shows `100755` |
| P0-5 | Use the wrapper in CI (**CI change: needs your approval**) | S | `api` job: `working-directory: services/mdm-api` and `./mvnw -B verify` instead of `mvn -B -f …` (the wrapper finds `.mvn` from the working directory). No other CI changes | Same command run locally in Git Bash: `cd services/mdm-api && ./mvnw -B verify` green. A real CI run needs a push (see gaps) |
| P0-6 | Make `db-test.sh` work in Git Bash on Windows (optional) | S | Add `export MSYS_NO_PATHCONV=1` near the top, with a comment; no effect on Linux | `bash scripts/db-test.sh` in Git Bash → 35/35 without extra variables |
| P0-7 | Bring the records up to date | S | `docs/BUILD_STATE.md` (baseline, commits); `README.md` status and `docs/data-model.md` "Known gaps" (no longer "never run"); `docs/DEVELOPER_SETUP.md` (Windows Home needs WSL 2 for Docker Desktop; Docker Engine 29 and Testcontainers; use `mvnw`); `CHANGELOG.md` (new, required by BUILD_PROTOCOL step 6); `docs/phases/phase-0/TEST_REPORT.md` and `SUMMARY.md` | Review |

Order: P0-1 → P0-2 → P0-3 → P0-4 → P0-5 → P0-6 → P0-7, one commit each with the `PROG:` prefix, each after the full
suite is green. I will ask before each commit, as the permission rules require. Nothing is pushed.

## Tests for the gate

- `scripts\db-test.ps1` and `bash scripts/db-test.sh`: 35/35.
- `services/mdm-api/mvnw.cmd -B verify` (Windows) and `./mvnw -B verify` (Git Bash): 6/6.
- `git ls-files -s` shows executable modes for `scripts/*.sh` and `mvnw`.
- No test is added, removed or weakened in Phase 0; no migration, trigger or constraint changes.

## Decisions and dependencies

- **OD-23** (Testcontainers fix): options above; recommendation Option A. Option B would be a dependency upgrade and would get its own ADR.
- **New tooling:** the Maven wrapper (Apache `maven-wrapper-plugin`, run once to generate files; the wrapper downloads the same Maven 3.9.9 distribution already named in `maven-wrapper.properties`). No new runtime or test dependencies.
- **CI change** in P0-5 needs your explicit approval (CLAUDE.md rule 8). If you prefer not to change CI now, P0-5 is dropped and CI keeps calling `mvn`, which GitHub's Ubuntu runners provide.

## Risks, assumptions and open questions

1. **"CI workflow valid" cannot be fully proved locally.** I can run the same commands in Bash, but a real GitHub
   Actions run needs a push, and the repository location is undecided (OD-11). Proposal: the gate records this as an
   explicit gap until the first push you approve.
2. The Docker Engine version on GitHub's `ubuntu-latest` runners is not known here; Option A works whichever it is.
3. The Mockito dynamic-agent warning is left as technical debt (fixing it changes the Surefire configuration); recorded in `BUILD_STATE.md`.
4. OD-24 (delete the draft `ADR-012-web-ui-stack.md` and `knowledge/capabilities.md`) is yours to decide; P0-1 commits both as they are unless you say otherwise.
5. Assumption: committing your uncommitted documentation (P0-1a) is what you want. If any of it should stay out of git, tell me which files.

## Questions for you

1. OD-23: Option A, B or C?
2. May I change `ci.yml` as in P0-5?
3. Include the optional P0-6?
4. OD-24: delete the two duplicate files before P0-1, or commit them as they are?
