# Phase 3 — Steward UI: low-level design

- **Status:** Approved 2026-11-11 (consistency fixes CR-nn applied the same day, see `../CONSISTENCY_REVIEW.md`)
- **Migration rule (CR-07):** where this design says "edit Vn", that is allowed only while no shared environment exists (CLAUDE.md rule 6, OD-18). If one exists when this phase is built, the same change goes into a new V-numbered migration (`ALTER` / `CREATE OR REPLACE`). What counts as shared: OD-44.
- **Phase goal (BUILD_PROTOCOL §2):** the first slice is usable by a person.
- **Exit criteria:** tree browsing with paging, node panel, worklist, add-leaf form; UI tests pass; SLICE-01 acceptance
  criteria met on synthetic data.
- **Binding standard:** `docs/design/UI_STANDARD.md` (§14 below shows compliance screen by screen). Landing page:
  OD-27, prototype `prototypes/landing.html`. Reads with the Phase 1 and 2 LLDs (APIs), ADR-012, ADR-015, ADR-018, ADR-022.

---

## 1. Purpose and scope

**Goal.** A steward signs in, lands on Home, browses a large hierarchy, inspects a node's properties and where each value
comes from, drafts an add-leaf request with the required properties, submits it; an approver and a committer act from
their worklists; everyone can view any past date read-only.

| ID | Decision | Phase 3 delivers |
|---|---|---|
| HIE-12 | Parity | Virtualised lazy tree, paged siblings, in-tree search, property grid |
| GOV-13 | Parity (API in Phase 2) | Worklist screen with the nine views, counts, search, model filter |
| SLICE-01 | Spec (draft) | The journeys S1-R2 to S1-R7 on synthetic data (S1-R1 load and the golden criterion need Phase 4) |
| NEW-10 | New | Shell, Home (OD-27), change-request tray, request detail with workflow timeline, start-page preference |
| GOV-12 | Improve (Phase 2) | "Committed by policy" label with the policy and evaluation; shadow summary panel for policy roles |

**Pending decision, not built (§15):** the History tab (QRY-04), Ownership tab (Phase 6), move/insert/remove screens
and impact preview (HIE-02 UI beyond add-leaf; Phase 5), AI suggestion cards (Phase 7), notifications (GOV-08).

**Dependencies.** Phase 1 API (reads with provenance, change requests, entitlements), Phase 2 API (submit with model,
worklist, decisions, instance view). Design system details OD-02 to OD-04 are open: this design targets the Nexus token
layer and the Angular CDK, with one adapter per design-system component so the swap is local (§3.4).

## 2. Confidence and assumptions

**Confidence: Medium for structure and behaviour; Low for visual detail** until the design-system packages, tokens and
component catalogue arrive (OD-02 to OD-04).

| # | Assumption | Effect if wrong |
|---|---|---|
| C-1 | The design system supports an Angular major with standalone components and signals (UI_STANDARD §2 allows store services without signals otherwise) | Stores switch from `signal()` to `BehaviorSubject`; component APIs unchanged |
| C-2 | The design system has no tree with lazy loading and virtual scrolling (OD-04) | If it has one, `nx-hierarchy-tree` wraps it instead of `cdk-virtual-scroll-viewport` |
| C-3 | The design system has a table but not virtual scrolling (OD-04) | Worklist table uses CDK virtual scroll inside the design-system table styles |
| C-4 | Users have desktop screens ≥ 1280 px; tablet ≥ 768 px supported (UI_STANDARD §4) | — |
| C-5 | Performance budgets: `UI_INITIAL_JS_KB` 350 (compressed), `UI_ROUTE_JS_KB` 150 per lazy feature, `UI_TREE_EXPAND_MS` 100 after the response, `UI_INP_MS` 200 | Budgets enforced in `angular.json`; values to confirm (OD-10) |
| C-6 | Browser support: current Edge and Chrome (organisation standard unknown, UI_STANDARD §12 item 6) | Add Firefox/Safari to the E2E matrix |
| C-7 | Until OD-06, the UI runs only in `local` and `test` with the development identity (Phase 1 `LocalDevActor`): a dev-only user picker sends `X-Nexus-User` | Phase 9 replaces it with the organisation's Angular auth library |
| C-8 | UI strings in English only, externalised (UI_STANDARD §9) | Translations added later without template changes |

**Human decisions this phase waits on:** OD-02/03/04 (packages, tokens, components) before visual sign-off; OD-06 for any
shared environment; approval of the UI dependencies and the CI job in the Phase 3 plan (ADR-025).

## 3. Component design

Angular workspace in `ui/` (CLAUDE.md layout). Feature folders per UI_STANDARD §9.

```text
ui/
  src/app/
    core/        shell, context bar, auth (dev interceptor), error handling, i18n, preferences store
    shared/      design-system adapters (ds-*), formatting pipes, nx-* presentational components
    home/        Home (default start page)
    hierarchy/   workspace: tree, node panel, property grid, add-leaf form
    change-request/  tray, review and submit, request detail, workflow timeline
    worklist/    worklist screen
    api/         generated OpenAPI client (not hand-edited) + thin facades
  src/styles/tokens.css   Nexus tokens mapped to design-system tokens (one file, UI_STANDARD §3)
  .storybook/  stories for every custom component and state
  e2e/         Playwright journeys (ADR-025)
```

```mermaid
flowchart TB
  Shell[AppShellComponent] --> Ctx[ContextBarComponent]
  Shell --> Nav[NavComponent]
  Shell --> Out((router outlet))
  Out --> Home[HomePage]
  Out --> WS[HierarchyWorkspacePage]
  Out --> WL[WorklistPage]
  Out --> CR[ChangeRequestPage]
  WS --> Tree[nx-hierarchy-tree]
  WS --> NP[NodePanelComponent] --> PG[nx-property-grid]
  WS --> ALF[AddLeafDialogComponent]
  Shell --> Tray[nx-change-request-tray]
  CR --> TL[nx-workflow-timeline]
  CR --> DP[DecisionPanelComponent]
  WL --> WT[nx-worklist-table]
  subgraph stores[Store services, signals]
    CS[ContextStore] ; PS[PreferencesStore] ; HS[HierarchyStore] ; NS[NodeStore] ; TS[TrayStore] ; WLS[WorklistStore]
  end
```

### 3.1 Core
| Class | Responsibility | Key API | Must not |
|---|---|---|---|
| `ContextStore` | Global context: version, as-of date, hierarchy (UI_STANDARD §4) | `version()`, `asOf()`, `isHistorical()` (computed: `asOf ≠ businessToday`), `setAsOf(d)` | Compute "today" from the browser zone: it uses `GET /me` → `businessToday` from the server (ADR-018) |
| `PreferencesStore` | Start page, last hierarchy, density | `startPage()`, `setStartPage(p)`, `rememberHierarchy(code)` (debounced PUT) | Store in browser storage (server-side, OD-27) |
| `startPageGuard` | On `/` redirect to the user's start page | `CanActivateFn` | Authorise (server does) |
| `apiErrorInterceptor` | Maps Problem Details to `UiError {title, detail, reason, fieldErrors}`; 401 → sign-in; 412 → "This was changed by someone else. Reload to see the latest version." | `HttpInterceptorFn` | Swallow errors |
| `correlationIdInterceptor` | Adds `X-Correlation-Id` per request; shows it in error states | — | — |
| `devIdentityInterceptor` | `local`/`test` builds only: adds `X-Nexus-User` from the dev user picker | — | Ship in production builds (file replacement in `angular.json`) |
| `LiveAnnouncer` use | Announces load completion, validation results, request status changes (UI_STANDARD §8) | — | — |

### 3.2 Features
| Feature | Container (fetches) | Presentational (inputs/outputs) | Store |
|---|---|---|---|
| Home | `HomePage` | `nx-search-box`, `nx-worklist-mini`, `nx-my-requests`, `nx-hierarchy-list`, `nx-policy-summary` | `HomeStore` (one `GET /home`) |
| Hierarchy workspace | `HierarchyWorkspacePage` | `nx-hierarchy-tree`, `NodePanelComponent`, `nx-property-grid`, `AddLeafDialogComponent` | `HierarchyStore` (tree nodes, pages, expanded set, selection), `NodeStore` (detail by node + asOf) |
| Change request | `ChangeRequestPage`, `ReviewSubmitPage` | `nx-change-request-tray`, `nx-item-list`, `nx-workflow-timeline`, `DecisionPanelComponent` | `TrayStore` (current draft request id, items, ETag), `RequestStore` |
| Worklist | `WorklistPage` | `nx-worklist-table`, `nx-view-chips` | `WorklistStore` (view, search, model, pages, counts) |

### 3.3 Custom components (UI_STANDARD §5 inventory only)
| Component | Inputs → outputs | Built on | Key behaviour |
|---|---|---|---|
| `nx-hierarchy-tree` | `rows: FlatTreeRow[]`, `selectedId`, `readOnly` → `expand(id)`, `select(id)`, `loadMore(parentId)`, `typeahead(text)` | `cdk-virtual-scroll-viewport` (fixed row height `--nx-density-row-height`), WAI-ARIA tree | Flattened visible rows; "Show next 200" row per partially loaded parent; shared-node indicator (icon + text "Shared"); type-ahead on visible rows; in-tree search reveals a match by loading its ancestor path |
| `nx-property-grid` | `properties: ResolvedProperty[]`, `editable` → `edit(code)` | design-system table + WAI-ARIA grid | Grouped by category; provenance marker per value (icon + text + `--nx-color-provenance-*`); "Inherited from <node>" link; required / read-only states |
| `nx-worklist-table` | `rows`, `loading`, `hasMore` → `open(id)`, `loadMore()` | design-system table + CDK virtual scroll (C-3) | Columns configurable; status = icon + text; overdue labelled; selection persists across pages |
| `nx-change-request-tray` | `count`, `items` → `review()` | design-system panel/drawer | Always visible in the shell when a draft exists; text "Nothing changes until governance approves." |
| `nx-workflow-timeline` | `stages`, `decisions`, `evaluations` | design-system list | Read-only; stage status icon + text; "Committed by policy <name>" with link to the evaluation; states announced |

Not built in Phase 3: diff/compare view (request detail shows a simple before → after list per item), ownership graph, evidence viewer.

### 3.4 Design-system adapters
`shared/ds/` holds thin wrappers (`ds-button`, `ds-input`, `ds-select`, `ds-dialog`, `ds-table`, `ds-tabs`, `ds-badge`,
`ds-date-input`, `ds-toast`, `ds-header`). Until OD-02 they render plain accessible HTML styled only with Nexus tokens and
neutral placeholder values (UI_STANDARD §1, ADR-012). When the packages arrive, each wrapper's template switches to the
design-system component; feature code does not change.

## 4. Data design

UI state is in memory (stores). Two backend additions:

```sql
-- new file V10__ui_support.sql
CREATE TABLE mdm.user_preference (
  user_id           uuid PRIMARY KEY REFERENCES mdm.app_user,
  start_page        text NOT NULL DEFAULT 'home' CHECK (start_page IN ('home','hierarchies','worklist')),
  last_hierarchy_id uuid REFERENCES mdm.hierarchy,
  density           text NOT NULL DEFAULT 'compact' CHECK (density IN ('compact','comfortable')),
  updated_at        timestamptz NOT NULL DEFAULT now()
);  -- not governed data; nexus_api INSERT/UPDATE; the API writes only the caller's own row

CREATE EXTENSION IF NOT EXISTS pg_trgm;   -- PostgreSQL contrib (OD-21: PostgreSQL search first); approve in the Phase 3 plan
CREATE INDEX node_attr_name_trgm ON mdm.node_attr USING gin (node_name gin_trgm_ops) WHERE upper_inf(recorded_period);
```
No bitemporal facts change. Volumes: one preference row per user.

## 5. Interface design

### 5.1 New endpoints (backend, Phase 3)
| Endpoint | Purpose | Auth | Response |
|---|---|---|---|
| `GET /me` (extended) | adds `businessToday`, `businessTimeZone`, `preferences`, `permissions` per readable hierarchy | actor | `{actor, businessToday, businessTimeZone, preferences, grants}` |
| `PUT /me/preferences` | start page, last hierarchy, density | actor (own row) | 200 |
| `GET /home` | bounded summary: worklist top 5 + counts per view; own requests (counts by status, latest 5); readable hierarchies (≤ 10: last used first, then by `sort_seq`) with open-request counts; shadow summary rows (only for `POLICY_ADMIN` or `POLICY_APPROVERS` members) | actor | one object; each list capped (no paging needed) |
| `GET /hierarchies/{code}/search?q&limit&asOf&recordedAsOf` | HIE-12 in-tree search by name or description (trigram) | READ | `{items: [{nodeId, name, path: [{nodeId, name}]}], nextCursor}`; `q` ≥ 2 characters; `limit` ≤ 50 |
| `GET /hierarchies/{code}/nodes/{id}/path?asOf&recordedAsOf` | Ancestor path to reveal a node in the tree | READ | `{path: [{nodeId, name}]}` (primary placement) |
| `GET /workflow/models/{code}/submit-form?hierarchy` | Properties the submit task lets the steward set, with required flags (GOV-03 infrastructure) | PROPOSE | `{properties: [{code, label, dataType, required, listValues?}]}` |
| `GET /change-requests/{id}` (extended) | adds `workflowInstanceId` (root instance) and `items[].before` (from `payload.expected`) for the request page | as Phase 1 | — |
| `POST /client-errors` | Client error reports (§11): `{status, type, correlationId, route}` only | actor; 20 per minute per user | 202 |

All other calls use the Phase 1 and 2 endpoints (no change). The client is generated from the OpenAPI document (ADR-025).

### 5.2 API calls per interaction
| Interaction | Calls | Notes |
|---|---|---|
| Sign in / open app | `GET /me` | Sets context `businessToday`, start page |
| Land on Home | `GET /home` | One call |
| Open hierarchy | `GET /hierarchies/{code}`; `GET …/children?parentId=top&limit=200`; `PUT /me/preferences` (debounced 2 s) | |
| Expand node | `GET …/children?parentId&limit=200` | Cached per (hierarchy, parent, asOf, recordedAsOf) for the session |
| Show next 200 | `GET …/children?…&cursor=` | |
| Select node | `GET /nodes/{id}?hierarchy&asOf` | |
| Search in tree | `GET …/search?q` (debounced 300 ms) → on choose: `GET …/path`, then children of each ancestor not yet loaded | |
| Change as-of date | Invalidates tree and node caches; reloads visible pages | |
| Add leaf | `GET /workflow/models/{code}/submit-form`; if no draft: `POST /change-requests`; `POST …/items` (add_node), `POST …/items` × n (set_property) | `If-Match` from `TrayStore`; `Idempotency-Key` per click |
| Review and submit | `POST …/validate`; `POST …/submit` | Findings shown per field and in a summary |
| Worklist | `GET /worklist?view&search&model&limit=50&cursor` | Counts from the same response |
| Open request | `GET /change-requests/{id}`, `…/items`, `GET /workflow/instances/{instanceId}` | |
| Decide | `POST /workflow/stages/{id}/decision` | Refusal reason shown inline |

## 6. Behaviour

### 6.1 Add a leaf (SLICE-01 S1-R4)
```mermaid
sequenceDiagram
  autonumber
  actor S as Steward
  participant UI as Angular UI
  participant API as mdm-api
  S->>UI: select limb node → "Add child"
  UI->>API: GET /workflow/models/ADD_LEAF/submit-form?hierarchy=…
  UI-->>S: form: name, description, kind, leaf (default yes), required properties
  S->>UI: fill, "Add to request"
  alt no draft request
    UI->>API: POST /change-requests {version, title (pre-filled "Add <name> under <parent>"), riskTier, effectiveFrom = businessToday, workflowModelCode}
  end
  UI->>API: POST /items add_node (If-Match)
  UI->>API: POST /items set_property × n (If-Match, chained ETags)
  UI-->>S: tray shows 1 + n items; toast "Added to your draft request"
  S->>UI: tray → "Review and submit"
  UI->>API: POST /validate
  UI-->>S: errors block submit (field + summary); warnings shown
  S->>UI: "Submit request"
  UI->>API: POST /submit (If-Match)
  UI-->>S: request page: status In review, timeline at Approve
```
Partial failure (an item call fails after the request exists): the tray shows what was added and the error for the rest;
the user retries the failed items (each call is idempotent by key).

### 6.2 UI states for every view (UI_STANDARD §6)
| View | Loading | Empty | Error | Read-only (historical) |
|---|---|---|---|---|
| Home | skeleton cards | "No requests need you" + quick actions | per card, with retry | banner; quick actions hidden |
| Tree | skeleton rows; per-parent spinner row | "This node has no children" | inline row "Couldn't load children. Retry" | edit actions hidden; banner |
| Node panel | skeleton grid | "No properties apply here" | panel message with correlation id | "Edit" hidden; values still show provenance |
| Add-leaf form | — | — | field errors + summary; server errors mapped to fields by `errors[].field` | not reachable |
| Worklist | skeleton rows | per view, e.g. "Nothing is overdue" | inline with retry | unaffected (worklist is current state) |
| Request page | skeleton | — | 404 "This request doesn't exist or you can't see it" | — |

### 6.3 Historical view
Setting "Viewing as of" to any date ≠ `businessToday` sets `isHistorical`; the shell shows the persistent banner; every
write control is removed from the DOM (not just disabled) and the tray is hidden. The URL carries `?asOf=` so a link opens the same view.

## 7. Algorithms

### 7.1 Flattened lazy tree
```text
state: nodes: Map<id, {id, name, parentId, depth, hasChildren, shared, active}>
       children: Map<parentId, {ids: id[], nextCursor: string|null, loading: boolean}>
       expanded: Set<id>
visibleRows() (computed signal):
   rows = []
   walk(id): rows.push(nodeRow(id)); if expanded.has(id):
               for c in children[id].ids: walk(c)
               if children[id].nextCursor: rows.push(loadMoreRow(id))
               if children[id].loading:    rows.push(loadingRow(id))
   walk(topId); return rows
```
Recomputed only when `nodes`, `children` or `expanded` change; O(visible rows). The virtual viewport renders only rows in
view, so 50 000 loaded siblings render ~40 DOM rows. Keyboard (WAI-ARIA tree): ↑/↓ move, → expand or first child, ←
collapse or parent, Home/End, Enter select, `*` expand siblings (loaded only), printable characters type-ahead over visible rows.

### 7.2 Reveal a search result
```text
path := GET …/path(node)
for each ancestor a in path (top → parent):
    expanded.add(a)
    if children[a] not loaded: load first page
    if node's next ancestor not in children[a].ids: load pages until found or nextCursor null
        (bounded by MAX_SIBLINGS / 200 requests; beyond 5 pages, insert the target as a pinned row "found by search" under a)
select(node); scroll into view; announce "Showing <name>"
```

### 7.3 ETag chaining in the tray
`TrayStore` keeps the latest `ETag`; each item call sends `If-Match` and stores the returned `ETag`. On 412 it reloads the
request and items, then asks the user to repeat the last action ("This request changed in another window.").

## 8. Patterns applied
| Pattern | Why |
|---|---|
| P-11 Keyset paging and lazy tree loading | Tree and worklist |
| P-18 Provenance | Property grid markers |
| P-21 Caching immutable slices | Children pages cached per session; for a pinned `recordedAsOf` they never go stale |
| P-26 Feature store with signals (new) | One store per feature; containers read signals; presentational components stay pure |
| P-27 Generated API client (new) | No hand-written DTOs; contract drift fails the build |

## 9. Security and controls
- No business rules in the UI: availability of actions comes from the server (`permissions` in `GET /me`, decision refusals); the UI explains, never decides (UI_STANDARD §6, §9).
- Edits only through the change-request tray; no control writes live data (UI_STANDARD §6).
- No `innerHTML` with dynamic content; Angular sanitisation not bypassed; no tokens in browser storage; preferences server-side.
- Dev identity only in `local`/`test` builds (C-7); production build fails if `devIdentityInterceptor` is present (build check).
- CLAUDE.md controls are server-side; the UI shows them: maker-checker and SoD refusals as text reasons; "Committed by policy" labels; historical views read-only.
- Data classification: property values of `is_pii` properties are not written to the browser console or error reports.

## 10. Performance and scale
| Target | Value | Design | Proof |
|---|---|---|---|
| Initial JS | `UI_INITIAL_JS_KB` 350 compressed | lazy routes per feature; design-system modules imported per component | Angular budgets fail the build |
| Tree expand (after response) | `UI_TREE_EXPAND_MS` 100 at 50 000 loaded siblings | flattened computed rows + virtual scroll | Playwright trace on a synthetic 50 000-child parent |
| Interaction | `UI_INP_MS` 200 | `OnPush` everywhere, `@for` with `track` | Playwright performance test |
| Children page round trip | `P95_CHILDREN_PAGE_MS` 300 (server, Phase 1) | — | Phase 1 perf test |

## 11. Observability
Client errors (status, `type`, correlation id, route; never values) sent to `POST /client-errors` (bounded, rate-limited,
logged server-side); page-load and interaction timings sampled at `UI_TELEMETRY_SAMPLE` (10 %). No third-party analytics.

## 12. UI design

### 12.1 Routes
| Route | Screen | Default for |
|---|---|---|
| `/` | redirect to start page (`startPageGuard`) | — |
| `/home` | Home | start page `home` (default) |
| `/hierarchies/:code?node=&asOf=` | Workspace | start page `hierarchies` (opens `last_hierarchy_id`) |
| `/worklist?view=&search=&model=` | Worklist | start page `worklist` |
| `/requests/:id` | Request detail, timeline, decision panel | — |
| `/requests/:id/review` | Review and submit | — |
| `/settings` | Preferences | — |

### 12.2 Screens (layouts follow the approved prototype, OD-27)
- **Shell:** design-system header (brand slot, app name "Nexus", environment badge, user menu); left nav: Home,
  Hierarchies, Worklist (count badge), Search, Ownership, Audit, Administration (items for later phases are shown only when the user has a permission for them); context bar; tray.
- **Home:** search box (nodes by name in the last hierarchy, request ids); next 5 worklist items with "All n"; your requests
  with status pills and "Committed by policy" labels; your hierarchies; governance panel for policy roles.
- **Workspace:** master-detail; tree (resizable, min 240 px) | node panel with tabs Properties and Relationships (History
  and Ownership tabs hidden until their phases); actions "Add child" (limbs only; leaves show the reason "Leaf nodes can't have children").
- **Add-leaf dialog:** name (required, unique message from server conflict), description, kind, "This is a leaf" (default on),
  required and optional properties from the submit form, effective date (default business today); buttons "Add to request", "Cancel".
- **Review and submit:** items list (before → after), validation findings with links to fields, "Submit request".
- **Worklist:** view chips with counts, search, model filter, table (request, title, stage, status, due, hierarchy, requester).
- **Request detail:** header (id with copy action, status, requester, effective date), items, `nx-workflow-timeline`,
  decision panel: "Approve", "Reject" (comment required) or the reason actions are unavailable (e.g. "You submitted this request").

### 12.3 Accessibility
WCAG 2.1 AA; WAI-ARIA tree and grid patterns; focus moved to the page heading on route change and back to the trigger on
dialog close; live region for loads, validation and status; reduced motion respected; status and provenance never by colour
alone; every flow keyboard-only in E2E tests; manual screen-reader check for each custom component before release.

## 13. Test design

Synthetic data: the Phase 2 fixtures plus a generated hierarchy `T_BIG` (one parent with 50 000 children, depth 12, 100 000 nodes).

| Capability | Criterion | Cases | Type |
|---|---|---|---|
| HIE-12 | Largest hierarchy loads and expands within targets | P: expand `T_BIG` parent, scroll to the end with "Show next" (all pages); B: page boundary row; P: in-tree search reveals a node 8 levels down; P: type-ahead; N: search `q` of 1 character refused with a message | Playwright + perf trace |
| HIE-12 | Property grid | P: provenance markers for stored / inherited (with source link) / derived / default; P: as-of change shows earlier values; A11y: grid keyboard | Component + Storybook + axe |
| GOV-13 | Views and counts | P: each chip shows the API count and rows; P: search and model filter; B: paging with equal due dates | Component + Playwright |
| SLICE-01 S1-R2 | Lazy paging, largest sibling set | as HIE-12 | Playwright |
| SLICE-01 S1-R3 | Node panel as of a chosen date | P: date before the leaf exists shows parent without it | Playwright |
| SLICE-01 S1-R4 | Add leaf with required properties; validations on submit | P: happy path; N: missing required property blocks submit with field message; N: duplicate name → conflict shown at the name field | Playwright |
| SLICE-01 S1-R5 | Right worklists; committed by an authorised human | P: approver sees it in Assigned; P: committer commits; N: steward without commit rights sees "You submitted this request" instead of Commit | Playwright (three users via the dev user picker) |
| SLICE-01 S1-R6 | Shadow evaluation recorded | P: timeline shows the policy evaluation "would commit" / "would route" | Playwright |
| SLICE-01 S1-R7 | Hierarchy, history, audit reflect the change; no self-approval | P: leaf visible today, absent as of the day before (acceptance criterion 3); P: audit rows exist (API check in the E2E test); "history" via as-of views only until QRY-04 | Playwright + API assertion |
| NEW-10 | Shell, Home, start page | P: start page preference respected after reload; P: historical banner + no write controls; A11y on every page | Playwright + axe |
| All custom components | Every state in Storybook (default, hover, focus, selected, disabled, loading, empty, error, read-only) | Story per state; axe on each story | Storybook test runner |
| Standards | Tokens only | Style lint fails on colour literals, px font sizes, font-family outside `tokens.css` | Lint in CI |

SLICE-01 acceptance criterion 1 (golden inherited and derived values) needs the masked extract and the Phase 4 golden
framework: listed as an explicit gap at the Phase 3 gate.

## 14. Compliance with UI_STANDARD
| Standard § | How Phase 3 complies |
|---|---|
| §1 Authority | Visual values only from tokens; design-system adapters (§3.4); no brand assets in the repo; placeholders until OD-02/03 |
| §2 Baseline | Angular at the design system's major (C-1), strict TypeScript, standalone + `OnPush`, signals + store services, typed reactive forms (add-leaf), lazy routes, guards for navigation only, `HttpClient` interceptors, generated client, CDK where needed |
| §3 Tokens | `ui/src/styles/tokens.css` with the `--nx-*` names from the standard; mapping column filled when OD-03 arrives; lint enforcement |
| §4 Layout | Shell, context bar with as-of banner and read-only mode, master-detail workspace, desktop-first with tablet collapse, compact density default + preference |
| §5 Components | Only inventory components built (tree, grid, worklist table, tray, timeline); each with Storybook states |
| §6 Interaction | Edits via tray; validation errors block, warnings don't; reasons for unavailable actions; "Committed by policy" label; global as-of; designed loading/empty/error states; toasts only for confirmations |
| §7 Content | `dd MMM yyyy` pipe; 24-hour times with zone; identifiers in the identifier style with copy action; verbs on buttons ("Add to request", "Submit request") |
| §8 Accessibility | §12.3 |
| §9 Code | Feature folders; container/presentational split; no business rules; `@for` with `track`; virtual scroll > 100 rows; budgets; no `innerHTML`; strings externalised |
| §10 Testing | Component tests for each custom component incl. keyboard; axe in CI; Playwright SLICE-01 journeys; Storybook as visual reference |
| §11 DoD | Checked at the Phase 3 gate, item by item, in the test report |
| §12 Obtain from UX | OD-02 to OD-06 remain open; listed in `OPEN_DECISIONS.md` |

## 15. Risks, open questions and alternatives
| # | Item | Handling |
|---|---|---|
| R-1 | Design-system packages may not be available to the build in time (OD-02) | Adapters render accessible placeholders; swap is per adapter |
| R-2 | The design system's supported Angular version may lack signals (C-1) | Store services keep the same public API |
| R-3 | Revealing a deep search result under a huge sibling set may need many pages | Bounded to 5 pages, then a pinned "found by search" row (§7.2) |
| R-4 | UI cannot be shown in a shared environment before OD-06 | Demonstrations run locally with synthetic data |
| Alt-1 | Load whole sub-trees into the client | Rejected: size at `MAX_NODES_PER_HIERARCHY` |
| Alt-2 | NgRx store | Rejected for now (UI_STANDARD §2: only with an ADR); signal stores suffice for these features |
| Alt-3 | Cypress for E2E | ADR-025 compares; Playwright recommended |

**Not built, pending decision:** History tab (QRY-04 / AUD-01), Ownership tab (NEW-02, Phase 6), move/insert/remove UI with
impact preview (HIE-02 UI; Phase 5 with the impact endpoint), AI suggestion cards (Phase 7), notifications inbox (GOV-08/16).

## 16. Work breakdown
| # | Increment | Size | Capabilities | Tests |
|---|---|---|---|---|
| 3-1 | Backend: `GET /me` extension, preferences, `/home`, search + path (pg_trgm), submit-form, client-errors | M | NEW-10, HIE-12 | JUnit |
| 3-2 | OpenAPI generation in the API build; generated client in `ui/api` (ADR-025) | S | PROG | build check |
| 3-3 | Workspace scaffold, tokens file, style lint, adapters, Storybook, axe, Playwright, CI job (approval needed) | M | PROG | CI |
| 3-4 | Shell, context bar, as-of banner and read-only mode, start-page guard, dev user picker | M | NEW-10 | Playwright, axe |
| 3-5 | `nx-hierarchy-tree` + `HierarchyStore` (lazy, paged, keyboard, search reveal) | L | HIE-12 | component, Storybook, perf |
| 3-6 | Node panel + `nx-property-grid` (provenance, as-of) | M | HIE-12 | component, Playwright S1-R3 |
| 3-7 | Add-leaf dialog, tray, review and submit | M | SLICE-01 | Playwright S1-R4 |
| 3-8 | Worklist screen + `nx-worklist-table` | M | GOV-13 | Playwright |
| 3-9 | Request detail, `nx-workflow-timeline`, decision panel | M | SLICE-01, GOV-12 | Playwright S1-R5, S1-R6 |
| 3-10 | Home (OD-27) | S | NEW-10 | Playwright |
| 3-11 | SLICE-01 end-to-end suite (S1-R2 … S1-R7), accessibility and performance runs | M | SLICE-01 | Playwright, axe, perf |
| 3-12 | Records: UI_STANDARD token mapping status, DEVELOPER_SETUP (Node.js), changelog, test report, summary | S | PROG | review |

Dependencies to approve in the Phase 3 plan (ADR-025): Node.js LTS and npm; Angular CLI and framework at the design
system's major; Angular CDK; Storybook; Playwright; axe-core; Stylelint; an OpenAPI generator for TypeScript and
`springdoc-openapi` for the API; `pg_trgm` extension.

## Built in Phase 3 (notes, 2026-11-12)
Differences from this design found while building; none changes a control, a guard or the scope.
- **3-5 split** into 3-5a (store and rendering) and 3-5b (keyboard, type-ahead, search reveal), as planned; same content and tests.
- **3-2:** springdoc and the committed `docs/api/openapi.json` already existed (Phase 1). Added `springdoc.default-produces-media-type:
  application/json`, because `*/*` made the generated client read every body as a blob. Generator: `ng-openapi-gen` (P-27).
- **`GET /me` adds `workingVersion`** (latest working version): the context bar shows it (§3.1 `version()`) and a new change
  request needs a version name, which the UI had no other way to know.
- **Instance view stages add `whyNot`**, the server's sentence from `wf.why_cannot_act` for an open stage the viewer cannot
  decide. The decision panel shows it ("You requested or submitted this change …") instead of a UI-made reason (§9: the UI explains, never decides).
- **Trigram index on descriptions too** (§4 named only `node_name`), since search matches name or description.
- **Budgets (§10):** Angular measures raw size, the targets are compressed. `scripts/check-prod-build.mjs` enforces
  `UI_INITIAL_JS_KB` 350 and `UI_ROUTE_JS_KB` 150 on gzip size after every production build; the Angular raw budget
  (600/900 kB) stays as a backstop. The same script fails the build if the development identity reaches the bundle (§9).
- **Duplicate names** are found by the server's trial apply at validation, not when the item is added, so the conflict is
  shown on the item in Review and submit (and blocks submission), not on the dialog's name field (§13 S1-R4).
- **Worklist model filter** is a text field: listing models is an administrator endpoint, and no non-admin list exists.
- **Dev identity (C-7):** the picker keeps the synthetic login in session storage in development and test builds only; the
  production build replaces the file (`fileReplacements`) and the build check proves the header is absent.
- **Toolchain (ADR-025), pinned exactly, each release at least two weeks old:** Node.js 26 LTS (installed by `winget`),
  Angular 22.2 and CDK 22.2, Vitest 5 (the CLI's default runner), Storybook 10.6 with the Vite-based Angular framework and
  the Storybook test runner with `axe-playwright`, Playwright 1.64 with `@axe-core/playwright`, Stylelint 17 (core rules
  only), `ng-openapi-gen` 1.1. Storybook telemetry is disabled.
- **End-to-end harness:** a throw-away database `nexus_e2e`, the API jar in profile `local` with the in-process worker in the
  same JVM, and the synthetic seed `ui/e2e/seed.sql`. Locally the API uses the docker-compose owner account, so the
  journeys do not prove least privilege; the JUnit suite does (as `nexus_api_test`).
- **Performance runs** (§10 expand trace, 50 000 siblings, INP) are written as `@perf` and not run: performance testing is
  deferred to the end of the build by the repository owner.

## Scope extension built in Phase 3 (repository owner, 2026-11-12)
The owner added the remaining editing screens to Phase 3 (Phase 3 plan, "Scope extension"). Design in brief:
- **Node panel actions** (not rendered in historical views; offered only with `PROPOSE` on the hierarchy; the server decides):
  Add child, Edit details (`update_node`), Place under another parent (`insert_node`, only if the hierarchy allows shared
  nodes), Move to… (`move_node`, target chosen with the in-tree search), Remove from hierarchy (`remove_node`, cascade
  choice), Delete node (`delete_node`). Remove, delete and move first show an impact preview from
  `GET /hierarchies/{code}/nodes/{id}/impact` (`{descendants, placements, isTop}`) and ask for confirmation stating the numbers.
- **Property grid** becomes editable for stored-origin properties: Edit opens a value dialog (list values as a select,
  booleans as a choice, other types as text); a stored value can be cleared. Derived properties stay read-only.
- **New hierarchy** on Home for users with `PROPOSE` on every hierarchy (`add_hierarchy`: code, name, purpose, top node).
- **Tray:** one draft at a time. A draft started by add-leaf uses `ADD_LEAF`; any other draft uses `MAINTAIN`
  (`ui/src/app/core/config.ts`). Later changes join the current draft whatever its model; the server validates the whole
  request on submit.
- **Not built:** drag and drop (optional per UI_STANDARD §6), category-based edit permissions (PRP-09 / SEC-03, Phase 5),
  inherited-value changes inside the impact preview (they appear as findings on Review and submit).

## Second scope extension built in Phase 3 (repository owner, 2026-11-12)
- **History tab (QRY-04):** `GET /api/v1/nodes/{id}/history?hierarchy&limit&cursor` returns one keyset-paged list of
  events, newest recorded first: attribute versions, placements (in readable hierarchies, or the named one), property values,
  each with `validFrom/To`, `recordedFrom/To` and the change request (id, title). The tab lists them; "Show more" pages.
- **Ownership tab (NEW-02, view only):** `GET /nodes/{id}/owners` and `/holdings` (direct `mdm.ownership_edge` rows at the
  slice, paged, readable nodes only). The tab shows two tables (owner or holding, relation, economic %, voting %, source)
  with percentages to two decimals and a small SVG diagram of the same rows; the table is the accessible equivalent
  (UI_STANDARD §5). UBO, effective ownership and editing stay in Phase 6; the graph library waits for OD-05.
- **Before/after view:** `nx-diff-view` replaces the plain item list on Review and on the request page: side-by-side and
  inline modes, added/removed/modified/moved with the change tokens plus an icon and a word.
- **Drag and drop:** a tree row can be dragged onto another node row (mouse only); dropping opens "Move to…" with that
  target chosen. Keyboard users use "Move to…".
- **Property edit rights by category:** ADR-036.

## Third scope extension: versions (repository owner, 2026-11-12; ADR-037) — designed, awaiting approval
The owner asked for versioning and chose every ADR-037 recommendation: named slices (D2 A), freeze at submit (D3 A),
`VERSION_ADMIN` with a second person to finalize, people only (D4 A), and VER-01 and VER-02 in Phase 3 (D5 A). ADR-037 R1 to R4
are refinements found while writing this section. **No code until the owner approves this section and plan increments 3-23 to 3-27.**

### V.1 Scope
| In | Out (and where it goes) |
|---|---|
| VER-01 create and copy (Improve) · VER-02 lifecycle (Parity) · a version picker · any version's picture shown read-only | VER-03 exports of a past picture (Phase 8; reads exist) · VER-04 baseline compare (Phase 5, needs QRY-02) · VER-05 aliases (Phase 8) · VER-06 retired as a feature (backup and point-in-time recovery) · VER-07 version properties (discovery, then Phase 5) · golden parity of version lists and contents (Phase 4, OD-31 and OD-32) |

### V.2 What a version shows (ADR-037 D2, R3)
- A version is a name, a business date (`business_as_of`) and, once frozen, a recorded time (`recorded_as_of`). Its
  **picture** is the data valid on the business date as recorded at the recorded time, or as recorded now while it is
  working. Export runs already read a version this way (V3).
- The steward workspace stays the live, editable view (today's date, as now). A new request is raised in the user's chosen
  working version (V.5 `/me`).
- "Copy from" records `base_version_id`; no rows are copied. A copy with its base's business date shows its base's
  picture at creation (the VER-01 test).
- Working versions are not isolated from each other (ADR-037 Context 2). The Versions page says so in one line.

### V.3 Data (`V11__versions.sql`, new; V1 to V10 unchanged)
- Role row `VERSION_ADMIN` ("Create versions and move them through their lifecycle").
- `mdm.version` gains `created_at` (default `now()`), `created_by`, `submitted_at`, `submitted_by` and `revision int NOT NULL
  DEFAULT 1` (the ETag source, ADR-015). Existing rows (the seed's `E2E working`) get `revision` 1 and NULL creators.
- A second CHECK, next to the V1 one, which stays:
  - `(status = 'working') = (recorded_as_of IS NULL)`;
  - `(status = 'working') = (submitted_by IS NULL)`;
  - `(status IN ('finalized', 'expired')) = (finalized_by IS NOT NULL)`.
- `mdm.version_transition (transition_id, version_id, from_status, to_status, actor_id, reason, pinned_at, recorded_at
  DEFAULT clock_timestamp())`. It is append-only (the V1 `N2011` trigger) and written only by the version guard. `audit_log`
  rows are written as before, since `mdm.version` is audited.
- `mdm.user_preference.working_version_id uuid REFERENCES mdm.version`, added to the API's column privileges.
- `GRANT UPDATE (version_id) ON mdm.change_request TO nexus_api` (R1), so a requester can move their draft. The V1 draft-only
  trigger (`N2102`) still refuses it on any request that is not a draft.
- A built-in validation rule `NEXUS.VERSION_DATE` (level `version`, severity warning, with an expression that is never run;
  the same pattern as `NEXUS.TRIAL_APPLY`). `validate_change_request` adds its finding.
- `nexus_api` gets no direct write on `mdm.version`; every change goes through the functions in V.4.

### V.4 Guards and functions (database)
`mdm.trg_version_guard`, BEFORE INSERT, UPDATE or DELETE on `mdm.version`:

| Rule | Code · hint |
|---|---|
| A new version starts `working`, with no pin and no submit or finalize fields | `N2706` · `version.must_start_working` |
| No version is deleted; an unwanted one is expired | `N2705` · `version.no_delete` |
| Only `working→submitted`, `submitted→working` (reopen), `submitted→finalized`, `finalized→expired` | `N2701` · `version.status_transition` |
| `business_as_of` and `base_version_id` change only while working. Name and description change while working or submitted. A finalized or expired version changes only by `finalized→expired`. Pin, submit and finalize fields change only as their transition sets them | `N2702` · `version.frozen` |
| Submit is refused while any request in the version is `submitted`, `in_review` or `approved`; DETAIL gives the count by status. Drafts do not block it (R1) | `N2704` · `version.requests_open` |
| The finalizer is not the person who submitted the version | `N1029` · `version.self_finalize` |
| Every status change has an identified, active, human actor (`mdm.actor_id`) | `N1030` · `version.actor_not_human` |

Every status change also writes a `version_transition` row, and every update bumps `revision`.

`mdm.trg_cr_version_working`, BEFORE INSERT, or UPDATE OF `version_id` or `status`, on `mdm.change_request` (R4):
- On insert, on a change of version, and on a status change to `submitted`, `in_review` (including the bridge's
  `draft → in_review`), `approved` or `applied`, the request's version, read `FOR SHARE`, must be `working`:
  `N2703` · `version.not_working`. Withdrawing or rejecting stays possible in any version.
- On the change to `applied` (R2): the trigger first takes the freeze lock shared (`pg_advisory_xact_lock_shared`), then
  refuses with `40001` if any version's `recorded_as_of` is later than this transaction's start (`now()`).
  - This works with `apply_change_request` unchanged. It sets `applied` as its last step inside its subtransaction.
    `40001` is not a rule failure (`apply_is_rule_failure`), so it is raised to `ApplyService`, which retries it in a new
    transaction whose facts fall after the pin.
  - An `N2703` at that point is a rule failure, so the request ends `apply_failed` with the reason. This should not happen,
    because `N2704` stops a submit while requests are approved.
  - `ApplyService` is the only caller of `apply_change_request`; every fact write goes through it.
  - It reads at READ COMMITTED (the default), so the pin check after the lock sees a freeze that committed meanwhile.

Functions: SECURITY DEFINER, owned by the migration owner, `SET search_path = mdm, public`, with EXECUTE granted to
`nexus_api`. Each one sets `mdm.actor_id`, so the guard and the audit see the caller.
- `mdm.is_version_admin(user)`: true for a `VERSION_ADMIN` grant on all hierarchies (`hierarchy_id IS NULL`), valid on the
  business day and currently recorded, held by an active human user. It has the same shape as `wf.is_workflow_admin` (V9).
  The functions below refuse anyone else with `N1028` · `version.not_admin`.
- `mdm.create_version(name, business_as_of, base_version_id, description, actor) → uuid`.
- `mdm.update_version(version_id, name, description, actor)`.
- `mdm.transition_version(version_id, to_status, reason, actor)`:
  - submit takes the freeze lock exclusively (`pg_advisory_xact_lock`), then sets `recorded_as_of = clock_timestamp()`,
    `submitted_at` and `submitted_by`;
  - reopen clears the pin and the submit fields;
  - finalize sets `finalized_at` and `finalized_by` and keeps the pin;
  - expire changes only the status.

New codes, to register in `CONSISTENCY_REVIEW.md` §3:

| Code | HTTP (ADR-020) | Hint | Meaning |
|---|---|---|---|
| `N1028` | 403 | `version.not_admin` | The caller is not a version administrator |
| `N1029` | 403 | `version.self_finalize` | The person who submitted a version cannot finalize it |
| `N1030` | 403 | `version.actor_not_human` | A version transition needs an identified person |
| `N2701` | 422 | `version.status_transition` | Not one of the four transitions |
| `N2702` | 422 | `version.frozen` | The field cannot change in this status |
| `N2703` | 422 | `version.not_working` | The request's version is not working |
| `N2704` | 422 | `version.requests_open` | Requests in the version are still in flight |
| `N2705` | 422 | `version.no_delete` | Versions are never deleted |
| `N2706` | 422 | `version.must_start_working` | A new version starts as working, unpinned |

### V.5 API (`/api/v1`; paging, ETags, idempotency and Problem Details as ADR-015)
| Endpoint | Notes |
|---|---|
| `GET /versions?status&limit&cursor` | Keyset on (business date descending, name). Each `VersionView` has name, status, `businessAsOf`, `recordedAsOf`, `baseVersion`, description, created, submitted and finalized (by, at), and `transitions[{to, allowed, whyNot}]` for the caller. Needs READ |
| `GET /versions/{name}` | `VersionView` plus `openRequests{draft, submitted, inReview, approved}`; ETag from `revision` |
| `POST /versions {name, businessAsOf, baseVersion?, description?}` | 201 with Location and ETag; `Idempotency-Key` as for requests; needs `ADMIN_VERSION` |
| `PATCH /versions/{name} {name?, description?}` | If-Match required (428 without, 412 if stale) |
| `POST /versions/{name}/transitions {to, reason?}` | If-Match required; returns the new `VersionView` |
| `GET /me` | `workingVersion` is the user's preference while it is still working, otherwise the latest working version (today's rule); `permissions` gains `ADMIN_VERSION` |
| `PUT /me/preferences` | Gains `workingVersion`: the name of a working version, or 422 |
| `PATCH /change-requests/{id}` | Gains `versionName`; drafts only, and the target must be working (`N2703`) |
| Validation | Warning `NEXUS.VERSION_DATE` when the request's effective date is after its version's business date: "This change takes effect on 1 Dec 2026, after version FY26 P11's date (30 Nov 2026), so it will not show in that version" |

- A picture is read through the existing endpoints, with `asOf` = the business date and `recordedAsOf` = the pin.
  Hierarchy, node and node-history reads already take both. Increment 3-24 checks every other slice-reading endpoint the
  UI uses (search, path, impact, owners and holdings, home) and adds `recordedAsOf` where it is missing.
- `whyNot` texts come from the server, for example:
  - "Only a version administrator can submit versions";
  - "You submitted this version; another version administrator must finalize it";
  - "3 requests in this version are still in flight (1 submitted, 2 approved)";
  - "A finalized version can only be expired".
- Code: `Permission.ADMIN_VERSION`, and `VERSION_ADMIN → READ, ADMIN_VERSION` in `RolePermissions` (ADR-022).
  `VersionController`, `VersionService` and `VersionRepository` use `JdbcClient` with explicit SQL and row mappers.
  Refusals come from the database codes (ADR-020); the service computes `whyNot` with the same rules, read-only.

### V.6 UI
- **Versions page** (`/versions`, lazy, in the main navigation):
  - Status chips: Working, Submitted, Finalized, Expired, All.
  - A table with name, business date, status (word and icon), frozen at, based on, and actions.
    - "Open picture" is always offered.
    - Holders of `ADMIN_VERSION` also get Submit, Reopen, Finalize, Expire and Edit, exactly as the server lists them. A
      refused action shows the server's reason as text next to it.
  - "New version" opens a dialog: name, business date, copy from (optional) and description.
  - Each transition asks for confirmation and states its effect. Submit "freezes the picture now; requests in it cannot be
    submitted until it is reopened". Finalize "is permanent; afterwards it can only be expired". The reason is optional.
  - One line says that working versions share every committed change.
- **Context bar:** "Version" becomes a select of working versions (the first 50 from `GET /versions?status=working`), with a
  link to the Versions page. Choosing one saves the preference, and the next draft is raised in it. While the open draft
  is in another version, the tray names that version.
- **Picture view:** `ContextStore` gains `recordedAsOf` and `version` (`?recordedAsOf=` and `?version=` next to `?asOf=`).
  - The view is historical when the date is not today **or** a recorded time is set, so no write controls render (as in
    the historical view).
  - The banner reads, for example, "Version FY26 P10, finalized: the data on 31 Oct 2026 as recorded at 1 Nov 2026 09:00.
    Read-only. Back to today."
- **Tray:** when submitting a draft returns `N2703`, it shows the server's message and offers "Move to version…" (choose a
  working version, then `PATCH versionName` with If-Match) or "Withdraw".
- **Review** shows the `NEXUS.VERSION_DATE` warning like any other finding; the UI holds no rule.
- Strings in `STRINGS`, tokens only, axe on the page and the dialogs, full keyboard operation, and focus to the dialog and
  back to its trigger (UI_STANDARD).

### V.7 Tests
| Level | What |
|---|---|
| pgTAP `db/tests/22_versions.sql` | Every guard and code in V.4. Pin set at submit, cleared at reopen, kept at finalize and expire. Four eyes and people only. Submit refused with requests in flight, allowed with drafts. A request created in, moved to or submitted in a non-working version is refused. R2: a pin later than the transaction's start refuses `applied` with `40001`. Transition log append-only; audit rows; the new CHECK. Privileges: no direct write on `mdm.version` for `nexus_api`, EXECUTE on the functions, `version_id` updatable only on drafts |
| JUnit `VersionApiTest` (least privilege, `nexus_api_test`) | Paging; create, copy and rename; 428 and 412; transitions and their `whyNot`; 403 for others; four eyes; submit refused with counts; moving a draft; the `/me` preference and its fallback; the validation warning. **VER-01:** a copy's picture equals its base's at creation (children and properties read at both slices). **VER-02:** a request in a submitted version is refused, and a correction applied after finalize leaves the finalized picture unchanged |
| UI unit (Vitest) | `VersionsStore`; the page renders the server's transitions and reasons; the context-bar picker; `ContextStore` with `recordedAsOf` and the banner; the tray's move after `N2703` |
| Stories with axe | Versions page (loading, empty, error, list); new-version dialog; transition confirmation |
| End to end `08-versions.spec.ts` | Two new synthetic version administrators in the seed (`e2e_vadmin`, `e2e_vadmin2`). Versions are dated yesterday, so `E2E working` stays the fallback for the other specs and is never changed. Create a version, then copy it. A steward picks it and raises a request. Submit is refused while the request is in flight, with the reason shown. The request is committed and the version submitted. A later change in another version does not appear in the picture. The submitter cannot finalize (reason shown); the second administrator finalizes. The picture is read-only; then expire. axe on every page |

### V.8 Risks
- **Users expect working versions to be isolated** (ADR-037 Context 2). Mitigations: the line on the Versions page, release
  notes and training.
- **Definitions drift (D-08).** A frozen picture is read with today's definitions. The test report lists this as a known limitation.
- **Lock cost.** A submit waits for applies already committing (short transactions). An apply that overlaps a freeze is
  retried, up to `TX_RETRY_MAX` times. If every retry fails, it is recorded `apply_failed` ("retry-later"), as for any
  technical failure today.
- **Names are unique across every status (V1).** An expired version's name cannot be reused.
