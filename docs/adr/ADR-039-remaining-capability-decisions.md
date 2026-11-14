# ADR-039: Decisions for the remaining undecided capabilities (Phases 1, 2 and 5)

- **Status:** **Accepted 2026-11-14** by the repository owner ("all approved", in answer to the Phase 5 plan's question 3: every recommendation). OD-47
- **Date:** 2026-11-14
- **Deciders:** Repository owner (as for ADR-038). Product confirms the rows marked "confirm" from discovery or the Phase 4
  extract profile. Audit-Risk keeps AUD-04 (OD-25)
- **Capabilities:**
  - Phase 5: VER-07, HIE-03, HIE-04, HIE-05, HIE-07 to HIE-11, PRP-04, PRP-05, PRP-07, PRP-08, PRP-10, VAL-04,
    SEC-03 (read side), SEC-04, AUD-03, AUD-04, GOV-14, GOV-15.
  - Earlier phases: HIE-06, PRP-02, PRP-03, VAL-01 to VAL-03, AUD-01 (Phase 1); GOV-03 to GOV-09, GOV-11, GOV-16, AUD-02
    (Phase 2).
  - Records only: PRP-09 and SEC-03 edit side (ADR-036).

## Context
ADR-038 decided the capabilities in the owner's 2026-11-14 request. The owner also moved Phase 5 ahead of Phase 4. Its
exit criterion is that each capability with decision Parity or Improve has passing acceptance tests, or is listed as an
explicit gap. Today every row below is `—` in the catalogue (OD-09), so at the Phase 5 gate each one would be a gap.

The Phase 5 LLD (§1) already says that the pending capabilities of Phases 1 and 2 are built in Phase 5 if they are decided
by then. So this ADR covers all of them.

**What exists already.** Several rows are mostly built and only need the decision recorded:

| Capability | Built |
|---|---|
| HIE-03 shared nodes | `insert_node` and `hierarchy_relationship.is_primary` (Phase 1); shown in the UI (Phase 3) |
| HIE-05 leaf and limb | `allows_children` is set at add (`isLeaf`). Adding under a leaf is refused (N2004). Promotion is not built |
| HIE-06, HIE-08 | The enum values `inactivate_node` and `reorder_node` exist. Neither has an apply handler: `apply_not_available` refuses them |
| PRP-02, PRP-03 | Types and list values are enforced by `trg_property_value_check` (N2020) |
| PRP-05 | Inheritance is resolved by `property_value_asof` and `node_properties_resolved`. Locks are not built |
| PRP-08 | `property_category`; the Phase 3 grid groups by it |
| PRP-09, SEC-03 edit side | Edit rights by category (ADR-036, built in Phase 3) |
| VAL-01 to VAL-03 | `validate_change_request` runs the rules at validate and at submit (Phase 1) |
| AUD-01 | `audit_log` (append-only) records every applied change. Phase 3 shows it per node in the History tab |
| GOV-03, GOV-05, GOV-06 | Built in Phase 2 as infrastructure: `wf.item_allowed_in_stage`, `wf.missing_required_properties`, `wf.sod_violation`, and the `any_group` and `all_groups` outcomes |
| GOV-04 | Conditional stages are evaluated and skipped. Splitting is refused (N2202) |
| AUD-02 | `wf.instance_action` and `wf.policy_evaluation` hold the history; there is no read API |

**Constraints**
- Golden parity tests need the Phase 4 harness and masked data. As in ADR-038 D5, a capability built now is accepted on
  synthetic tests, and its parity is unproven until the golden run.
- Some rows matter only if DRM uses them. Usage evidence comes from discovery or from the Phase 4 extract profile, which
  now comes after Phase 5.
- The owner excluded notifications (GOV-08, GOV-16) from the build on 2026-11-12.

## Decisions to take

### D1: Capability decisions (OD-09)
"Record" means the capability is built, so the decision only updates the catalogue. "Confirm" means build only once
Product confirms the feature is used; otherwise retire it.

**Phase 1 capabilities**
| ID | Options | Recommendation | Why |
|---|---|---|---|
| HIE-06 Inactivate / reactivate | Parity · Retire | **Parity** (Phase 5) | Inactive nodes are widely used to retire codes without deleting them, and exports already have an include-inactive option. Needs apply handlers for `inactivate_node` and a reactivation action; both are a `node_attr` change from a date |
| PRP-02 Data types | Parity · Improve | **Parity** (record) | Enforced today. Exact round-trip is proved by the Phase 4 golden extract |
| PRP-03 List properties | Parity · Improve | **Parity** (record) | Enforced today. The golden check compares the list definitions |
| VAL-01 Real-time validations | Parity: block each edit · **Improve**: check each item when added and block at submit | **Improve** (Phase 5) | In Nexus an edit is an item in a draft request, and a restructure passes through invalid states before it is complete. Node-scoped rules run when an item is added, and the result shows in the tray at once, with DRM's message. Submit stays blocked while any rule fails, which it already is |
| VAL-02 Batch validations | Parity · Retire | **Parity** (Phase 5) | An on-demand run of the rules across one hierarchy or version slice, with stored, paged results |
| VAL-03 Levels and assignments | Parity · Improve | **Parity** (Phase 5) | Rules keep DRM's node, hierarchy and version levels, and are assigned to hierarchies or versions |
| AUD-01 Transaction history | Parity · Improve | **Parity** (Phase 5) | A paged query API over `audit_log`: actor, period, hierarchy, request. Filtered by the reader's scope. EXP-05 reuses it in Phase 8 |

**Phase 2 capabilities**
| ID | Options | Recommendation | Why |
|---|---|---|---|
| GOV-03 Tasks and editable properties | Parity | **Parity** (record) | Built in Phase 2. Request histories prove it in Phase 4 |
| GOV-04 Conditional stages and splitting | Parity · Parity for conditions only, with splitting confirmed | **Parity for conditions (record); splitting: confirm** | Conditions are built. `wf.split_instance` exists but is disabled (N2202). Build splitting only if DRG models in use split requests |
| GOV-05 Separation of duties | Parity | **Parity** (record) | Built and tested as a control in Phase 2 |
| GOV-06 Approval groups and methods | Parity | **Parity** (record) | Built in Phase 2 |
| GOV-07 Claims, durations, SLAs | Parity · Improve | **Parity** (Phase 5), without escalation messages | Claim expiry, a due time per stage, and an overdue flag and filter in the worklist. Escalation by message waits with GOV-08 (D3) |
| GOV-08 Notifications | See D3 | **Stays out** (D3) | Excluded by the owner on 2026-11-12 |
| GOV-09 Push-back and re-approval | Parity · Retire | **Parity** (Phase 5) | A `push_back` decision returns the request to an earlier stage; the stage's `reapproval` setting decides which stages approve again. Today `push_back` is refused |
| GOV-11 Comments and attachments | Parity · comments only | **Parity**: comments in Phase 5; attachments after Phase 6 | Comments are `comment` actions (the enum value exists). Attachments need the Phase 6 document store (OD-16a) |
| GOV-16 Alerts | See D3 | **Stays out** (D3) | As GOV-08 |
| AUD-02 Request history | Parity · Improve | **Parity** (Phase 5) | A read API and a panel on the request page over `wf.instance_action` and `wf.policy_evaluation`. Read-only; the history is already append-only |

**Phase 5 capabilities**
| ID | Options | Recommendation | Why |
|---|---|---|---|
| VER-07 Version properties | Parity · Retire | **Confirm** (ADR-037 D1 already says so) | Design ready (§15.1). Build only if used |
| HIE-03 Shared nodes | Parity | **Parity** (record) | Built. Exports with shared nodes are proved in Phase 8 |
| HIE-04 Orphans | Parity · Retire | **Parity** (Phase 5) | A view and a paged endpoint of nodes that are in no hierarchy at the slice, with a list in the UI |
| HIE-05 Leaf / limb and promotion | Parity | **Parity** (Phase 5) | Leaf at add and the block exist. Add promotion and demotion through `update_node` (`isLeaf`); demoting a node that has children is refused |
| HIE-07 Merge on delete | Parity · Retire | **Confirm** | A `merge_node` action must find and repoint every `node_ref` value and relationship. That cost is justified only if the feature is used |
| HIE-08 Sibling sort order | Parity | **Parity** (Phase 5) | A `reorder_node` handler. Export row order must match DRM (golden in Phase 8) |
| HIE-09 Node types | Parity · Improve | **Parity** (Phase 5) | Which properties and rules apply by node type. The detailed design states whether the type is `node_kind` or a property, because in DRM it is often a property |
| HIE-10 Domains | Parity · Retire | **Confirm** | Identifier schemes and uniqueness rules exist. Domain rules are worth building only if used |
| HIE-11 Model after | Parity | **Parity** (Phase 5) | UI only: fills a draft with `add_node` and `set_property` items copied from a source node |
| PRP-04 Lookup properties | Parity: governed lookup table and a deterministic CEL `lookup()` · Parity: `sql` derivations · Retire | **Parity, with a lookup table and `lookup()`** (Phase 5) | The lookup values valid at the slice are read once per batch and passed to the engine, so evaluation stays free of I/O (Phase 5 LLD §17.3.2). Lookup changes go through change requests. This ADR is the decision §17.3.2 requires for a function that reads more than its variables |
| PRP-05 Inheritance and overrides | Parity, with locks · Parity, with locks confirmed | **Parity (record inheritance); locks: confirm** | Inheritance is built. Locks (a lower node may not override) need a new table; build them only if used |
| PRP-07 System properties | Parity | **Parity** (Phase 5) | Level, child count, leaf, parent, name and description as read-only properties in reads, queries (§17.5.1 already has them as attributes) and exports |
| PRP-08 Categories | Parity | **Parity** (record) | Built in Phase 3 |
| PRP-09 Property edit permissions | Parity | **Parity** (record, ADR-036) | Built in Phase 3 |
| PRP-10 Hierarchy properties | Parity · Retire | **Confirm** | Same pattern as VER-07 |
| VAL-04 Formula validations | Parity · Improve | **Parity** (Phase 5 engine; translation after Phase 4) | Rules as CEL in Java on the ADR-038 D4 engine, with `drm_validation_orig` kept. Each DRM rule in use is converted with its own tests once the Phase 4 profile lists them |
| SEC-03 Property access (read side) | See D4 | **D4 A** | |
| SEC-04 Object access | Parity · Improve | **Parity** (Phase 5) | DRM's personal, shared and system levels on saved queries and sandboxes: `visibility` gains `system`, set by an administrator. Export profiles keep their governed ownership (ADR-032) |
| AUD-03 Job and export run history | Parity | **Parity, built in Phase 8** | Nothing produces runs before the Phase 8 export service. It makes `export_run` append-only (D-30) and adds job runs there |
| AUD-04 Retention | Audit-Risk decides (OD-25) | **No change** | No deletion in any phase until OD-25 is decided. Nothing is built in Phase 5 |
| GOV-14 Request tags | Parity · Retire | **Parity** (Phase 5) | A tag table on `change_request`, a worklist filter and tag counts |
| GOV-15 Governance analytics | Parity · Improve | **Parity** (Phase 5); metric list to confirm | Read-only views over `wf`, refreshed daily: volumes, ageing, stage durations, SLA. Shown on one page and exportable. Product confirms which metrics are used today |

### D2: Where the Phase 1 and 2 capabilities are built
| Option | Effect |
|---|---|
| **A (recommended)** | Built as Phase 5 increments, as the Phase 5 LLD §1 says. Phases 1 and 2 stay closed |
| B | Reopen Phases 1 and 2. Their gates would have to be passed again, for no gain |

### D3: Notifications and alerts (GOV-08, GOV-16)
| Option | Effect |
|---|---|
| **A (recommended)** | Stay out, as the owner decided on 2026-11-12. They are explicit gaps at the gate, and GOV-07 escalation waits with them |
| B | Parity in Phase 5: an outbox consumer with an in-app channel and an email channel. Email needs a mail service, which is outside the local machine and needs its own approval (CLAUDE.md rule 8) |
| C | Retire. Downstream users would lose DRG's request messages |

### D4: SEC-03 read side
| Option | Effect |
|---|---|
| **A (recommended)** | ADR-036's `category_codes` also limits READ. The API omits values in uncovered categories from node detail, queries, compares and search, and says that it has done so. Exports keep their governed profile access (ADR-032). One grant model for both sides |
| B | A separate read-category list on each grant. More control, and twice the grant administration |
| C | No read restriction (edit rights only). Simplest; acceptable only if DRM hides no properties from readers |

### D5: Rows that wait for confirmation
VER-07, HIE-07, HIE-10, PRP-10, GOV-04 splitting and PRP-05 locks.
| Option | Effect |
|---|---|
| **A (recommended)** | Build each only after Product confirms use. The Phase 4 extract profile shows it. Until then each is an explicit gap at the Phase 5 gate, and is built as a Phase 5 follow-up after Phase 4 if confirmed |
| B | Build them now on the assumption they are used. Effort without evidence, and HIE-07 is large |

## Decision
Accepted 2026-11-14 by the repository owner: **every recommendation** (OD-47).
- **D1:** each capability as the Recommendation column says. The catalogue (`docs/capabilities.md`) and `TRACEABILITY.md` record it.
- **D2 A:** the Phase 1 and 2 capabilities are built as Phase 5 increments. Phases 1 and 2 stay closed.
- **D3 A:** notifications and alerts (GOV-08, GOV-16) stay out. They are explicit gaps at the gate, and GOV-07 escalation waits with them.
- **D4 A:** ADR-036's `category_codes` also limits READ. Exports keep their governed profile access (ADR-032).
- **D5 A:** VER-07, HIE-07, HIE-10, PRP-10, GOV-04 splitting and PRP-05 locks are built only after Product confirms use. Until then they are explicit gaps at the Phase 5 gate.

The Phase 5 rows get Phase 5 LLD §18, which is reviewed before they are built, after increment 5-16 and before the gate (5-8).

## Consequences
- **If the recommendations are adopted:**
  - The "record" rows change only the catalogue and TRACEABILITY.
  - The Phase 5 rows each get a detailed design section in the Phase 5 LLD (§18), reviewed before they are built, as
    BUILD_PROTOCOL and DESIGN_PROTOCOL require. They are built after 5-16 and before the gate (5-8).
  - VAL-04 and PRP-04 use the CEL engine from 5-10.
  - The gate lists GOV-08, GOV-16, AUD-04 and the "confirm" rows as explicit gaps, with the reason for each.
- **Parity stays unproven** for every row until the Phase 4 golden run (ADR-038 D5).
- **If any row is decided Retire,** its §15.1 outline is removed, and the catalogue records the reason.
