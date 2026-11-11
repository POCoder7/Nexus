# CLAUDE.md — working rules for AI coding agents (and a summary for humans)

## What this project is
Nexus is an AI-enabled master data management (MDM) platform replacing a legacy hierarchy-management
product (Oracle DRM/DRG). It manages hierarchies, nodes, properties, versions, governance workflows,
and a legal-entity ownership graph for beneficial-ownership (UBO) analysis.

Read first: `README.md`, `docs/capabilities.md`, `docs/data-model.md`, `docs/adr/`, and the spec for the task in `docs/specs/`.
For the phased build, follow `docs/BUILD_PROTOCOL.md`; `docs/BUILD_STATE.md` records where the build stands.
For design work, follow `docs/DESIGN_PROTOCOL.md`. Before building a phase, read `docs/architecture/` (overview,
patterns), its approved `docs/design/phase-N-*/LLD.md`, `docs/design/CONSISTENCY_REVIEW.md` and `docs/design/OPEN_DECISIONS.md`.
**Each phase plan must follow its LLD; any deviation requires updating the LLD and writing an ADR first.**
UI work follows `docs/design/UI_STANDARD.md` (Angular, ADR-012). Phase 7 (AI) is designed but deferred (OD-38).

## Layout
- `services/mdm-api/` — Java 21 / Spring Boot 3 service (Maven). Flyway migrations live in
  `src/main/resources/db/migration` (V1 core, V2 ownership/UBO, V3 DRM export, V4 workflow,
  V5 workflow↔core bridge, V6 commit policies).
- `db/tests/` — pgTAP tests for database rules. `db/Dockerfile` — PostgreSQL 16 + pgTAP.
- `scripts/` — `db-test.sh` / `db-test.ps1` (fresh DB, all migrations, pgTAP), `check-setup.*`.
- `docs/specs/` — specs per capability; `docs/adr/` — architecture decisions.
- `docs/capabilities.md` — capability catalogue; every story and change maps to an ID here.
- `docs/BUILD_PROTOCOL.md` — the phase-by-phase build loop; `docs/BUILD_STATE.md` — current progress (update before stopping).
- `docs/DESIGN_PROTOCOL.md` — how the low-level designs are produced; `docs/design/` — the designs, UI standard,
  traceability and open decisions; `docs/architecture/` — overview and pattern catalogue.
- `ui/` — Angular front end (from Phase 3). Design-system packages come from the internal registry and are never committed.
- `.knowledge/` (git-ignored, may be absent) — private reference material. Read-only: never edit, copy from, quote in commits, or stage it.
- `tests/golden/` — parity tests against outputs captured from the legacy system (masked data only).

## Commands
- Toolchain check: `scripts/check-setup.ps1` (Windows) or `scripts/check-setup.sh`
- Database tests: `scripts/db-test.ps1` or `scripts/db-test.sh`
- Java build + tests (needs Docker for Testcontainers): from `services/mdm-api`, `./mvnw -B verify` (`.\mvnw.cmd -B verify` on Windows)
- Local database only: `docker compose up -d db`

## Non-negotiable rules
1. **Never weaken a guard to make a test pass.** Triggers and constraints enforcing bitemporal history,
   maker-checker, separation of duties, human-only decisions, append-only logs, and commit-policy limits
   are deliberate controls. If one seems wrong, stop and explain; do not change it without a human decision
   recorded in an ADR.
2. **Explain before fixing.** For any failing migration or test, state the cause and the proposed fix,
   then make the smallest change that fixes it.
3. **Layer separation.** Schema `mdm` must never reference `wf`. `wf` may read `mdm` but never write it.
   Only `wf_bridge` writes across. `mdm_stage` is written only by the loader role and may read `mdm`; data reaches `mdm`
   from it only through change requests.
4. **Deterministic calculations.** Ownership percentages, inheritance and exports are computed in code/SQL,
   never by an AI model.
5. **No real data.** Never add production, client or personal data to code, tests, fixtures or prompts.
   Use synthetic or masked data. Never read files outside this repository.
6. **Migrations.** Until a shared environment exists, V1–V6 may be edited. After that, never edit an applied
   migration — add a new V-numbered file.
7. **Traceability.** Every change references a capability ID (e.g. `HIE-02`, `GOV-12`) or `PROG`
   in the branch name, commit message and PR.
8. **Ask first** before: `git push`, changing CI, touching credentials or `.env`, adding dependencies,
   or anything outside the local machine.
9. **Private material stays private.** Never stage, commit or summarise into tracked files anything from `.knowledge/`.

## Conventions
- Java: constructor injection, records for DTOs, `JdbcClient` with explicit SQL and row mappers,
  schema-qualified table names (`mdm.`, `wf.`). Page every list endpoint; hierarchies can be very large.
- SQL: schema-qualified names, `SET search_path` on functions, comments explaining *why*.
- Tests: pgTAP for database rules (one file per area, `BEGIN … ROLLBACK`), JUnit + Testcontainers for the API.
- Commits: `HIE-02: add paged children endpoint`. Branches: `feature/HIE-02-children-paging`.

## Definition of done
Reviewed by a human · tests added and green in CI · golden tests pass where applicable · no guard weakened ·
spec/ADR updated if behaviour or a decision changed · no real data · tracker updated.
