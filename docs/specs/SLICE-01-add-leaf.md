# SLICE-01: First vertical slice — browse a hierarchy and add a leaf under governance

- **Status:** Draft
- **Capabilities:** HIE-01, HIE-02, HIE-12, PRP-01, GOV-01, GOV-02, GOV-13, GOV-12 (shadow mode only)
- **Owner:** <product owner>

## Goal
Prove the data model, UI and controls together on one real (masked) hierarchy: a steward browses the
hierarchy, raises a request to add a leaf, the request runs through governance, and the result matches what
the legacy system would produce.

## Scope
**In:** one medium-sized hierarchy with shared nodes and inherited properties; one existing "add leaf"
workflow model (Submit → Commit); read API; minimal UI (tree, node panel, worklist, add-leaf form);
commit policy in shadow mode; golden tests for this hierarchy.
**Out:** other hierarchies, other workflow models, exports to downstream systems, AI features.

## Requirements
| ID | Requirement | Priority |
|---|---|---|
| S1-R1 | Load the chosen hierarchy from a masked legacy extract via staging; node and relationship counts match. | Must |
| S1-R2 | Browse the hierarchy lazily with paging; the largest sibling set opens within the NFR target. | Must |
| S1-R3 | Node panel shows attributes and resolved properties (stored, inherited, default) as of a chosen date. | Must |
| S1-R4 | A steward can submit an add-leaf request with required properties; validations run on submit. | Must |
| S1-R5 | The request appears in the right worklists and can be committed by an authorised human. | Must |
| S1-R6 | The commit policy evaluates every request in shadow mode and records would-commit/would-route. | Should |
| S1-R7 | After commit, the hierarchy, history and audit log reflect the change; the requester cannot approve their own request. | Must |

## Acceptance criteria
- **Given** the loaded hierarchy, **when** the golden harness compares inherited and derived values with the
  legacy output, **then** every node matches.
- **Given** a steward without commit rights, **when** they submit an add-leaf request, **then** it reaches the
  Commit stage of an authorised group and they cannot commit it themselves.
- **Given** a committed request, **when** the hierarchy is viewed as of the day before, **then** the new leaf is absent.

## Golden tests
Capture, inside the organisation's network, for the chosen hierarchy: the hierarchy export, inherited and derived
property values per node, and batch validation results. Mask names and identifiers consistently before use.

## Design notes
Tables: `mdm.node`, `mdm.node_attr`, `mdm.hierarchy`, `mdm.hierarchy_relationship`, `mdm.property_*`,
`mdm.change_request`, `mdm.change_item`, `wf.*`. Endpoints so far: `GET /api/v1/hierarchies`,
`GET /api/v1/hierarchies/{code}/children`, `GET /api/v1/nodes/{id}`. Next: change-request endpoints and
the workflow engine integration. ADRs: 003, 005, 006, 008, 009.

## Open questions
- Which hierarchy and which add-leaf model? (Choose for real complexity and high request volume.)
- Masking approach for names and codes that keeps golden comparisons valid.
- NFR targets for tree browsing.
