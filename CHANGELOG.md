# Changelog

All notable changes to Nexus, newest first. Each entry names its capability ID or `PROG`.

## Phase 0 — Foundation (2026-11-11, gate approved)

### Added
- Maven wrapper for `services/mdm-api` (Maven 3.9.9; `mvnw`, `mvnw.cmd`). `PROG`
- Build and design protocols, capability catalogue in `docs/`, UI standard, ADR-012 (Accepted). `PROG`
- Architecture overview, pattern catalogue, traceability, open decisions, ADR-013 to ADR-018 (Proposed), landing-page prototype. `PROG`
- `CHANGELOG.md`. `PROG`

### Changed
- CI `api` job runs `./mvnw -B verify` from `services/mdm-api`. `PROG`
- `scripts/db-test.sh` works in Git Bash on Windows (`MSYS_NO_PATHCONV=1`). `PROG`
- `scripts/*.sh` are executable in git, so CI can run them. `PROG`
- `*.cmd` files use CRLF line endings. `PROG`
- Testcontainers pinned to 1.21.4 for Docker Engine 29. `PROG`
- README, data model and developer setup describe the verified state. `PROG`

### Removed
- `knowledge/capabilities.md` (duplicate of `docs/capabilities.md`) and a superseded draft ADR-012 (OD-24). `PROG`
