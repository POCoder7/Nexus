# ADR-025: UI toolchain — tests, stories, accessibility checks, style lint, generated API client

- **Status:** Accepted (repository owner, 2026-11-11). The dependencies and the UI CI job are approved separately in the Phase 3 build plan
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** HIE-12, GOV-13, NEW-10, SLICE-01

## Context
ADR-012 fixes Angular on the organisation's design system; `UI_STANDARD.md` requires component tests, Storybook states,
automated accessibility checks, a token lint rule, end-to-end SLICE-01 journeys and an API client generated from OpenAPI.
The tools are not chosen yet.

## Decision (proposed)
| Need | Tool | Why |
|---|---|---|
| Unit and component tests | The Angular CLI's default test runner for the design system's Angular major | No extra choice; follows the framework |
| End-to-end and performance traces | Playwright | Multi-user journeys in one test (dev user picker), traces, Chromium and Edge |
| Component states | Storybook with its test runner | Required by UI_STANDARD §5 |
| Accessibility | axe-core (in Playwright and on every story) | Widely used WCAG checks |
| Token enforcement | Stylelint with rules banning colour literals, px font sizes and `font-family` outside `tokens.css` | UI_STANDARD §3 |
| API contract | `springdoc-openapi` in `mdm-api`; an OpenAPI TypeScript generator in the UI build | P-27 |
| Runtime | Node.js LTS, npm, via the organisation's registry mirror | UI_STANDARD §1 (packages from the internal registry) |

## Alternatives considered
- **Cypress** instead of Playwright: good developer experience; weaker for several signed-in users in one test and for performance traces.
- **Hand-written API services:** drift between UI and API.
- **No Storybook:** contradicts UI_STANDARD §5 and §10.

## Consequences
- A third toolchain in CI (a `ui` job), which needs approval as a CI change.
- Tool versions follow the design system's Angular major once OD-02 is answered.
