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
   If your local database predates Phase 1, recreate it once: `docker compose down -v` (V1, V5 and V6 were edited).

Full setup: [docs/DEVELOPER_SETUP.md](docs/DEVELOPER_SETUP.md) · Working rules: [CLAUDE.md](CLAUDE.md) ·
Contributing: [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) · Data model: [docs/data-model.md](docs/data-model.md) ·
Capabilities: [docs/capabilities.md](docs/capabilities.md)

## Documentation map
| Document | Purpose |
|---|---|
| [CLAUDE.md](CLAUDE.md) | Non-negotiable working rules for AI agents and humans |
| [docs/capabilities.md](docs/capabilities.md) | What must be built: 91 capabilities with IDs, decisions and acceptance criteria |
| [docs/DESIGN_PROTOCOL.md](docs/DESIGN_PROTOCOL.md) | How the low-level design per phase is produced (do this first) |
| [docs/BUILD_PROTOCOL.md](docs/BUILD_PROTOCOL.md) | The phase-by-phase build loop: plan, build, test, document, approve |
| [docs/BUILD_STATE.md](docs/BUILD_STATE.md) | Where the build currently stands |
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
| `services/mdm-api` | Java 21 / Spring Boot service; Flyway migrations V1–V9; generic workflow process in `src/main/resources/bpmn` |
| `db` | PostgreSQL + pgTAP image and database tests |
| `docs/specs` | Specifications per capability |
| `docs/adr` | Architecture decision records |
| `tests/golden` | Parity tests against legacy outputs (masked data only) |
| `tools/drm-analysis` | Internal-only analysis tooling (aggregate outputs only) |
| `scripts` | Setup checks and database test runners |

## Status
Phase 2 (governance) built, awaiting gate approval: workflow models, stages, worklist, commit policy in shadow mode,
engine-neutral workflow (Camunda adapter written, its run deferred). Phase 1 (core write path) approved: change requests from draft to applied data in core mode
(maker-checker), entitlements by hierarchy and sub-tree, bitemporal reads at any date. Migrations V1–V9 apply on a
fresh PostgreSQL 16 database and all 319 pgTAP tests pass; the API's 100 tests pass (verified 2026-11-11).
Current progress: [docs/BUILD_STATE.md](docs/BUILD_STATE.md).
