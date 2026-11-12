# Contributing

## Flow
1. Pick a story from the tracker; note its capability ID.
2. Branch: `feature/<CAP-ID>-<short-name>` (e.g. `feature/HIE-02-children-paging`).
3. Commit messages start with the ID: `HIE-02: page children endpoint`.
4. Open a PR using the template; CI must be green; a human other than the author reviews.

## Definition of done
- Reviewed by someone other than the author
- Tests added/updated and green in CI (pgTAP for DB rules, JUnit for Java)
- Golden/parity tests pass where the capability has them
- No guard weakened to pass a test (unless an ADR records the decision)
- Spec/ADR updated if behaviour or a decision changed
- No production, client or personal data anywhere in the change
- Tracker updated

## Migrations
Until the first shared environment exists, V1–V6 may be edited in place. After that, never modify an
applied migration; add a new `V<n>__description.sql`.

## AI-assisted changes
AI-written code meets the same bar as human code. The author of the PR is accountable for it.
