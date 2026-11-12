# Nexus UI design standard

Applies to every Nexus screen. Save as `docs/design/UI_STANDARD.md`.

## 1. Authority and sources

Order of precedence when two sources disagree:

1. **The organisation's design system** (Angular component library, design tokens, typography, iconography,
   brand rules, accessibility standard). It is the only source of visual values and brand assets.
2. **This standard**, which says how Nexus uses the design system and covers what it does not: data-dense
   master-data screens.
3. Feature-level design in the phase LLDs.

Rules:
- Visual values (colours, fonts, sizes, spacing, radii, shadows, motion) come from the design system's tokens.
  Never copy them from a public website, a screenshot or another application.
- Design-system packages, fonts, logos and icons are installed from the organisation's internal package
  registry at build time. They are never committed to this repository.
- Use the design system's own header and brand components for the application shell. Do not recreate brand marks.
- A deviation from the design system needs an ADR and sign-off from the UX / design-system team.

## 2. Technology baseline

| Topic | Standard |
|---|---|
| Framework | Angular, at the major version the design system supports |
| Language | TypeScript in strict mode |
| Components | Standalone components; `OnPush` change detection everywhere |
| State | Component and feature state with signals (where the supported Angular version provides them) and store services; a state library only if an ADR justifies it |
| Forms | Typed reactive forms |
| Routing | Lazy-loaded feature routes; route guards for navigation only (the server enforces authorisation) |
| HTTP | `HttpClient` with interceptors for auth, correlation IDs and the error model; API clients generated from the OpenAPI spec |
| Primitives | Design-system components first; Angular CDK (virtual scroll, overlay, a11y, drag-drop) where the design system has no equivalent |
| Styling | Design-system tokens via CSS custom properties; component-scoped styles; no global overrides of design-system components |

## 3. Design tokens

Nexus components reference **semantic Nexus tokens**, each mapped to a design-system token in one file
(`ui/src/styles/tokens.css` or the design system's theming mechanism). Components never reference raw values
or design-system primitives directly, so a design-system upgrade is a change in one place.

Naming: `--nx-<category>-<role>[-<state>]`, for example `--nx-color-text-primary`, `--nx-color-status-error`,
`--nx-space-3`, `--nx-density-row-height`.

| Category | Nexus tokens (roles) | Design-system token (fill in) |
|---|---|---|
| Colour: surface | page, panel, raised, selected, hover | |
| Colour: text | primary, secondary, disabled, inverse, link | |
| Colour: border | default, strong, focus | |
| Colour: status | info, success, warning, error, pending | |
| Colour: change | added, removed, modified, moved (for diffs) | |
| Colour: provenance | stored, inherited, derived, default, ai-suggested | |
| Typography | body, body-compact, label, heading-1…4, code/identifier | |
| Spacing | space-1…8 | |
| Density | row-height (comfortable, compact), cell-padding | |
| Radius, elevation, motion | as provided | |
| Z-index | dropdown, sticky, overlay, modal, toast | |

Enforcement: a style lint rule fails the build on colour literals, pixel font sizes and font-family
declarations outside the token file.

**Status (Phase 3, 2026-11-12):** `ui/src/styles/tokens.css` defines every role above with neutral **placeholder** values
(contrast checked by axe on every page and story). The "Design-system token" column stays empty until OD-03; filling it
is a change to that one file. Enforcement is built: `npm run lint` (Stylelint core rules) with a self-test that proves
each rule refuses a forbidden declaration.

## 4. Application layout

- **Shell:** design-system header (brand, application name, environment badge, user menu); left navigation
  (Hierarchies, Worklist, Search, Ownership, Audit, Administration); main workspace; optional right context panel.
- **Global context bar** under the header, always visible: current version, **"Viewing as of" date**, and
  the hierarchy. When the as-of date is not today, show a persistent banner and make all data read-only.
- **Workspace pattern:** master-detail. Tree or list on the left (resizable), detail panel on the right with
  tabs (Properties, Relationships, Ownership, History).
- **Desktop first.** Stewards work on large screens; support the design system's breakpoints down to tablet
  width with the detail panel collapsing below the tree. No horizontal scrolling of the page; wide content
  scrolls inside its own container.
- Density: compact by default on data screens, with a user preference for comfortable.

## 5. Components

Use a design-system component whenever one exists. Custom components are limited to this inventory and are
built from design-system primitives and tokens:

| Custom component | Purpose | Interaction standard |
|---|---|---|
| Hierarchy tree | Browse and restructure large hierarchies | WAI-ARIA tree pattern; lazy loading; paged siblings ("Show next 200"); virtual scrolling; type-ahead; shared-node indicator |
| Property grid | View and edit properties by category | WAI-ARIA grid pattern; provenance marker per value (stored, inherited from ancestor, derived, default); required and read-only states |
| Worklist table | Requests assigned, urgent, overdue, claimed | Design-system table if it supports virtual scroll and column configuration; otherwise custom on CDK |
| Change-request tray | Draft changes awaiting submission | Persistent, shows item count; review before submit |
| Diff / compare view | Before and after for a change, version or hierarchy | Side by side and inline modes; added, removed, modified and moved use the change tokens plus icons |
| Workflow timeline | Stages, approvals, comments, policy evaluations | Read-only; states announced to assistive technology |
| Ownership graph | Ownership paths and percentages | Graph view plus an equivalent accessible table of paths; never the graph alone |
| Evidence viewer | Source document with highlighted citation | Opens beside the fact it supports |

Each custom component has a Storybook entry showing every state: default, hover, focus, selected, disabled,
loading, empty, error, read-only.

## 6. Interaction patterns

- **Edits are change requests.** No control writes directly to live data. Edits collect in the change-request
  tray; the user reviews, then submits. Make this visible so stewards always know nothing changes until
  governance approves.
- **Restructuring.** Drag-and-drop is optional and never the only way: provide "Move to…" with a searchable
  target picker. Before confirming a move, show an impact preview (descendants affected, inherited property
  changes, validations).
- **Validation.** Errors block submission; warnings do not. Show messages next to the field and in a summary
  that links to each field. Server validation is authoritative; client checks exist only to help the user.
- **Workflow state.** Show stage and status with text and an icon, never colour alone. Explain why an action
  is unavailable (for example separation of duties) instead of hiding it without explanation.
- **Straight-through commit.** When a request was committed under a policy, label it "Committed by policy"
  with the policy name and a link to the evaluation.
- **AI output.** Always labelled as an AI suggestion, visually distinct using the provenance token, with
  confidence and a link to evidence. It requires an explicit accept or reject and is never pre-applied.
- **Time.** The as-of control is global. Historical views are read-only and clearly marked.
- **Loading, empty and error states** are designed for every view. Use skeletons for content, a progress
  indicator with cancel for long operations, and errors that state what happened, why, and what to do next.
- **Destructive or wide-impact actions** require confirmation that states the impact in numbers.
- **Tables.** Sorting, filtering and column configuration are consistent across the application; keyset
  paging or virtual scroll for large sets; selection persists across pages; exports respect entitlements.
- **Notifications.** Toasts for confirmations only; anything requiring action goes to the worklist or an
  inline message, not a transient toast.

## 7. Content and formatting

| Item | Standard |
|---|---|
| Dates | `dd MMM yyyy` (for example 03 Feb 2027) to avoid US/India ambiguity; ISO 8601 in exports and APIs |
| Times | 24-hour with time zone shown; relative time ("2 hours ago") only with the absolute time available on focus or hover |
| Percentages | Ownership to two decimals in lists, full stored precision in detail; right-aligned, tabular numerals |
| Identifiers | Node names, LEIs and request IDs in the identifier type style with tabular numerals and a copy action |
| Terminology | One term per concept, matching the glossary in the architecture overview (node, hierarchy, version, change request, stage, policy) |
| Language | Plain, specific, active voice; no blame in errors; buttons use verbs ("Submit request", not "OK") |

## 8. Accessibility

- Target WCAG 2.1 AA, or the organisation's standard if stricter.
- Everything works by keyboard, including the tree, grid, graph alternative and drag-drop alternative.
  Focus is always visible and managed on route change, dialog open and close.
- Contrast comes from tokens; status and change are conveyed by text or icon as well as colour.
- Asynchronous updates (validation results, request status, loading completion) are announced through a
  live region.
- Respect reduced-motion preferences.
- Automated accessibility checks run in CI on every page and Storybook story; custom components get a manual
  screen-reader check before release.

## 9. Angular code standards for the UI

- Feature-based folders (`hierarchy`, `worklist`, `change-request`, `ownership`, `audit`, `admin`, `shared`).
- Container components fetch and coordinate; presentational components take inputs and emit outputs.
- No business rules in the UI: authorisation, validation and calculations are server-side.
- `@for` with `track` (or `trackBy`); virtual scroll for any list that can exceed 100 rows.
- Performance budgets for initial bundle size and interaction latency are set in the Phase 3 LLD and
  enforced in the build.
- Security: no `innerHTML` with dynamic content, no bypassing Angular sanitisation, authentication through
  the organisation's library, no tokens in browser storage unless that library requires it.
- Internationalisation-ready: no hard-coded user-facing strings in templates.

## 10. Testing

| Level | Standard |
|---|---|
| Component | Tests for every custom component, including keyboard behaviour and states |
| Accessibility | Automated checks in CI; manual checks for custom components |
| End to end | The SLICE-01 journeys (browse, add leaf, submit, commit, verify) and each later critical journey |
| Visual | Storybook stories as the reference for custom components |

## 11. Definition of done for UI work

Uses design-system components where they exist · only Nexus tokens in styles · all states designed and in
Storybook · keyboard and screen-reader behaviour verified · automated accessibility checks pass · edits go
through the change-request tray · strings externalised · tests added · no brand assets committed.

## 12. To obtain from the UX / design-system team

1. Package names, internal registry and the supported Angular version.
2. The token list, to complete the mapping in section 3.
3. The component catalogue, especially whether a tree, a data grid with virtual scrolling, and a date picker exist.
4. Approved libraries for data grids and for graph visualisation (the ownership graph).
5. Icon set, application shell and brand rules for internal applications.
6. Accessibility standard and browser support matrix.
7. The authentication library for Angular applications.
8. Their review process for new internal applications.
