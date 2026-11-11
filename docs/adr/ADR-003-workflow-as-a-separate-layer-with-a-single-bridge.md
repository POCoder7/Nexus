# ADR-003: Workflow as a separate layer with a single bridge

- **Status:** Accepted
- **Date:** <set when reviewed>
- **Deciders:** <names / roles>
- **Capabilities:** GOV-01

## Context
DRG-equivalent governance is required, but coupling it into the core model would make both harder to change and test.

## Decision
Schema `wf` reads `mdm` but never writes it. Schema `wf_bridge` is the only write path back. The core keeps a minimal maker-checker on its own.

## Alternatives considered
- Workflow tables inside the core schema.
- Commercial workflow product only.

## Consequences
The core runs without workflow; a different workflow product could replace `wf` by replacing the bridge. Two schemas to reason about.
