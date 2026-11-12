# ADR-012: UI framework — Angular with the organisation's design system

- **Status:** Accepted
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** HIE-12, GOV-13, NEW-10, SLICE-01

## Context
Nexus needs a web UI for data stewards that is consistent with the organisation's other applications.
The organisation's internal design system (components, tokens, typography, brand rules) is built on Angular.
The UI framework had been left open as a human-owned decision.

## Decision
Build the Nexus UI in Angular, at the major version the design system supports, using the organisation's
design system as the only source of visual values, components and brand assets. Nexus-specific rules and
custom components are defined in `docs/design/UI_STANDARD.md`. Design-system packages are consumed from the
organisation's internal package registry and are not committed to this repository.

## Alternatives considered
- **React:** larger ecosystem for trees, grids and graph visualisation, but the design system would have to
  be re-implemented or wrapped, creating visual drift and duplicated accessibility work.
- **Recreating the organisation's styles from its public website:** rejected. It is the wrong source for
  internal applications, gives styling without tested components, drifts over time, and brand assets must
  come through official channels.

## Consequences
- Consistent look, accessibility and behaviour with other internal applications, with less custom UI code.
- The Angular version, available components and upgrade cadence follow the design system's roadmap.
- Custom components (hierarchy tree, property grid, diff view, ownership graph) must be built on design-system
  primitives and Angular CDK where the design system has no equivalent; library choices for data grid and
  graph visualisation need approval (see `OPEN_DECISIONS.md`).
- Until the design-system packages are available to the build, the UI is developed against the Nexus token
  layer with neutral placeholder values and no brand marks.
