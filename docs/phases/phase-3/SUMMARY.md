# Phase 3 — Steward UI: summary

## What was built
A person can now use Nexus. A steward signs in (development user picker until OD-06), lands on Home, browses a large
hierarchy through a lazy, virtualised tree, sees each property value with its provenance, and raises changes that collect
in the change-request tray. Changes include adding a leaf with its required properties, editing details and property values,
placing, moving, removing and deleting nodes, and creating a hierarchy. The steward reviews the validation and submits. An
approver and a committer act from their worklists, the shadow commit policy shows on the timeline, and anyone can view any
past date read-only.

| Commit | Increment |
|---|---|
| `7d2b0a4` | Plan; fixture time-zone fix |
| `bd2ea31` | 3-1 Backend: V10, `/me` preferences and permissions, `/home`, search and path, submit form, request detail additions, client errors |
| Phase 3 UI commit | 3-2 to 3-17: generated client, workspace and toolchain, shell, tree, node panel, add-leaf, tray, review, worklist, request page, Home, the scope-extension editing screens, impact endpoint, the `set_property` fix, end-to-end suite, CI job |
| Records commit | Test report, this summary, build state |
| Third Phase 3 commit | 3-18 to 3-22 second scope extension: edit rights by category (ADR-036), History and Ownership tabs, before/after view, drag and drop |

## Decisions taken
- Plan approved by the repository owner, including the Node.js install, the UI dependencies from the public npm registry and the CI `ui` job.
- **Scope extension (repository owner):** all editing screens for actions the API already had were moved from Phase 5 into Phase 3 (plan "Scope extension", LLD section "Scope extension built in Phase 3").
- Node.js 26 LTS (what `winget` installed), Angular 22.2; every package pinned exactly to a release at least two weeks old.
- Drafts not started by add-leaf use a second workflow model, `MAINTAIN`.
- **Second scope extension (repository owner):** everything else except AI suggestions and notifications; property edit rights by category recorded as ADR-036 (accepted; Security confirmation pending with ADR-022).

## Patterns introduced or extended (`docs/architecture/patterns.md`)
P-26 feature stores with signals; P-27 generated API client with a drift check; P-11 flattened lazy tree with virtual scroll and
a bounded search reveal; P-21 children pages cached per slice; P-18 provenance markers.

## Deviations from the plan and the LLD (recorded as *Built in Phase 3* notes)
3-5 split; springdoc default media type; `/me` `workingVersion`; stage `whyNot`; trigram index on descriptions; compressed
budgets checked by a script; duplicate names reported at the item on review; worklist model filter as text; dev login in
session storage (dev builds only); harness on the owner account; impact endpoint for the scope extension.

## Known gaps and technical debt
See `TEST_REPORT.md` → Explicit gaps. Also: the item list shows a move's target parent by id prefix (names are not in the
item); the Storybook test runner pulls deprecated transitive packages (dev only); `npm` blocks native install scripts for
optional watchers (esbuild's is allowed).

## What the next phase needs
Phase 4 (data loading and parity) needs masked extracts and captured DRM outputs (OD-31, OD-32) for golden parity, and a
decision on running its performance baseline now or at the end of the build with the rest of the deferred performance work.
