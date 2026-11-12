# Phase 3 — Steward UI: plan

- **Status:** Approved by the repository owner (2026-11-12: "complete all of implementation in this phase, go with your
  recommendation"), including the 3-5 split, Node.js install by `winget` (it installed Node.js 26 LTS, the current LTS, so
  the build uses 26 rather than 24), the UI dependencies from the public npm registry and the CI `ui` job
- **Follows:** `docs/design/phase-3-steward-ui/LLD.md` (approved 2026-11-11), `docs/design/UI_STANDARD.md`, ADR-012 (Angular),
  ADR-015 (paging, ETags), ADR-018 (business day), ADR-022 (entitlements), ADR-025 (UI toolchain, accepted; its
  dependencies and CI job are approved here), OD-27 (landing page, prototype `prototypes/landing.html`).
- **Exit criteria (BUILD_PROTOCOL §2, LLD):** tree browsing with paging, node panel, worklist, add-leaf form; UI tests pass;
  SLICE-01 acceptance criteria met on synthetic data.

## Orient (baseline, 2026-11-12)
| Check | Result |
|---|---|
| `git status` | clean; branch `feature/GOV-02-phase-2-governance` at `f7fcf1f`; Phase 2 gate approved by the repository owner (2026-11-12, "go ahead with phase-3"); not merged to `main` (OD-18a); no remote (OD-11) |
| `scripts\db-test.ps1` | pass: V1–V9, 319/319 pgTAP |
| `mvnw.cmd -B verify` | **first run red, 4 + 2 failures** in `HierarchyApiTest` and `NodePropertiesApiTest`. Cause: their fixtures took the column default `daterange(current_date, NULL)`, the UTC session date, while reads use the New York business day (ADR-018). Between 00:00 UTC and midnight New York the rows start "tomorrow" and are invisible (run at 01:57 UTC; the Phase 2 gate ran outside that window). Fix, in test setup only: the fixtures set `valid_period` from `mdm.business_today()`. Production fact writes set the period through `mdm.apply_fact` and do not use the default. After the fix: **pass, 100/100** |
| Shared environment (OD-44) | none → the new `V10__ui_support.sql` is a new file anyway; no earlier migration is edited this phase |
| Already built | springdoc and the committed `docs/api/openapi.json` with a drift test (Phase 1), so LLD increment 3-2 is only the client generation; `GET /me` returns `actor`, `businessToday`, `businessTimeZone`, `grants` (3-1 adds `preferences` and `permissions`); the dev identity (`LocalDevActor`, `X-Nexus-User`) exists |
| Tooling on this machine | **Node.js and npm are not installed.** Nothing in `ui/` can be built until they are (question 2) |
| Open decisions this phase waits on | OD-02/03/04 (design-system packages, tokens, components): planned around as the LLD says, with adapters that render accessible placeholders and placeholder token values; visual sign-off waits for them. OD-06 (authentication): the UI runs only in `local` and `test` with the dev user picker. OD-10 (NFR values): budgets use the LLD defaults |

## Scope
**In (decided):** HIE-12 (Parity): lazy virtualised tree, paged siblings, in-tree search, property grid. GOV-13 UI (Parity):
worklist screen with nine views, counts, search, model filter. NEW-10 (New): shell, Home (OD-27), tray, request detail with
timeline, start-page preference. SLICE-01 journeys S1-R2 to S1-R7 on synthetic data. GOV-12 (Improve): "Committed by
policy" label and the shadow summary panel for policy roles.

**Infrastructure only:** GOV-03 `submit-form` endpoint (the properties the submit task lets the steward set), as the LLD
says.

**Not built, pending decision (LLD §15):** History tab (QRY-04 / AUD-01), Ownership tab (Phase 6), move / insert / remove
screens and impact preview (HIE-02 UI, Phase 5), diff / compare view, AI suggestion cards (Phase 7, deferred), notifications
(GOV-08 / GOV-16).

**Explicit gaps planned now:**
- **SLICE-01 S1-R1 and the golden criterion** need the masked extract and the Phase 4 golden framework.
- **Performance runs are deferred to the end of the build, as you decided.** These are the `T_BIG` expand trace, scrolling 50 000 siblings, and the interaction-latency test. Bundle-size budgets are still enforced, because they are a build check, not a performance run.
- **Visual sign-off** waits for OD-02 to OD-04.
- **The manual screen-reader check** of the custom components needs a person.

## Way of working
- New branch `feature/NEW-10-phase-3-steward-ui` from the Phase 2 branch. One local commit per increment, with its capability ID. I ask before each commit and never push.
- Tests first. Before every commit, all suites are green: `db-test`, `mvnw verify`, and the UI suites (`npm run lint`, `npm test`, `npm run build`, the Storybook tests, and, from 3-4, Playwright).
- **Synthetic data only.** End-to-end data comes from one seed script, `ui/e2e/seed.sql`, with obviously fictional names such as `E2E Region North`, `e2e_steward` and `e2e_approver`. The script creates users, groups, an activated `ADD_LEAF` model and a hierarchy with shared nodes and inherited properties.
- **The end-to-end environment:**
  - a fresh `docker compose` database with the API migrating it;
  - the seed script, run through definer functions as the owner, like the pgTAP fixtures;
  - the API, plus a worker on the in-process engine (`local` profile);
  - the Angular dev server, which proxies `/api` to the API, so no CORS change is needed.

  Playwright starts and stops all of this. As with local runs, the API runs as the docker-compose owner account (a known gap until a least-privilege local profile exists).

## Work breakdown (LLD §16; differences in **bold**)
| # | Increment | Size | Capabilities | Tests written first |
|---|---|---|---|---|
| 3-1 | Backend: `V10__ui_support.sql` (`mdm.user_preference`, `pg_trgm`, trigram index); `GET /me` adds `preferences` and `permissions`; `PUT /me/preferences`; `GET /home`; `GET /hierarchies/{code}/search` and `…/nodes/{id}/path`; `GET /workflow/models/{code}/submit-form`; `GET /change-requests/{id}` adds `workflowInstanceId` and `items[].before`; `POST /client-errors` (rate-limited, no values) | M | NEW-10, HIE-12, GOV-03 (infra) | pgTAP `21_ui_support`: preference checks, own row only via the API role, no grant to `nexus_wf`. JUnit per endpoint: `q` of 1 character → 422; `limit` > 50 refused; search honours `asOf` and read scope; path is the primary placement; `/home` lists capped and the policy panel only for policy roles; preferences of another user unreachable; client errors drop unknown fields, 429 after 20 per minute. OpenAPI regenerated |
| 3-2 | Generated TypeScript client in `ui/src/app/api` from the committed `docs/api/openapi.json` (**springdoc already done in Phase 1**); drift check | S | PROG | `npm run api:check` regenerates and fails on any difference |
| 3-3 | Angular workspace in `ui/`; `tokens.css` with the UI_STANDARD §3 names and neutral placeholder values; Stylelint rules (colour literals, px font sizes, `font-family` outside `tokens.css`); `ds-*` adapters; Storybook with the test runner and axe; Playwright with axe; budgets (`UI_INITIAL_JS_KB` 350, `UI_ROUTE_JS_KB` 150); production-build check for the dev identity; **CI job `ui` (your approval needed)** | M | PROG | A lint fixture with a hex colour fails; production build fails when `devIdentityInterceptor` is present; one adapter story passes axe |
| 3-4 | Shell, nav, context bar, as-of banner and read-only mode, `startPageGuard`, dev user picker, interceptors (errors, correlation id, dev identity), live announcer, `/settings` | M | NEW-10 | Component: `isHistorical` from the server's `businessToday`, not the browser; write controls absent from the DOM when historical; 412 message. Playwright + axe: start page respected after reload; historical banner via `?asOf=` |
| **3-5a** | `HierarchyStore` (flattened visible rows, LLD §7.1; pages per parent; caches per `asOf` / `recordedAsOf`) and `nx-hierarchy-tree` rendering (virtual scroll, "Show next 200", loading / error rows, shared-node indicator) | M | HIE-12 | Component: rows computed from the maps; load-more row on a partial page; page boundary; retry row; Storybook: every state, axe |
| **3-5b** | Tree keyboard (WAI-ARIA), type-ahead, in-tree search box and reveal (§7.2, bounded to 5 pages, then a pinned "found by search" row) | M | HIE-12 | Component: each key; type-ahead on visible rows; reveal 8 levels down; pinned row beyond 5 pages; search `q` of 1 character shows a message |
| 3-6 | Node panel and `nx-property-grid` (provenance markers stored / inherited with source link / derived / default, as-of) | M | HIE-12 | Component + Storybook + axe; Playwright S1-R3: a date before the leaf exists shows the parent without it |
| 3-7 | Add-leaf dialog (typed reactive form from `submit-form`), `TrayStore` (ETag chaining, idempotency key per click, 412 reload), tray, review and submit | M | SLICE-01 | Component: partial failure keeps added items and offers retry; Playwright S1-R4: happy path; missing required property blocks submit at the field; duplicate name shown at the name field |
| 3-8 | Worklist screen and `nx-worklist-table` (view chips with counts, search, model filter, keyset paging) | M | GOV-13 | Component + Storybook; Playwright: each chip shows the API count and rows; search and filter; paging with equal due dates |
| 3-9 | Request detail, `nx-workflow-timeline`, decision panel (refusal reasons in words, "Committed by policy" label) | M | SLICE-01, GOV-12 | Playwright S1-R5 (three users via the picker): approver sees it in Assigned, committer commits, steward sees "You submitted this request"; S1-R6: timeline shows the shadow evaluation |
| 3-10 | Home (OD-27): search box, worklist top 5, your requests, your hierarchies, governance panel for policy roles | S | NEW-10 | Playwright + axe; policy panel absent for a steward |
| 3-11 | SLICE-01 end-to-end suite S1-R2 … S1-R7 (leaf visible today, absent the day before; audit rows checked through the API), keyboard-only runs, axe on every page | M | SLICE-01 | Playwright, axe. **Perf traces written, tagged and not run (deferred)** |
| 3-12 | Records: UI_STANDARD mapping status, DEVELOPER_SETUP (Node.js), README, CHANGELOG, patterns P-26 / P-27, data model (V10), test report, summary | S | PROG | review |

**Why the split.** 3-5 is size L in the LLD, so I split it into 3-5a and 3-5b. The content and tests don't change. I'll add a *Built in …* note to the LLD, as I did for 2-8 in Phase 2. Nothing else in this plan departs from the LLD, so no new ADR is needed.

## Decisions I expect to need
- **No new ADR.**
- **Version choices are set by the open design-system decision (OD-02), not by me.** Until you answer it, I'll pin each tool's current release and record the versions in `ui/package.json` and the summary.
- **Choices within ADR-025 that I'll record in `patterns.md` as P-27:**
  - the TypeScript generator: `ng-openapi-gen`;
  - the Storybook accessibility check: the test runner with axe.

## New dependencies (your approval needed, CLAUDE.md rule 8)
| Dependency | Why | Where |
|---|---|---|
| **Node.js 24 LTS and npm** on this machine | Runs the Angular toolchain | Your machine (installed by you, or by me with `winget install OpenJS.NodeJS.LTS` if you allow it) |
| Angular CLI, framework and CDK: current major, pinned exactly (expected 21.x) | ADR-012; virtual scroll, a11y, overlay (C-2, C-3) | `ui/` |
| The Angular CLI's default unit-test runner for that major (Vitest from Angular 21) | ADR-025: no extra choice | `ui/` dev |
| `ng-openapi-gen` | Generates Angular `HttpClient` services and models from `openapi.json` (P-27). Pure Node, unlike `openapi-generator-cli`, which downloads a JAR. Unlike `openapi-typescript`, it generates Angular services as well as types | `ui/` dev |
| Storybook for Angular, its test runner and `axe-playwright` | UI_STANDARD §5 and §10: every component state, axe on every story | `ui/` dev |
| Playwright (`@playwright/test`, Chromium and Edge) and `@axe-core/playwright` | SLICE-01 journeys with several users, axe on pages | `ui/` dev |
| Stylelint with core rules only (no plugin) | Token enforcement (UI_STANDARD §3) | `ui/` dev |
| `pg_trgm` (PostgreSQL contrib, already in `postgres:16` and `postgres:16-alpine`) | In-tree search (OD-21) | `V10__ui_support.sql` |
| **Public npm registry** (`registry.npmjs.org`) | This machine has no organisation mirror. DEVELOPER_SETUP §2 will say to point npm at your mirror. Design-system packages (OD-02) will still come only from the internal registry and are never committed | network, at `npm install` |

**CI change (your approval needed):** a `ui` job in `.github/workflows/ci.yml` (Node 24; `npm ci`, lint, unit, build with budgets, Storybook tests; Playwright with the API and database from 3-11). It cannot run until a remote exists (OD-11).

## Risks, assumptions and questions
| # | Item | Handling |
|---|---|---|
| R-1 | The design system may support an older Angular major than the one I pin (OD-02, LLD C-1) | Standalone components, signals and `OnPush` exist from Angular 17. Stores keep the same public API if signals have to go (LLD R-2). A downgrade is a version change, not a redesign |
| R-2 | Placeholder tokens and adapters will look plain | Intended (UI_STANDARD §1). Visual sign-off is a gap until OD-02 to OD-04 |
| R-3 | End-to-end runs need Docker (database), the API and the dev server together on a 3.7 GiB Docker allowance | Only PostgreSQL runs in Docker; the API and worker are JVMs on the host. One worker, in-process engine |
| R-4 | The local API uses the owner account, so end-to-end runs do not prove least privilege | The JUnit tests already prove it (as `nexus_api_test`). Listed as a gap |
| R-5 | Merging to `main` | Unchanged: needs the Audit-Risk review of ADR-021 and ADR-023, or your waiver (OD-18a) |
| A-1 | LLD assumptions C-1 to C-8 hold | As the LLD says |

**Questions for you**
1. Do you approve this plan, including the 3-5 split?
2. **Node.js 24 LTS:** will you install it, or may I run `winget install OpenJS.NodeJS.LTS`?
3. Do you approve the UI dependencies above, and installing them from the public npm registry on this machine?
4. Do you approve adding the `ui` job to CI (a CI change; it runs once a remote exists)?

## Scope extension (repository owner, 2026-11-12: "lets add all of UI into phase-3 and complete it")
The owner moved the remaining editing screens for actions the API already has (Phase 1) into Phase 3. They were planned
for Phase 5 (HIE-02 UI, property editing). Every edit still becomes an item of a draft change request in the tray; nothing
writes live data (UI_STANDARD §6).

| # | Increment | Capabilities | Tests |
|---|---|---|---|
| 3-13 | Backend: `GET /hierarchies/{code}/nodes/{id}/impact` (descendants by primary links, placements, top node); seed: `MAINTAIN` model, an all-hierarchy steward | HIE-02 | JUnit |
| 3-14 | Generic tray action (`TrayStore.addChange`); drafts not started by add-leaf use the `MAINTAIN` model | HIE-02, PRP-01 | unit |
| 3-15 | Edit details (`update_node`), edit or clear a property value (`set_property` / `clear_property`) from the property grid | HIE-02, PRP-01 | unit, stories, e2e |
| 3-16 | Place under another parent (`insert_node`, shared), "Move to…" with a searchable target picker (`move_node`), remove from the hierarchy (`remove_node`, cascade choice), delete (`delete_node`); each with an impact preview in numbers before confirming | HIE-02 | unit, e2e |
| 3-17 | New hierarchy (`add_hierarchy`) for users with propose rights on every hierarchy | HIE-01, HIE-02 | e2e |

**Gaps that stay:** property edit permissions by category (PRP-09, SEC-03; Phase 5): until then anyone who may propose on a
node may edit any of its stored properties, and the server enforces the rest. The impact preview counts descendants and
placements; inherited-value changes and validation findings show on Review and submit (trial apply), not in the preview.
Drag and drop is not built (UI_STANDARD §6 makes it optional; "Move to…" is the required way).

## Second scope extension (repository owner, 2026-11-12: "except for AI suggestions and Notifications, implement everything else")
| # | Increment | Capabilities | Tests |
|---|---|---|---|
| 3-18 | Property edit rights by category: `mdm.user_role.category_codes` (V10), API check on `set_property` / `clear_property`, categories in `/me` grants, Edit hidden without the right (ADR-036) | PRP-09, SEC-03 (edit) | pgTAP, JUnit, unit, e2e |
| 3-19 | Node history: `GET /nodes/{id}/history` (keyset-paged events: attribute, placement and property versions with valid and recorded periods and their change request); History tab | QRY-04, AUD-01 (read) | JUnit, e2e |
| 3-20 | Ownership view: `GET /nodes/{id}/owners` and `/holdings` (direct edges at the slice, paged); Ownership tab with an accessible table and a simple SVG diagram (no graph library: OD-05 open) | NEW-02 (view only) | JUnit, unit, e2e |
| 3-21 | Before/after view (`nx-diff-view`, side-by-side and inline, change tokens + icons) on Review and the request page | NEW-10 | unit, stories, e2e |
| 3-22 | Drag and drop in the tree onto another node opens "Move to…" with the target set (never the only way) | HIE-02 | e2e |

**Still not built:** AI suggestions (Phase 7, deferred) and notifications (GOV-08 / GOV-16), as the owner said. UBO results,
cross-holding calculation and editing ownership stay in Phase 6; read filtering by property category stays in Phase 5.
