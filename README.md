# Nexus
=======
# Nexus — AI-enabled master data management

Replacement for a legacy hierarchy-management and governance product, with a bitemporal data model,
DRG-style governance workflows, policy-governed straight-through commit, a legal-entity ownership graph
for beneficial-ownership analysis, and AI assistance under human approval.

## Quick start
1. Check your toolchain: `scripts\check-setup.ps1` (Windows) or `scripts/check-setup.sh`
2. Run the database tests: `scripts\db-test.ps1` or `scripts/db-test.sh`
3. Build and test the API with the Maven wrapper (no local Maven needed): `cd services/mdm-api`, then
   `.\mvnw.cmd -B verify` (Windows) or `./mvnw -B verify`
4. Run the API locally: `docker compose up -d db`, then from `services/mdm-api` run
   `./mvnw spring-boot:run -Dspring-boot.run.profiles=local -Dspring-boot.run.arguments=--mdm.api.local-user=<login>`
   (`.\mvnw.cmd` on Windows) and open http://localhost:8080/api/v1/me. The API refuses to start without an identity
   adapter; the `local` profile reads the user from `mdm.api.local-user` or the `X-Nexus-User` header. The login must
   be a synthetic user in `mdm.app_user` with a role grant in `mdm.user_role` (see
   [docs/DEVELOPER_SETUP.md](docs/DEVELOPER_SETUP.md#3-verify)).
   If the API refuses to start with a Flyway checksum error after a pull, an applied migration was edited (allowed until
   the first shared environment): recreate the local database with `docker compose down -v`
   ([details](docs/DEVELOPER_SETUP.md#which-databases-are-built-from-scratch)).
5. Try the whole app with synthetic data: `scripts\demo.ps1` or `scripts/demo.sh` builds a fresh demo database, loads
   the hackathon CSV data set (ADR-046) from `data/` (or the tracked sample) through the governed two-ADMIN load, starts
   the API and the UI, and prints the users to sign in as: only those of `data/users.csv`. `-E2eSeed` / `--e2e-seed`
   gives the automated tests' data instead. `scripts\demo-stop.ps1` or `scripts/demo-stop.sh` stops it.
6. To load a data set into a running Nexus by hand: `scripts/load-data.sh` or `scripts\load-data.ps1` uploads and checks
   a folder and prepares the load; `--approve-as` / `-ApproveAs` then approves and applies it as a second ADMIN (local
   and test only). Admin › Data loads does the same on screen.

Full setup: [docs/DEVELOPER_SETUP.md](docs/DEVELOPER_SETUP.md) · Working rules: [CLAUDE.md](CLAUDE.md) ·
Contributing: [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) · Data model: [docs/data-model.md](docs/data-model.md) ·
Capabilities: [docs/capabilities.md](docs/capabilities.md)

## Documentation map
| Document | Purpose |
|---|---|
| [CLAUDE.md](CLAUDE.md) | Non-negotiable working rules for AI agents and humans |
| [docs/capabilities.md](docs/capabilities.md) | What must be built: 91 capabilities with IDs, decisions and acceptance criteria |
| [docs/DRM_COMPARISON.md](docs/DRM_COMPARISON.md) | Review of Nexus against Oracle DRM: coverage, architecture, highlights, gaps and recommendations (2026-11-14) |
| [docs/DESIGN_PROTOCOL.md](docs/DESIGN_PROTOCOL.md) | How the low-level design per phase is produced (do this first) |
| [docs/BUILD_PROTOCOL.md](docs/BUILD_PROTOCOL.md) | The phase-by-phase build loop: plan, build, test, document, approve |
| [docs/BUILD_STATE.md](docs/BUILD_STATE.md) | Where the build currently stands |
| [docs/APPROVAL_MATRIX.md](docs/APPROVAL_MATRIX.md) | Who can raise, approve and commit each kind of change, the four-eyes rules, and the demo users' matrix |
| [docs/design/UI_STANDARD.md](docs/design/UI_STANDARD.md) | Binding UI standard (Angular on the organisation's design system) |
| [docs/design/](docs/design/) | Low-level designs per phase, traceability, open decisions |
| [docs/architecture/](docs/architecture/) | Architecture overview and pattern catalogue |
| [docs/adr/](docs/adr/) | Architecture decision records |
| [docs/specs/](docs/specs/) | Specifications per capability |
| [docs/data-model.md](docs/data-model.md) | Schema design and legacy-product mapping |
| [docs/api/openapi.json](docs/api/openapi.json) | OpenAPI description of the API (regenerate with `./mvnw -B verify -Dopenapi.update=true`) |
| [docs/DEVELOPER_SETUP.md](docs/DEVELOPER_SETUP.md) · [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) | Environment setup and the contribution flow |

## Repository layout
| Path | Contents |
|---|---|
| `services/mdm-api` | Java 21 / Spring Boot service; Flyway migrations V1–V10; generic workflow process in `src/main/resources/bpmn` |
| `ui` | Angular steward UI (Phase 3): `npm start`, tests and end-to-end journeys in `ui/e2e` (see DEVELOPER_SETUP) |
| `db` | PostgreSQL + pgTAP image and database tests |
| `docs/specs` | Specifications per capability |
| `docs/adr` | Architecture decision records |
| `tests/golden` | Parity tests against legacy outputs (masked data only) |
| `tools/drm-analysis` | Internal-only analysis tooling (aggregate outputs only) |
| `scripts` | Setup checks and database test runners |

## Status
Phase 3 (steward UI) built, awaiting gate approval: an Angular 22 UI in `ui/` with Home, the lazy hierarchy tree with
search, the property grid with provenance, every editing action through the change-request tray (add leaf, edit details
and properties, place, move, remove, delete, new hierarchy, drag and drop), History and Ownership tabs, a before/after
view, property edit rights by category, review and submit, worklist and request pages with the
workflow timeline, and versions (create and copy, the lifecycle to finalized and expired, a working-version picker and
read-only version pictures). Phase 2 (governance) and Phase 1 (core write path) approved. Migrations V1–V11 apply on a
fresh PostgreSQL 16 database and all 411 pgTAP tests pass; the API's 126 tests pass; the UI's 64 unit tests, 49 stories
and 38 end-to-end journeys pass with accessibility checks (verified 2026-11-13).
Current progress: [docs/BUILD_STATE.md](docs/BUILD_STATE.md).
