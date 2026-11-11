# Nexus — AI-enabled master data management

Replacement for a legacy hierarchy-management and governance product, with a bitemporal data model,
DRG-style governance workflows, policy-governed straight-through commit, a legal-entity ownership graph
for beneficial-ownership analysis, and AI assistance under human approval.

## Quick start
1. Check your toolchain: `scripts\check-setup.ps1` (Windows) or `scripts/check-setup.sh`
2. Run the database tests: `scripts\db-test.ps1` or `scripts/db-test.sh`
3. Build and test the API: `mvn -B -f services/mdm-api/pom.xml verify`
4. Run the API locally: `docker compose up -d db`, then `mvn -f services/mdm-api/pom.xml spring-boot:run`
   and open http://localhost:8080/api/v1/hierarchies

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
| [docs/DEVELOPER_SETUP.md](docs/DEVELOPER_SETUP.md) · [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) | Environment setup and the contribution flow |

## Repository layout
| Path | Contents |
|---|---|
| `services/mdm-api` | Java 21 / Spring Boot service; Flyway migrations V1–V6 |
| `db` | PostgreSQL + pgTAP image and database tests |
| `docs/specs` | Specifications per capability |
| `docs/adr` | Architecture decision records |
| `tests/golden` | Parity tests against legacy outputs (masked data only) |
| `tools/drm-analysis` | Internal-only analysis tooling (aggregate outputs only) |
| `scripts` | Setup checks and database test runners |

## Status
Sprint 0. The schema and code have **not yet been run against a live database** — making
`scripts/db-test` and `mvn verify` pass is the first task.
