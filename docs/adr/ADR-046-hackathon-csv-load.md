# ADR-046: Load the hackathon CSV data set; display names, property applicability, ledgers and one rule catalogue

- **Status:** Accepted (repository owner, 2026-11-20: "approved", for the design in Phase 4 LLD §17 and every recommendation C-1 to C-7, including the screen and scripts). The owner's decisions D1 to D7 were given on 2026-11-20 ("1 - add a display-name 2. add new
  columns 3. ignore and dont do anything now 4. go with your recommendation 5 - need one place to manage rules
  (including the ones already existing) ignore FEED for now ... 6) pause for later phase 7) go with your
  recommendation").
- **Date:** 2026-11-20
- **Deciders:** Repository owner
- **Capabilities:** IMP-01, HIE-01, HIE-02, PRP-01, PRP-02, VAL-01, VAL-03, VER-01, VER-02, SEC-01; PROG (loader)
- **Amends:** Phase 4 LLD (input format, §17 added); Phase 1 data model (node, property definition, validation rule);
  the build order (Phase 4 increments for this format come ahead of the rest of Phase 5, if C-6 is approved)

## Context
Nexus is being presented at a hackathon. The hackathon team supplied a data set to load as 12 CSV files with fixed
formats (`data/`, git-ignored, synthetic sample only): hierarchies, nodes, relationships, attribute definitions and
values, reference lists, ledgers, validation rules, versions, users, groups and roles.

The Phase 4 loader is designed for a DRM extract, refers to nodes by name, and is not built. Comparing the files with
the schema found seven gaps:
1. A node has a code, a name and a description; Nexus has only `node_name` (the business key) and `description`.
2. An attribute names the hierarchies it applies to and a node filter (LEAF, LIMB, ANY); `property_definition` has neither.
3. Reference lists are shared by name (YES_NO is used by seven attributes); Nexus keeps list values per property.
4. Ledgers (id, name, currency, finance country) have no table, and rule VR17 needs a ledger's currency.
5. Validation rules come as descriptions with a mode (IMPORT, REAL_TIME, BOTH), a level (including FEED) and a
   `core_path` flag. `validation_rule` needs an expression, has no mode or name, and several of the rules are
   already enforced by database guards (VR02, VR05, VR06, VR07, VR08), so they exist in two places.
6. Derived attributes (OC, BG, BU, FULL_NAME) are described in English, not as formulas.
7. Versions carry no business date, and no data row says which version it belongs to.

## Decision
- **D1. Display name (owner: "add a display-name").** `node_attr` gains `display_name`. The CSV `node_code` becomes
  `node_name` (the business key, unchanged everywhere it is used), the CSV `node_name` becomes `display_name`, and the CSV
  `description` becomes `description`. The UI shows the display name and the code; search matches both.
- **D2. Property applicability (owner: "add new columns").** A property definition gains the hierarchies it applies to
  (none listed = every hierarchy) and a node filter (`any`, `leaf`, `limb`). Setting a value where the property does
  not apply is refused (C-2), and the property grid lists only applicable properties.
- **D3. Shared lists (owner: "ignore and don't do anything now").** No model change. The loader copies a named list's
  values to each property that uses it. A BOOLEAN attribute's YES_NO list is ignored, and Y/N load as true/false.
- **D4. Ledgers (owner: recommendation).** A small configuration table `mdm.ledger` (id, name, currency, finance
  country), loaded by the loader and readable by every role. The LEDGER_ID property's list holds the ledger ids, and
  rules may join the table.
- **D5. One rule catalogue (owner: "one place to manage rules, including the ones already existing").**
  - `validation_rule` becomes the single catalogue. Every existing database guard gets a catalogue row marked as a
    guard, with its error code or constraint. The guards are unchanged and stay in force (CLAUDE.md rule 1).
  - A guard row cannot be deactivated, deleted or have its severity, level or check changed; only its labels can be
    edited. Findings from a guard are reported under its catalogue row instead of the generic NEXUS.TRIAL_APPLY.
  - Rules gain a name, a mode (`real_time`, `import`, `both`) and an external code (the customer's id, such as VR07).
  - Rule expressions stay SQL (the CEL engine for rules is still OD-19). Expressions come from a reviewed rule library
    in the repository, keyed by rule code. A rule with no library entry loads inactive and is listed in the load report.
  - ADMIN gets one screen and API to list every rule and guard, and to edit rule rows (C-3).
  - FEED rules (VR00) are skipped for now and listed in the load report.
- **D6. Derived attributes (owner: "pause for later phase").** Not loaded; listed in the load report. They will
  be written in CEL with PRP-06 (Phase 5 increments 5-10 and 5-11).
- **D7. Versions (owner: recommendation).**
  - Each version's business date is the load date.
  - Data loads into the version the load names. If none is named, it goes to the latest working version, and the load
    stops if there is none.
  - Versions are created as working through the existing functions. Non-working statuses are reached after the data
    load through the existing lifecycle: the preparer submits, and the load-run approver (a second ADMIN, as the
    version guard already requires) finalizes and expires.
  - The target version is shown in the load preview and the load report.
- **D8 (proposed, C-5).** `hierarchy` gains a `description` column so the CSV description is kept.
- **D9. How loads are run (owner: "Screen and scripts").**
  - An Admin › Data loads screen covers upload, check, prepare, approve by a second ADMIN, apply, and the report and
    history.
  - The `load-data` scripts (bash and PowerShell) run the same engine, for rehearsals and bulk loads.
  - Uploads are staged through a SECURITY DEFINER function owned by the loader role. The API therefore needs no
    loader credential, and `mdm_stage` is still written only by the loader.

Everything the loader writes to `mdm` goes through change requests or the existing governed functions, under a load
run approved by a second person (Phase 4 LLD §6.1). Nothing is copied into `mdm` directly.

## Alternatives considered
- **Code into `node_name`, name into `description` (no D1).** No schema change, but the CSV description would be lost
  and the screens would show codes. The owner chose a display name.
- **Applicability as a warning rule instead of columns.** Too weak for a property that must not exist on a node.
  The owner chose columns.
- **Shared named lists (`reference_list` table).** A cleaner model, but the owner deferred it. Copying values per
  property needs no change and can be migrated later.
- **Ledgers as nodes with attributes.** That reuses the model but turns reference data into hierarchy data, and VR17
  becomes a node-to-node lookup. A table is simpler.
- **Leave the guards out of the catalogue.** That leaves rules in two places, which is what the owner wants to avoid.
- **Make guards switchable from the catalogue.** That would weaken a control (CLAUDE.md rule 1). Rejected.

## Consequences
- New migration `V16__hackathon_load.sql` (next free number). Rule 6 still allows edits to V1–V15, but a new file keeps
  the change reviewable.
- The node API, the change actions `add_node` and `update_node`, the property grid, search and the history views carry
  the display name. DRM exports keep `node_name`.
- Finding the right guard row needs one error-code change. "Parent not in hierarchy" moves from the shared
  N2105 to its own code, N2007 `hierarchy.parent_missing`. The check itself is unchanged, and no guard is weakened.
- Users are provisioned by a new ADMIN-only, audited function, because no governed path creates `app_user` rows yet.
- The Phase 4 synthetic generator, golden framework and performance baseline are unchanged and still follow.
- Open: OD-19 (CEL for rules), OD-29 (how load runs are approved), and the owner's choices C-1 to C-7 (LLD §17.10).
