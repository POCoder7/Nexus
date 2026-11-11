# Capability catalogue

Capabilities of the legacy hierarchy-management and governance product (Oracle DRM/DRG) and how Nexus covers them,
plus new capabilities. Reference a capability by its ID in prompts, branches, commits and PRs (e.g. `HIE-02`).

- **Decision:** Parity (rebuild as-is) · Improve (rebuild differently) · Retire (not carried over) · New (not in the legacy product). `—` = not yet decided.
- **Target design** names the schema objects or components; "(to add)" marks a known gap.
- **Acceptance criteria** are drafts until the capability's spec in `docs/specs/` is approved.
- The working copy of this catalogue, with discovery evidence, is maintained outside the repository. Regenerate this file from it; don't edit both.

## Areas

- [Versions](#versions) (7)
- [Hierarchies & nodes](#hierarchies--nodes) (12)
- [Properties](#properties) (10)
- [Validations](#validations) (4)
- [Queries & compares](#queries--compares) (5)
- [Imports & bulk change](#imports--bulk-change) (3)
- [Exports & distribution](#exports--distribution) (8)
- [Blending](#blending) (3)
- [Governance (DRG)](#governance-drg) (16)
- [Security & access](#security--access) (5)
- [Audit & history](#audit--history) (4)
- [Admin & integration](#admin--integration) (4)
- [New capabilities](#new-capabilities) (10)

## Versions

### VER-01 — Create and copy versions

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Create a version, typically by copying the prior period's finalized version.
- **Target design:** mdm.version as a named data slice (no physical copy).
- **Acceptance criteria (draft):** A new period version can be created and shows identical data to its base at creation.
- **Golden test source:** Version list + node counts per version

### VER-02 — Version status lifecycle

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Working → Submitted → Finalized → Expired; finalized versions are read-only.
- **Target design:** mdm.version.status; finalized versions pin recorded_as_of.
- **Acceptance criteria (draft):** Edits are rejected in submitted/finalized versions; finalized data is unchanged by later corrections.
- **Golden test source:** Exports from past finalized versions

### VER-03 — As-of versions

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Rebuild a version as it stood at a past point in time from transaction history.
- **Target design:** Bitemporal reads at any business date and recorded time.
- **Acceptance criteria (draft):** Any past date can be queried without a rebuild and matches DRM's as-of output.
- **Golden test source:** DRM as-of exports for 3 sample dates

### VER-04 — Baseline versions

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Baseline kept for comparison with the working version.
- **Target design:** Named version slices + compare service.
- **Acceptance criteria (draft):** Baseline vs current differences reproduce DRM compare output.
- **Golden test source:** DRM compare export (baseline vs normal)

### VER-05 — Version variables

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Named pointers (e.g. current production version) used by exports, books and automation.
- **Target design:** Version alias table (to add to schema).
- **Acceptance criteria (draft):** Exports and jobs using a variable resolve to the right version after it changes.
- **Golden test source:** Export runs before/after a variable change

### VER-06 — Load, unload, backup and restore versions

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Versions loaded into memory; backed up and restored by admins.
- **Target design:** Not needed as a feature: database backup and point-in-time recovery.
- **Acceptance criteria (draft):** Point-in-time restore tested; users never load/unload versions.
- **Golden test source:** Operational DR test

### VER-07 — Version-level properties

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Properties attached to a version (e.g. period, status flags).
- **Target design:** Version property table (to add).
- **Acceptance criteria (draft):** Version-level properties display and export as in DRM.
- **Golden test source:** Version property values

## Hierarchies & nodes

### HIE-01 — Hierarchies, top nodes and groups

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Named trees with a top node, organised into hierarchy groups.
- **Target design:** mdm.hierarchy
- **Acceptance criteria (draft):** All hierarchies load with the same top node, group and node count as DRM.
- **Golden test source:** Hierarchy list + node counts

### HIE-02 — Add, insert, move, remove, delete

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Add a new node, insert an existing one elsewhere, move it, remove it from a hierarchy, or delete it from the version.
- **Target design:** mdm.hierarchy_relationship + change_item actions.
- **Acceptance criteria (draft):** Each action produces the same resulting tree as DRM.
- **Golden test source:** Before/after exports for scripted action sets

### HIE-03 — Shared nodes

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Same node under multiple parents in a hierarchy (primary + shared instances).
- **Target design:** hierarchy_relationship.is_primary = false
- **Acceptance criteria (draft):** Shared nodes display, export and validate as in DRM.
- **Golden test source:** Hierarchy exports containing shared nodes

### HIE-04 — Orphans

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Nodes in a version that belong to no hierarchy.
- **Target design:** View of nodes without relationships (to add).
- **Acceptance criteria (draft):** Orphan list matches DRM.
- **Golden test source:** DRM orphan list

### HIE-05 — Leaf / limb and promotion

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Leaf nodes cannot have children; a leaf can be promoted to a limb.
- **Target design:** node_attr.allows_children
- **Acceptance criteria (draft):** Adding a child under a leaf is blocked; promotion works.
- **Golden test source:** Validation results

### HIE-06 — Inactivate / reactivate nodes

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Mark nodes inactive without deleting them.
- **Target design:** node_attr.is_active
- **Acceptance criteria (draft):** Inactive nodes included/excluded per export settings exactly as DRM.
- **Golden test source:** Exports with include-inactive on and off

### HIE-07 — Node merge on delete

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** When deleting a node, repoint references to a replacement node.
- **Target design:** New change action 'merge_node' (to add).
- **Acceptance criteria (draft):** References repoint to the target node and the merge is logged.
- **Golden test source:** DRM merge log

### HIE-08 — Sibling sort order

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Custom ordering of children.
- **Target design:** hierarchy_relationship.sort_order
- **Acceptance criteria (draft):** Export row order matches DRM exactly.
- **Golden test source:** Hierarchy exports

### HIE-09 — Node types

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Node types control which properties and validations apply to a node.
- **Target design:** node_kind + property applicability by type (to add).
- **Acceptance criteria (draft):** Correct properties shown and validated per node type.
- **Golden test source:** Validation results by node type

### HIE-10 — Domains

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Govern node naming and uniqueness across versions.
- **Target design:** Identifier schemes + uniqueness rules.
- **Acceptance criteria (draft):** Domain rules enforced identically.
- **Golden test source:** Domain validation results

### HIE-11 — Model after (clone node)

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Create a node using another node as a template.
- **Target design:** UI action that generates change items.
- **Acceptance criteria (draft):** Clone has the source's property values except its name.
- **Golden test source:** n/a

### HIE-12 — Browse and edit large hierarchies

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Tree navigation, in-tree search, property grid.
- **Target design:** Virtualised tree UI on hierarchy_tree().
- **Acceptance criteria (draft):** Largest hierarchy loads and expands within the NFR targets.
- **Golden test source:** Performance test with production volumes

## Properties

### PRP-01 — Global and local properties

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Global values shared across hierarchies; local values specific to a hierarchy.
- **Target design:** property_definition.scope
- **Acceptance criteria (draft):** Every property migrated with the correct scope; values match.
- **Golden test source:** Property value extract

### PRP-02 — Property data types

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** String, integer, decimal, boolean, date, list, node reference, memo and others.
- **Target design:** property_data_type + validation trigger.
- **Acceptance criteria (draft):** Type rules enforced; values round-trip exactly.
- **Golden test source:** Property value extract

### PRP-03 — List properties

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Allowed-value lists.
- **Target design:** property_list_value
- **Acceptance criteria (draft):** Only listed values accepted; lists match DRM.
- **Golden test source:** List definitions

### PRP-04 — Lookup properties

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Value looked up from a table keyed on another property.
- **Target design:** Derived property (sql engine) or lookup table (to add).
- **Acceptance criteria (draft):** Lookup results match DRM for every node.
- **Golden test source:** Derived value extract

### PRP-05 — Inheritance and overrides

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Values inherited from ancestors, with overrides and locks at lower nodes.
- **Target design:** property_definition.inheritance + property_value_asof()
- **Acceptance criteria (draft):** Inherited values match DRM for every node in every hierarchy.
- **Golden test source:** Inherited value extract

### PRP-06 — Derived properties (formulas/scripts)

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Values calculated from formulas or scripts.
- **Target design:** derivation_expr (original kept in drm_formula_orig).
- **Acceptance criteria (draft):** Each in-use derived property returns DRM's value for all nodes.
- **Golden test source:** Derived value extract (key golden test)

### PRP-07 — System / core properties

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Built-ins such as name, description, level, child count, leaf.
- **Target design:** Columns in export and tree functions.
- **Acceptance criteria (draft):** Values match DRM.
- **Golden test source:** Exports

### PRP-08 — Property categories

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Group properties for display and access.
- **Target design:** property_category
- **Acceptance criteria (draft):** Same grouping in the UI.
- **Golden test source:** n/a

### PRP-09 — Property-level edit permissions

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Restrict which users can edit which properties.
- **Target design:** Workflow tasks + entitlement model (to add for direct edits).
- **Acceptance criteria (draft):** Unauthorised edits rejected.
- **Golden test source:** Security test cases

### PRP-10 — Hierarchy-level properties

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Properties attached to a hierarchy object.
- **Target design:** Hierarchy property table (to add).
- **Acceptance criteria (draft):** Values display and export as in DRM.
- **Golden test source:** Hierarchy property values

## Validations

### VAL-01 — Real-time validations

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Run on each edit and block invalid changes.
- **Target design:** Rules engine run on change requests.
- **Acceptance criteria (draft):** Invalid edits blocked with an equivalent message.
- **Golden test source:** DRM outcomes for scripted edits

### VAL-02 — Batch validations

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Run on demand across a version or hierarchy.
- **Target design:** validation_rule + validation_result
- **Acceptance criteria (draft):** Batch results match DRM.
- **Golden test source:** DRM batch validation output

### VAL-03 — Validation levels and assignments

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Node, hierarchy and version levels; assigned to hierarchies or versions.
- **Target design:** validation_rule.level + hierarchy_id
- **Acceptance criteria (draft):** Each rule applies in exactly the same scope.
- **Golden test source:** Validation output by scope

### VAL-04 — Formula / script validations

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Custom validation logic in formulas or scripts.
- **Target design:** Rules as code (original kept in drm_validation_orig).
- **Acceptance criteria (draft):** Each rule converted with automated tests.
- **Golden test source:** Validation outputs

## Queries & compares

### QRY-01 — Property queries

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Find nodes by property criteria; saved and shared.
- **Target design:** Query builder over node_filter / property_value_asof().
- **Acceptance criteria (draft):** Same node set returned for each saved query.
- **Golden test source:** Query results

### QRY-02 — Compares

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Structure, property and rename compares between hierarchies or versions.
- **Target design:** Diff service on bitemporal data.
- **Acceptance criteria (draft):** Same differences reported.
- **Golden test source:** DRM compare output

### QRY-03 — Search

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Find nodes by name or description.
- **Target design:** Search index.
- **Acceptance criteria (draft):** Results returned within NFR targets.
- **Golden test source:** n/a

### QRY-04 — Node change history

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** View the history of changes to a node.
- **Target design:** audit_log + bitemporal history.
- **Acceptance criteria (draft):** Complete history visible per node.
- **Golden test source:** Transaction log sample

### QRY-05 — Edit from query and compare results

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Edit nodes and properties directly from query or compare result lists.
- **Target design:** Bulk-edit from result grids creating a change request.
- **Acceptance criteria (draft):** Edits from results go through the same governance as other edits.
- **Golden test source:** n/a

## Imports & bulk change

### IMP-01 — Imports

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Load hierarchies and properties from flat files into a version.
- **Target design:** Import pipeline that creates change requests.
- **Acceptance criteria (draft):** The same file produces the same structure.
- **Golden test source:** DRM import samples

### IMP-02 — Action scripts

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Apply bulk actions (add, move, update property) from a file.
- **Target design:** Bulk change request from file.
- **Acceptance criteria (draft):** The same script produces the same result.
- **Golden test source:** Before/after exports

### IMP-03 — Bulk property updates

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Mass-edit property values.
- **Target design:** Bulk edit in UI creating a change request.
- **Acceptance criteria (draft):** Bulk edits apply atomically with validation.
- **Golden test source:** Before/after exports

## Exports & distribution

### EXP-01 — Hierarchy exports

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** One row per node with parent and properties.
- **Target design:** export_profile (type hierarchy) + export_drm().
- **Acceptance criteria (draft):** Byte-for-byte match with DRM files.
- **Golden test source:** DRM export files

### EXP-02 — Generation exports

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Ancestors spread across columns.
- **Target design:** export_profile (type generation).
- **Acceptance criteria (draft):** Byte-for-byte match.
- **Golden test source:** DRM export files

### EXP-03 — Hierarchy XML exports

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** XML output of hierarchies.
- **Target design:** Export service (to build).
- **Acceptance criteria (draft):** Output matches DRM.
- **Golden test source:** DRM export files

### EXP-04 — Compare / difference exports

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Changes between hierarchies or versions as files.
- **Target design:** Export service (to build).
- **Acceptance criteria (draft):** Output matches DRM.
- **Golden test source:** DRM export files

### EXP-05 — Transaction log exports

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Audit extracts to file.
- **Target design:** audit_log extract.
- **Acceptance criteria (draft):** Output matches DRM.
- **Golden test source:** DRM export files

### EXP-06 — Export targets and delivery

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Write to files, database tables or other targets.
- **Target design:** Delivery adapters in the export service.
- **Acceptance criteria (draft):** Files/tables delivered to the same locations on the same schedule.
- **Golden test source:** Delivery logs

### EXP-07 — Books

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Named groups of exports run together.
- **Target design:** Export bundles (to add).
- **Acceptance criteria (draft):** A book run produces every file.
- **Golden test source:** Book output

### EXP-08 — Export filters and format options

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Query filters, inactive/shared handling, column and format options.
- **Target design:** export_profile options.
- **Acceptance criteria (draft):** Every option reproduces DRM's output.
- **Golden test source:** DRM export files

## Blending

### BLD-01 — Blenders

- **Decision / priority / phase:** Retire / — / —
- **Legacy behaviour:** Merge hierarchies, nodes and properties from a source version into a target.
- **Target design:** Sandbox change request: diff, conflict check, atomic apply.
- **Acceptance criteria (draft):** Blending a sample produces the same target state as DRM.
- **Golden test source:** Pre/post blend exports

### BLD-02 — Remove vs mark-for-removal

- **Decision / priority / phase:** Retire / — / —
- **Legacy behaviour:** Remove nodes immediately or flag them for later removal.
- **Target design:** remove_node action + flag property.
- **Acceptance criteria (draft):** Both modes behave as in DRM.
- **Golden test source:** Pre/post blend exports

### BLD-03 — Scenario / restructure versions

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Isolated what-if versions for restructuring.
- **Target design:** Sandboxes that branch and can be discarded (to add).
- **Acceptance criteria (draft):** Scenario can be built, compared and applied or discarded.
- **Golden test source:** n/a

## Governance (DRG)

### GOV-01 — Workflow models

- **Decision / priority / phase:** Parity / — / —
- **Legacy behaviour:** Define stages, tasks and participants per type of change.
- **Target design:** wf.workflow_model (versioned)
- **Acceptance criteria (draft):** Every in-use model configured and routing identically.
- **Golden test source:** Request histories

### GOV-02 — Submit / Enrich / Approve / Commit stages

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Stage types controlling participation.
- **Target design:** wf.workflow_stage
- **Acceptance criteria (draft):** Stages behave as in DRG.
- **Golden test source:** Request histories

### GOV-03 — Workflow tasks and editable properties

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Which actions and properties each stage may change.
- **Target design:** wf.workflow_task + task_property
- **Acceptance criteria (draft):** Only permitted edits allowed per stage.
- **Golden test source:** Request histories

### GOV-04 — Conditional stages and request splitting

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Stages included by property values or failed validations; items split into separate requests.
- **Target design:** workflow_stage.condition + split_instance()
- **Acceptance criteria (draft):** Same routing and splits as DRG.
- **Golden test source:** Request histories

### GOV-05 — Separation of duties

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Approver must not have submitted or approved another stage.
- **Target design:** wf.sod_violation()
- **Acceptance criteria (draft):** SoD violations blocked.
- **Golden test source:** Security test cases

### GOV-06 — Approval groups and methods

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Groups per stage; any-group or all-groups approval.
- **Target design:** wf.stage_group + approval_method
- **Acceptance criteria (draft):** Approval outcomes match DRG.
- **Golden test source:** Request histories

### GOV-07 — Claims, durations and SLAs

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Claim requests; request and claim durations; overdue tracking.
- **Target design:** claim_expires_at, due_at, v_sla_status
- **Acceptance criteria (draft):** Overdue requests flagged correctly.
- **Golden test source:** SLA reports

### GOV-08 — Notifications

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Notify participants of request activity.
- **Target design:** event_outbox + notifier service
- **Acceptance criteria (draft):** Right people notified at each step.
- **Golden test source:** Notification logs

### GOV-09 — Push-back and re-approval

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Return a request to an earlier stage; re-approval rules.
- **Target design:** workflow_stage.reapproval + instance_stage.iteration
- **Acceptance criteria (draft):** Push-back and re-approval match DRG.
- **Golden test source:** Request histories

### GOV-10 — Bulk requests from file

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Load request items from a file.
- **Target design:** Import pipeline creating change items.
- **Acceptance criteria (draft):** Bulk requests created and routed correctly.
- **Golden test source:** n/a

### GOV-11 — Request comments and attachments

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Discussion and supporting documents on requests.
- **Target design:** instance_action comments + evidence_document
- **Acceptance criteria (draft):** Comments and files retained with the request.
- **Golden test source:** n/a

### GOV-12 — Straight-through commit

- **Decision / priority / phase:** Improve / Must / 1 - Core + first slice
- **Legacy behaviour:** A request is promoted to Commit and committed immediately, with no human approver ('No assignees available' in the activity log).
- **Target design:** wf.commit_policy + apply_commit_policy(); shadow mode, freeze windows, caps, kill switch, sampled post-commit review (06_wf_commit_policy.sql).
- **Acceptance criteria (draft):** Eligible requests commit automatically after validations; ineligible ones route to a human; every auto-commit is logged with the policy that allowed it.
- **Golden test source:** Request histories

### GOV-13 — Worklist views and flags

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Personal worklist filtered by Assigned, Urgent, Overdue, Claimed, Submitted, Drafted, Participated, Notified, All; search and model filter.
- **Target design:** wf.worklist() + UI filters (urgent flag to add).
- **Acceptance criteria (draft):** Each filter returns the same requests as DRM for a sample user.
- **Golden test source:** Worklist samples

### GOV-14 — Request tags

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Free-form tags on requests for grouping and search.
- **Target design:** Tag table on change_request (to add).
- **Acceptance criteria (draft):** Tags can be added, searched and reported on.
- **Golden test source:** n/a

### GOV-15 — Governance analytics

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Analytics on request volumes, ageing and SLA performance.
- **Target design:** Dashboard over wf tables.
- **Acceptance criteria (draft):** Same metrics available as today, refreshed at least daily.
- **Golden test source:** Analytics exports

### GOV-16 — Alerts

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** In-app alerts about request activity.
- **Target design:** event_outbox + in-app notifications.
- **Acceptance criteria (draft):** Users see alerts for their requests; volume is actionable.
- **Golden test source:** n/a

## Security & access

### SEC-01 — Users and roles

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Application roles (e.g. admin, data manager, workflow users).
- **Target design:** app_user + role model (to add).
- **Acceptance criteria (draft):** Each role can do exactly what it should.
- **Golden test source:** Security test cases

### SEC-02 — Node access groups

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Permissions by hierarchy and sub-tree (read, edit, insert, etc.).
- **Target design:** Entitlements by scope + wf.stage_access_scope
- **Acceptance criteria (draft):** Access matches DRM per user.
- **Golden test source:** Access matrix sample

### SEC-03 — Property access

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Read/edit rights by property or category.
- **Target design:** Entitlements by property category.
- **Acceptance criteria (draft):** Access matches DRM.
- **Golden test source:** Security test cases

### SEC-04 — Object access

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Personal vs shared vs system queries, exports and other objects.
- **Target design:** Ownership/sharing on saved objects.
- **Acceptance criteria (draft):** Visibility matches DRM.
- **Golden test source:** n/a

### SEC-05 — Authentication / SSO

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** External authentication via directory services.
- **Target design:** Corporate SSO (OIDC/SAML).
- **Acceptance criteria (draft):** Users sign in with corporate SSO.
- **Golden test source:** n/a

## Audit & history

### AUD-01 — Transaction history

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Who changed what and when, with filters.
- **Target design:** mdm.audit_log (append-only)
- **Acceptance criteria (draft):** Every change traceable to actor and request.
- **Golden test source:** Transaction log sample

### AUD-02 — Request history

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Full history of each governance request.
- **Target design:** wf.instance_action
- **Acceptance criteria (draft):** Complete, immutable request history.
- **Golden test source:** Request histories

### AUD-03 — Job and export run history

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Logs of batch jobs and exports.
- **Target design:** export_run + job logs
- **Acceptance criteria (draft):** Every run logged with outcome and file hash.
- **Golden test source:** Job history

### AUD-04 — Audit retention

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** How long history is kept.
- **Target design:** Retention policy + archival.
- **Acceptance criteria (draft):** History retained for the required period.
- **Golden test source:** n/a

## Admin & integration

### ADM-01 — Environments and metadata migration

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Move configuration between environments.
- **Target design:** Configuration as code with versioned deployments.
- **Acceptance criteria (draft):** Config promoted between environments reproducibly.
- **Golden test source:** n/a

### ADM-02 — Web service API

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Programmatic access for integrations.
- **Target design:** REST/GraphQL API + events.
- **Acceptance criteria (draft):** Every current integration has an equivalent API.
- **Golden test source:** Integration test suite

### ADM-03 — Batch client automation

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Scheduled scripts that run imports, exports, validations.
- **Target design:** Scheduler + API.
- **Acceptance criteria (draft):** Every scheduled job reproduced or retired.
- **Golden test source:** Job outputs

### ADM-04 — Downstream integrations

- **Decision / priority / phase:** — / — / —
- **Legacy behaviour:** Feeds to EPM, ERP, data warehouse and others.
- **Target design:** Exports, APIs and events.
- **Acceptance criteria (draft):** Every consumer cut over with a passing parallel run.
- **Golden test source:** Reconciliation results

## New capabilities

### NEW-01 — Any-date history without rebuild

- **Decision / priority / phase:** New / — / —
- **Legacy behaviour:** Not available in DRM (as-of versions need a rebuild).
- **Target design:** Bitemporal model.
- **Acceptance criteria (draft):** Any date/time queryable instantly.
- **Golden test source:** n/a

### NEW-02 — Ownership graph and UBO

- **Decision / priority / phase:** New / — / —
- **Legacy behaviour:** Not available in DRM.
- **Target design:** ownership_edge + ubo_ownership_prong / ubo_control_prong
- **Acceptance criteria (draft):** UBOs computed with paths and evidence.
- **Golden test source:** Compliance-verified samples

### NEW-03 — AI document-to-graph extraction

- **Decision / priority / phase:** New / — / —
- **Legacy behaviour:** Not available in DRM.
- **Target design:** AI extraction service creating evidence-linked change requests.
- **Acceptance criteria (draft):** Extraction accuracy meets agreed threshold; every fact cites evidence.
- **Golden test source:** Labelled document set

### NEW-04 — AI change-request drafting

- **Decision / priority / phase:** New / — / —
- **Legacy behaviour:** Not available in DRM.
- **Target design:** AI agent as requester (human approval).
- **Acceptance criteria (draft):** Drafts accepted without edits at agreed rate.
- **Golden test source:** Historical requests

### NEW-05 — AI anomaly detection

- **Decision / priority / phase:** New / — / —
- **Legacy behaviour:** Not available in DRM.
- **Target design:** Steward agents raising warnings/change requests.
- **Acceptance criteria (draft):** Detects seeded anomalies at agreed recall.
- **Golden test source:** Seeded test data

### NEW-06 — Natural-language query

- **Decision / priority / phase:** New / — / —
- **Legacy behaviour:** Not available in DRM.
- **Target design:** NL query over APIs (read-only).
- **Acceptance criteria (draft):** Answers match equivalent structured queries.
- **Golden test source:** Query test set

### NEW-07 — Real-time API and events

- **Decision / priority / phase:** New / — / —
- **Legacy behaviour:** DRM is batch-oriented.
- **Target design:** API + event stream.
- **Acceptance criteria (draft):** Changes published within agreed latency.
- **Golden test source:** Integration tests

### NEW-08 — Sandboxes and scenarios

- **Decision / priority / phase:** New / — / —
- **Legacy behaviour:** Partly via versions + blending.
- **Target design:** Sandbox overlay, diff, conflict detection, atomic apply.
- **Acceptance criteria (draft):** Sandbox lifecycle works end to end.
- **Golden test source:** n/a

### NEW-09 — Parallel-run reconciliation

- **Decision / priority / phase:** New / — / —
- **Legacy behaviour:** Not available in DRM.
- **Target design:** export_run + drm_reconciliation
- **Acceptance criteria (draft):** Daily automated comparison with DRM during parallel run.
- **Golden test source:** DRM export files

### NEW-10 — Modern steward UX

- **Decision / priority / phase:** New / — / —
- **Legacy behaviour:** DRM web client.
- **Target design:** New web app: impact preview, side-by-side compare, inbox.
- **Acceptance criteria (draft):** Usability targets met in testing.
- **Golden test source:** Usability tests
