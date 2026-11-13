# Phase 3 — Steward UI: summary

## What was built
A person can now use Nexus. A steward signs in (development user picker until OD-06), lands on Home, browses a large
hierarchy through a lazy, virtualised tree, sees each property value with its provenance, and raises changes that collect
in the change-request tray. Changes include adding a leaf with its required properties, editing details and property values,
placing, moving, removing and deleting nodes, and creating a hierarchy. The steward reviews the validation and submits. An
approver and a committer act from their worklists, the shadow commit policy shows on the timeline, and anyone can view any
past date read-only. A version administrator creates and copies versions and moves them from working to submitted,
finalized and expired. A second administrator finalizes. Stewards raise requests in a chosen working version, and anyone
can open a version's frozen picture read-only.

| Commit | Increment |
|---|---|
| `549fd67` | Plan; fixture time-zone fix |
| `507477b` | 3-1 Backend: V10, `/me` preferences and permissions, `/home`, search and path, submit form, request detail additions, client errors |
| Phase 3 UI commit | 3-2 to 3-17: generated client, workspace and toolchain, shell, tree, node panel, add-leaf, tray, review, worklist, request page, Home, the scope-extension editing screens, impact endpoint, the `set_property` fix, end-to-end suite, CI job |
| Records commit | Test report, this summary, build state |
| Third Phase 3 commit | 3-18 to 3-22 second scope extension: edit rights by category (ADR-036), History and Ownership tabs, before/after view, drag and drop |
| `0b584f7`, `a706809` | Versions: ADR-037 proposed, then the design (LLD "Third scope extension: versions") |
| `abf0151` | 3-23 `V11__versions.sql` and pgTAP `22_versions.sql` |
| `34393e1` | 3-24 Versions API, `/me` working version, moving a draft, the `NEXUS.VERSION_DATE` warning |
| `e24bf87` | 3-25 Versions page and dialogs, context-bar picker, version pictures, move on Review and submit |
| `0f32aa4` | 3-26 End-to-end journey `08-versions` and two synthetic version administrators |
| Records commit (3-27) | Versions records: LLD V.9, data model, patterns, traceability, this summary, test report, build state |

## Decisions taken
- Plan approved by the repository owner, including the Node.js install, the UI dependencies from the public npm registry and the CI `ui` job.
- **Scope extension (repository owner):** all editing screens for actions the API already had were moved from Phase 5 into Phase 3 (plan "Scope extension", LLD section "Scope extension built in Phase 3").
- Node.js 26 LTS (what `winget` installed), Angular 22.2; every package pinned exactly to a release at least two weeks old.
- Drafts not started by add-leaf use a second workflow model, `MAINTAIN`.
- **Second scope extension (repository owner):** everything else except AI suggestions and notifications; property edit rights by category recorded as ADR-036 (accepted; Security confirmation pending with ADR-022).
- **Third scope extension (repository owner, 2026-11-12):** versions (VER-01, VER-02) in Phase 3, every ADR-037 recommendation (D2 to D5 A), refinements R1 to R4 and the `UPDATE (version_id)` column privilege; "Build it as designed".

## Patterns introduced or extended (`docs/architecture/patterns.md`)
P-26 feature stores with signals; P-27 generated API client with a drift check; P-11 flattened lazy tree with virtual scroll and
a bounded search reveal; P-21 children pages cached per slice; P-18 provenance markers. Versions: P-02 lifecycle and pin at
submit, P-24 version guards and the freeze lock, P-17 reasons computed by the server (`whyNot`, `edit`), P-10 ETags on versions.

## Deviations from the plan and the LLD (recorded as *Built in Phase 3* notes)
3-5 split; springdoc default media type; `/me` `workingVersion`; stage `whyNot`; trigram index on descriptions; compressed
budgets checked by a script; duplicate names reported at the item on review; worklist model filter as text; dev login in
session storage (dev builds only); harness on the owner account; impact endpoint for the scope extension. Versions (LLD
V.9): `edit{allowed, whyNot}`; a copy takes its base's date; no slice changes were needed for search, path, impact,
ownership or home; move and withdraw on Review and submit; the Versions page opens on All; picker errors inline; the guard
keeps the query string; journey 08 raises requests as the architect.

## Known gaps and technical debt
See `TEST_REPORT.md` → Explicit gaps. Also: the item list shows a move's target parent by id prefix (names are not in the
item); the Storybook test runner pulls deprecated transitive packages (dev only); `npm` blocks native install scripts for
optional watchers (esbuild's is allowed); nothing indexes `mdm.change_request(version_id)`, so counting a version's
requests in flight scans the table (Phase 9 hardening).

## What the next phase needs
Phase 4 (data loading and parity) needs masked extracts and captured DRM outputs (OD-31, OD-32) for golden parity, and a
decision on running its performance baseline now or at the end of the build with the rest of the deferred performance work.
