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
Contributing: [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) · Data model: [docs/data-model.md](docs/data-model.md)

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
