# Changelog

All notable changes to Nexus, newest first. Each entry names its capability ID or `PROG`.

## Phase 1 — Core write path (2026-11-11, gate passed with gaps, awaiting approval)

### Added
- Change-request API: create, edit, items with expected values, list mine and the review queue, validate, submit, decide, withdraw; ETags (428/412) and idempotency keys. `HIE-02`, `PRP-01`
- Apply in SQL for `add_node`, `insert_node`, `move_node`, `remove_node`, `delete_node`, `update_node`, `add_hierarchy`, `set_property`, `clear_property`: bitemporal set-from-D, stale-base check, all-or-nothing, change events. `HIE-02`, `PRP-01`, `HIE-01`
- Validation by trial apply plus SQL rules, findings stored; submit refuses on errors. `HIE-02`
- Core-mode decisions (maker-checker, human only), apply service with retries, sweeper for requests left approved. `HIE-02`
- Entitlements: six roles, grants scoped to all hierarchies, one hierarchy or a sub-tree; `GET /me`. `SEC-01`, `SEC-02`
- Reads at any business date and recorded time, keyset paging, resolved properties with provenance. `HIE-01`, `NEW-01`, `PRP-01`
- V7 database roles and privileges; V8 entitlements, settings and idempotency keys. `PROG`
- Error codes and hints on every guard, Problem Details responses. `PROG`
- Performance test scaffold (tag `perf`, not run; deferred). `PROG`

### Changed
- V1, V5, V6 edited (allowed until a shared environment exists, OD-44): new guards (requester kind, status transitions, frozen content, draft-only items and deletes), write-path functions; local databases must be recreated (`docker compose down -v`). `PROG`
- The API refuses to start without an identity adapter; run it locally with the `local` profile and `mdm.api.local-user`. `SEC-01`
- Database sessions run in UTC; business dates come from `America/New_York`. `PROG`

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
