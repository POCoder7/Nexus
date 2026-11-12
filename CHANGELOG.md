# Changelog

All notable changes to Nexus, newest first. Each entry names its capability ID or `PROG`.

## Phase 3 — Steward UI (2026-11-12)

### Added
- Angular 22 workspace in `ui/`: shell with context bar, "Viewing as of" date and read-only historical views, start-page preference, development user picker (local and test builds only). `NEW-10`
- Hierarchy workspace: lazy virtualised tree with paged siblings ("Show next 200"), WAI-ARIA keyboard model, type-ahead, in-tree search that reveals deep nodes; node panel with the property grid and provenance markers. `HIE-12`
- Add-leaf dialog built from the model's submit form, change-request tray with ETag chaining and idempotent retries, review and submit with validation findings. `SLICE-01`
- Worklist screen with nine view chips, counts, search, model filter and paging; request page with workflow timeline, policy evaluations and decision panel. `GOV-13`, `GOV-12`
- Home with worklist, own requests, hierarchies and the shadow-mode policy panel for policy roles. `NEW-10` (OD-27)
- Scope extension (repository owner): edit node details, set or clear property values from the property grid, place under a second parent, move with a target picker, remove and delete with an impact preview in numbers and a confirmation, and create a hierarchy from Home; drafts not started by add-leaf use the `MAINTAIN` model; `GET /hierarchies/{code}/nodes/{id}/impact`. `HIE-01`, `HIE-02`, `PRP-01`
- Backend support: `V10__ui_support.sql` (user preferences, `pg_trgm` search indexes), `/me` preferences, permissions and working version, `/home`, in-tree search and node path, submit form, request instance link and item "before" values, the reason a stage cannot be decided, client error reports. `NEW-10`, `HIE-12`, `GOV-03` (infrastructure)
- UI toolchain (ADR-025): Vitest component tests, Storybook stories with axe, Playwright SLICE-01 journeys with axe, Stylelint token rules, generated API client with a drift check, compressed bundle budgets and a production check that the dev identity is absent; CI job `ui`. `PROG`

### Changed
- Worklist query moved into `WorklistQuery` so Home and the worklist share it. `GOV-13`
- springdoc answers `application/json` by default (the generated client read `*/*` bodies as blobs). `PROG`

### Fixed
- A property could not be set on a node added earlier in the same request, so a leaf and its required properties could not go into one request. `HIE-02`, `PRP-01`
- Tree type-ahead stopped at a space; focus jumped to the heading when only a query parameter changed; the add-leaf form saved defaults as stored values; the request page did not refresh after submit. `HIE-12`, `NEW-10`
- `HierarchyApiTest` and `NodePropertiesApiTest` fixtures took the UTC session date for their valid period and failed between 00:00 UTC and midnight New York; they now use the business day. `PROG`

## Phase 2 — Governance (2026-11-11, gate approved 2026-11-12)

### Added
- Workflow models from definition files, activated by a second administrator; versions pinned per request. `GOV-01`
- Submit with a workflow model; Enrich, Approve and Commit stages; decisions, claims, enrichment items; instance view; refusals explained in words. `GOV-02`
- Commit policy evaluated before Commit in shadow mode; policy administration; daily cap safe under concurrency; active mode refused until OD-08. `GOV-12`
- Worklist with nine views, counts, search, model filter and paging; urgent flag. `GOV-13`
- Engine-neutral workflow ports, outbox relay with offsets, in-process reference driver, reconciler; Camunda 8 adapter (written, Camunda run deferred). `GOV-02`, `PROG` (ADR-035)
- V9 workflow objects; bitemporal, four-eyes group membership; configuration audit. `PROG`

### Changed
- V1, V4, V5, V6, V7, V8 edited (allowed until a shared environment exists, OD-44): business-day boundaries, membership checks, claim and close rules, bridge attribution and clearance, scope by ancestor walk; local databases must be recreated (`docker compose down -v`). `PROG`
- Controller methods (OpenAPI operation ids) renamed to explicit names. `PROG`

### Fixed
- `wf.close_instance` recorded the commit action after changing the status, so the approval had no decider. `GOV-02`

## Phase 1 — Core write path (2026-11-11, gate approved)

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
- OpenAPI description `docs/api/openapi.json` (springdoc, JSON only; served only in `local` and `test`), checked by `OpenApiDocumentTest`. `PROG`

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
