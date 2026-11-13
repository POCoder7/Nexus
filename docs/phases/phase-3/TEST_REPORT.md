# Phase 3 — Steward UI: test report

- **Date:** 2026-11-12; versions (third scope extension) added 2026-11-13 · **Code state:** the Phase 3 commits on `feature/NEW-10-phase-3-steward-ui` (see SUMMARY)
- **Machine:** Windows 11 Home, Docker Desktop (Engine 29, WSL 2, 3.7 GiB), JDK Temurin 21, Maven 3.9.9 (wrapper), Node.js 26.13.1 LTS, npm 11.20, Chromium (Playwright 1.64)
- **Data:** synthetic only (`ui/e2e/seed.sql`, every name prefixed `E2E`; unit and story fixtures named `Synthetic …`; no client, account or personal data)

## Commands and results

| Suite | Command | Passed | Failed | Skipped |
|---|---|---|---|---|
| Migrations V1–V11 + pgTAP | `scripts\db-test.ps1` (fresh database) | 411 | 0 | 0 |
| API build + tests | `cd services/mdm-api; .\mvnw.cmd -B verify` | 126 | 0 | 0 |
| UI style lint + self-test | `cd ui; npm run lint` | all files clean; 4/4 forbidden declarations refused | 0 | — |
| Generated client drift | `npm run api:check` | 116 files match `docs/api/openapi.json` | 0 | — |
| UI unit and component tests (Vitest) | `npm test` | 64 | 0 | 0 |
| Production build + budgets + dev-identity check | `npm run build` | initial JS 129.9 kB compressed (budget 350), every lazy chunk < 150 kB, no dev identity | 0 | — |
| Storybook stories with axe (WCAG 2.1 AA) | `npm run build-storybook; npm run test:storybook` | 49 | 0 | 0 (one earlier run under load: 6 failed, cause not captured; clean rerun 35/35 before the versions stories) |
| End-to-end journeys with axe (Playwright, Chromium) | `npx playwright test` | 38 | 0 | 1 tagged `@perf`, excluded (deferred) |
| Performance (`@perf`, LLD §10) | `E2E_PERF=1 npx playwright test` | — | — | **not run** (deferred by the repository owner) |
| Edge | `E2E_EDGE=1 npx playwright test` | — | — | **not run** (Chromium only on this machine run) |

## Traceability (LLD §13 and the scope extension)

| Capability | Criterion | Tests | Result |
|---|---|---|---|
| HIE-12 | Lazy paging, "Show next 200" to the last page, page boundary | e2e 02 `pages a large sibling set…` (450 children, 3 pages, no "show next" after the last); unit `HierarchyStore` (6) | Pass |
| HIE-12 | Search reveals a node deep down; bounded reveal pins beyond 5 pages | e2e 02 (9 levels down, selected, URL carries the node); unit store `pins a search result…` | Pass |
| HIE-12 | Type-ahead; keyboard tree model; 1-character search refused with a message | e2e 02 keyboard-only, one-character; unit tree (8, incl. Space during type-ahead) | Pass |
| HIE-12 | Property grid: stored / inherited with source link / derived / default / not set; grid keyboard | e2e 03; unit grid (4); stories 4 with axe | Pass |
| HIE-12 | Largest hierarchy within targets (`UI_TREE_EXPAND_MS`, 50 000 siblings) | `@perf` test written | **Not measured** (deferred) |
| GOV-13 | Each chip shows the API count; search and model filter; empty view in words | e2e 05 (counts per view equal `GET /worklist` counts; drafted view, search, model filter) | Pass |
| GOV-13 | Paging with equal due dates | API test `WorklistApiTest` (Phase 2); UI "Load more" keyset | Pass (API); UI paging exercised in stories |
| SLICE-01 S1-R2 | Lazy paging, largest sibling set | as HIE-12 | Pass (functional); timing not measured |
| SLICE-01 S1-R3 | Node panel as of a chosen date | e2e 04 S1-R7 (parent without the leaf the day before); e2e 01 historical view | Pass |
| SLICE-01 S1-R4 | Add leaf with required properties; missing required blocks at the field; duplicate name reported and blocks submit | e2e 04 (three tests); unit tray (4) | Pass |
| SLICE-01 S1-R5 | Approver sees it in Assigned; committer commits; requester sees the reason | e2e 04 (three users) | Pass |
| SLICE-01 S1-R6 | Shadow evaluation on the timeline | e2e 04 (`E2E_SHADOW: would … (shadow mode, no effect)`); unit timeline | Pass |
| SLICE-01 S1-R7 | Leaf today, absent the day before; audit rows; no self-approval | e2e 04 (as-of view, search, `mdm.audit_log` rows, `decisionBasis` human_review) | Pass |
| SLICE-01 AC 1 | Golden inherited/derived values vs legacy | — | **Gap**: Phase 4 golden framework and a masked extract (OD-31, OD-32) |
| NEW-10 | Shell, Home, start page after reload; historical banner and no write controls | e2e 01 (3); unit `ContextStore` (3), node panel (4) | Pass |
| NEW-10 | Governance panel only for policy roles; Home search opens a node | e2e 05; API `UiSupportApiTest` | Pass |
| HIE-02 / PRP-01 (scope extension) | Edit a property value; edit details; move with a target picker; place under a second parent (shared); remove and delete preview impact in numbers and need confirmation; new hierarchy; the request is approved, committed and every change is in the data | e2e 06 (7); unit dialog (5), grid editable, tray `addChange`; API impact test | Pass |
| QRY-04 (second extension) | History: every version of details, placements and properties with periods and request; paged; unreadable is 404 | JUnit `historyListsEveryVersionOfTheNodeAndPages`; e2e 07 | Pass |
| NEW-02 view (second extension) | Direct owners and holdings at a date, tables and diagram, two decimals | JUnit `ownersAndHoldingsListDirectEdges`; unit ownership; story 2; e2e 07 | Pass (view only; UBO in Phase 6) |
| PRP-09 / SEC-03 edit (ADR-036) | A Finance-only grant may edit Finance properties, not Legal; structural actions unaffected; Edit hidden in the UI | pgTAP 21 (+2); JUnit `aCategoryLimitedGrantMayEditOnlyItsCategories`; unit context store; e2e 07 | Pass |
| Diff view (second extension) | Side-by-side and inline, change kind in words and icons, findings on the item | unit item list (2); stories 3; e2e 07 | Pass |
| Drag and drop (second extension) | Dropping a node on another opens "Move to…" with the target chosen; keyboard path unchanged | e2e 07 | Pass |
| VER-01 (third extension, ADR-037) | A version is created by a version administrator only; a copy shows its base's picture at creation (children and properties at both slices) and takes its base's date; names unique; create is idempotent with a key | pgTAP 22; JUnit `createCopyAndRename`, `createIsIdempotentWithAKey`, `aCopyShowsItsBasesPictureAtCreation`, `theListIsPagedByBusinessDateThenNameAndNeedsRead`; unit store, table, picker; stories (dialogs, page, picker); e2e 08 (create, copy, edit, a viewer sees no admin actions) | Pass; **golden** (version list and node counts against DRM) waits for Phase 4 |
| VER-02 (third extension, ADR-037) | Working → submitted → finalized → expired, reopen back to working; the pin is set at submit, cleared at reopen and kept after; submit refused while requests are in flight (reason with counts); the submitter cannot finalize (four eyes), people only; a request cannot be raised in, moved to or advanced in a version that is not working; a change committed after the freeze is not in the picture; a correction after finalize leaves the finalized picture unchanged; the picture is read-only; a change effective after its version's date gets the `NEXUS.VERSION_DATE` warning | pgTAP 22 (every code, the CHECK, the append-only log, the freeze lock and its `40001` retry, privileges); JUnit `theLifecycleWithReasonsAndFourEyes`, `reopeningClearsThePin`, `submitIsRefusedWhileRequestsAreInFlightAndADraftCanMove`, `aCorrectionAppliedAfterFinalizeLeavesTheFinalizedPictureUnchanged`, `theWorkingVersionPreferenceAndItsFallback`, `versionAdministratorsAreListedInTheirPermissions`; unit `ContextStore` (picture slice, banner), tray store (move after N2703); e2e 08 (six tests, two administrators) | Pass; **golden** (exports of past finalized versions) waits for Phase 4 and Phase 8 |
| Controls | Edits only through the tray; read-only historical views; dev identity absent from production; no business rules in the UI (reasons from the server: `whyNot`) | e2e 01, 04; build check; unit decision panel | Pass |
| Accessibility | axe on every page and story; keyboard-only journeys; focus to heading on page change, back to trigger on dialog close | e2e (every spec calls axe), 30 stories, e2e 02/03 keyboard, e2e 04 focus return | Pass; **manual screen-reader check not done** (needs a person) |
| Standards | Tokens only in styles | `npm run lint` + self-test | Pass |

## Defects found by tests during the phase (fixed)
1. **API (from Phase 1): a property could not be set on a node added earlier in the same request** (`change_item.not_in_hierarchy`), so a leaf and its required properties could not go into one request. The API's early check now counts nodes added by earlier items; apply and the trial apply still check every item in order. Regression: `UiSupportApiTest.propertiesCanBeSetOnANodeAddedEarlierInTheSameRequest`.
2. **Test fixtures (Phase 1):** `HierarchyApiTest` and `NodePropertiesApiTest` took the UTC session date and failed between 00:00 UTC and midnight New York; they now use the business day.
3. **Tree:** Space always meant "select", so typing a name with a space broke type-ahead (WAI-ARIA: Space is part of a type-ahead in progress).
4. **Shell:** focus jumped to the page heading on every navigation, including selecting a node (a query parameter), so keyboard users lost their place in the tree.
5. **Add-leaf form:** optional properties were pre-filled with their defaults, which then became stored values (provenance changed from "default" to "stored").
6. **Request page:** after submit it did not refresh, so the stage the engine opened a moment later showed as "Not started".
7. **Accessibility (axe):** property-grid category rows had no cell children; worklist table had non-row content inside `role=table`; virtual-scroll viewports were not keyboard-focusable; the change dialog's hidden submit button was announced as a second "Add to request".
8. **Generated client:** springdoc answered `*/*`, so every body was read as a blob (default media type now JSON).

Changes to tests during the phase, shape or setup only: the paging test scrolls the viewport (virtual scrolling renders only visible rows); the worklist test uses the Drafted view (the committed request has left the open-work views); two locators use accessible names that include "(Required)". Journey 08 (versions): the business-date field is found by role and accessible name, the status badge is matched with "contains" because it carries an icon, and the tray is expected to name no version while the draft is in the version the context bar shows (LLD V.6). No assertion was removed or weakened.

## Explicit gaps
1. **Performance not measured** (deferred to the end of the build by the repository owner): `@perf` tests written, not run.
2. **Golden parity** (SLICE-01 acceptance criterion 1, S1-R1 load; VER-01 version list and node counts; VER-02 exports of finalized versions) waits for Phase 4 and masked extracts, and Phase 8 for version exports.
3. **Visual sign-off** waits for the design system (OD-02 to OD-04): placeholder tokens and adapters.
4. **Manual screen-reader check** of the custom components (UI_STANDARD §8) needs a person.
5. **Least privilege in end-to-end runs:** locally the API uses the docker-compose owner account; least privilege is proven by the JUnit suite (`nexus_api_test`).
6. **Read filtering by property category** (read side of SEC-03) stays in Phase 5; edit rights by category are built (ADR-036). The UI hint for edit rights reads `STEWARD` grants (the only role with PROPOSE today); the server decides.
7. **Impact preview** counts descendants and placements; inherited-value changes appear as findings on Review and submit.
8. **CI has never run on GitHub** (the remote exists since 2026-11-12, OD-11, but no pull request is open and `main` waits for the owner's push); the `ui` job is written.
9. **Edge** not run on this machine (Chromium only).
10. **Ownership** is a view of direct edges: effective ownership, UBO results, cross-holdings and editing ownership are Phase 6; the diagram is a simple SVG until the graph library is chosen (OD-05).
11. **Drag and drop** is mouse only and opens "Move to…"; dropping does not reorder siblings.
12. **Definitions drift (D-08):** a frozen version picture is read with today's definitions (properties, rules, hierarchy settings); only facts are frozen. Known limitation of the slice model (ADR-037, P-02).
13. **No index on `mdm.change_request(version_id)`:** counting a version's requests in flight (submit refusal, `whyNot`) scans the table. Acceptable at test volumes; listed for Phase 9 hardening.
14. **Audit-Risk confirmation of ADR-037 D4** (four eyes and people only for finalize; OD-45a) is pending and needed before merging to `main`.

## Gate result
All suites that ran are green (pgTAP 411, JUnit 126, UI unit 64, stories 49, end to end 38, lint, contract and build checks); every
in-scope criterion, including the three scope extensions (the third is versions, VER-01 and VER-02), is covered by a passing test or listed above as an explicit, explained gap.
**Gate: pass with the gaps above**, subject to your approval.
