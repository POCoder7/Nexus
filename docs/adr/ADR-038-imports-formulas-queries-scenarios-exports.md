# ADR-038: Imports, derived properties, queries and compares, scenarios and exports: decisions and sequence

- **Status:** Accepted by the repository owner on 2026-11-14 ("approved for going ahead"): every recommendation, with D3
  amended the same day so that Phase 5 is built before Phase 4 (see Decision). Product still confirms EXP-03 from the export inventory
- **Date:** 2026-11-14
- **Deciders:** Repository owner (D1 to D5); Product confirms in discovery the rows marked "confirm"
- **Capabilities:** PRP-06, QRY-01 to QRY-05, IMP-01 to IMP-03, EXP-01 to EXP-08, BLD-03, NEW-08 (BLD-01 and BLD-02 stay retired)

## Context
On 2026-11-14 the repository owner asked to build "derived-property formulas; queries and compares; imports and action
scripts; all exports; the replacement for blending". In the catalogue and the approved designs they are:

| Asked for | Capabilities | Catalogue decision | Phase (TRACEABILITY) | Design today |
|---|---|---|---|---|
| Derived-property formulas | PRP-06 | — | 5 | Outline (Phase 5 LLD §15.1) |
| Queries and compares | QRY-01 to QRY-05 | — | 5 | Outlines. Phase 3 built in-tree search (as part of HIE-12) and the QRY-04 History tab, but no QRY decision is recorded |
| Imports and action scripts | IMP-01, IMP-02; IMP-03 bulk property updates | — | 4; IMP-03 in 5 | Outlines (Phase 4 LLD §15, Phase 5 LLD §15.1) |
| All exports | EXP-01 to EXP-08 | — | 8 | Outlines (Phase 8 LLD §15). The export core (PROG: profiles, streaming runs, bundles, run history) is designed in full |
| Replacement for blending | BLD-01, BLD-02 retired; NEW-08 sandboxes; BLD-03 scenarios | NEW-08 New; BLD-03 — (OD-12) | 5 | NEW-08 designed in full (Phase 5 LLD §3 to §13, ADR-028) |

What exists already:
- **Exports.** `mdm.export_profile` holds the profile: a `node_filter` JSON, columns and format options. `mdm.export_drm` and
  `mdm.run_export` (V3) produce hierarchy and generation exports in SQL. Other types are refused (`N2608`, "produced by the
  export service").
- **Derived properties.** `property_definition` has `derivation_engine` (`sql`, `cel` or `python`), `derivation_expr` and
  `drm_formula_orig` (V1). Only `sql` is evaluated, by running the stored expression with `EXECUTE` (D-39). `cel` and
  `python` values read as NULL. OD-19 chose CEL evaluated in Java, but the library still needs approval.
- **Queries.** `node_passes_filter` evaluates the `node_filter` JSON for exports. Phase 3 added in-tree search by name or
  description (trigram index) and the node History tab.
- **Imports.** There are none for users. Phase 4 designs the migration loader (staging intake, a converter into governed
  change requests, load runs, ADR-026), which IMP-01 and IMP-02 would reuse.

Constraints that shape the options:
1. **Build order.** BUILD_PROTOCOL §2 sets the order 3 → 4 → 5 → 6 → 8. Each phase starts only after the previous gate is
   approved, and the Phase 3 gate is still awaiting approval.
2. **Dependencies between the requested items.**
   - IMP-01 and IMP-02 reuse the Phase 4 converter.
   - Difference exports (EXP-04) and baseline versions (VER-04) need the QRY-02 compare service from Phase 5.
   - Delivery to object storage uses the document store from Phase 6 (OD-16a).
3. **Proof of parity.** Every acceptance criterion in these rows compares Nexus output with DRM output (golden tests,
   ADR-009). The golden datasets are masked and kept in an internal artefact store, never in this public repository
   (OD-31, OD-32; confirmations OD-31a and OD-32a pending). Nobody working in this repository has seen a DRM import file,
   action script or export file.
4. **Deterministic calculations** (CLAUDE.md rule 4). People translate the formulas and test them. No AI model writes or
   evaluates a formula (Phase 7 is deferred, OD-38).

## Decisions to take

### D1: Capability decisions (OD-09)

| ID | Recommendation | Phase | Why |
|---|---|---|---|
| PRP-06 Derived properties | **Parity** | 5 | Downstream files carry derived values. Each formula in use is translated with its original kept in `drm_formula_orig`, and is accepted only when the golden derived-value test matches DRM for every node |
| QRY-01 Property queries | **Parity** | 5 | A saved query uses the same JSON as `node_filter` and returns paged results. It is private or shared with everyone who can read the hierarchy; finer sharing waits for SEC-04 |
| QRY-02 Compares | **Parity** | 5 | Structure, property and rename compares between any two slices (hierarchy plus version or as-of date). Set-based SQL with paged or streamed results. EXP-04, VER-04 and the blending replacement (D2) reuse it |
| QRY-03 Search | **Parity** | 5 | Phase 3 searches within one hierarchy. This adds search across hierarchies with PostgreSQL full-text and `pg_trgm` (OD-21) |
| QRY-04 Node history | **Parity** (records only) | 3 (built) | The History tab was built in Phase 3's second scope extension. This records the decision; the golden check against a transaction-log sample runs when the Phase 4 harness exists |
| QRY-05 Edit from results | **Parity** | 5 | Query and compare result grids add items to the tray, under the same governance as any other edit |
| IMP-01 Imports | **Improve** | 4 | Reads DRM's import file format unchanged. DRM writes the file straight into a version; Nexus turns it into a draft change request that is validated and approved like any other. Large files use the load-run path (ADR-026) |
| IMP-02 Action scripts | **Improve** | 4 | Reads DRM's action-script format unchanged. One script becomes one draft request, applied as a unit after approval, with a result per line like DRM's script log |
| IMP-03 Bulk property updates | **Parity** | 5 | Select many rows in the grid, then many `set_property` items go into one request, validated and applied as a unit, up to a named size limit |
| EXP-01 Hierarchy exports | **Parity** | 8 | The SQL generator exists. Byte parity is proved per profile by golden tests |
| EXP-02 Generation exports | **Parity** | 8 | Same as EXP-01 |
| EXP-03 Hierarchy XML exports | **Parity if in use** (confirm) | 8 | Build only if the export inventory (`drm_export_definition`) shows XML exports in use; retire otherwise |
| EXP-04 Compare / difference exports | **Parity** | 8 | A generator over the QRY-02 compare service |
| EXP-05 Transaction log exports | **Parity** | 8 | A generator over `audit_log` and requests for a period, filtered by the caller's scope |
| EXP-06 Targets and delivery | **Improve** | 8 | Object storage (OD-16) and a file-share drop by default. Database-table targets go through a staging table and a governed loader. Each further adapter (for example SFTP) only when a consumer needs it, as its own dependency approval |
| EXP-07 Books | **Parity** | 8 | Bundles (Phase 8 LLD §4.2) shown to users as books, with owners and schedules |
| EXP-08 Filters and format options | **Parity** | 8 | The options already exist as profile columns. Golden tests per option |

### D2: Scenarios and the replacement for blending (OD-12, BLD-03)
DRM blenders merge hierarchies, nodes and properties from a source version into a target version. Nexus keeps one
bitemporal store, so each way DRM users use blending gets its own replacement:

| What blending is used for in DRM | Replacement in Nexus |
|---|---|
| Roll a period forward into the next version | Not needed. A version is a named slice of the one store (ADR-037), so the next version already sees the data |
| Build a restructure in isolation, then merge it | A sandbox (NEW-08): edit in an overlay, compare it with the live tree, resolve conflicts, then apply it as one governed request or discard it |
| Copy selected nodes or properties from one version to another | Compare the two slices (QRY-02), then edit from the results (QRY-05) into a sandbox or a bulk update (IMP-03) |
| Remove vs mark for removal (BLD-02) | Stays retired. Remove and delete already exist (Phase 3), with an impact preview |

| Option | Meaning | Notes |
|---|---|---|
| **A. BLD-03 is met by NEW-08 sandboxes (recommended)** | BLD-03 is recorded as Improve, and scenarios are sandboxes as designed: one owner, collaborators can view, applied as one request, up to `SANDBOX_MAX_ITEMS` | No new design. The catalogue test "a scenario is built, compared, applied or discarded" joins the NEW-08 tests |
| B. As A, plus applying only part of a sandbox | The owner picks some items; they are split into a new request, re-checked for conflicts and applied | Closer to filtered blending, but adds a split-and-recheck step. Worth it only if discovery finds filtered blends in use; it can be added later without rework |
| C. Retire BLD-03 | Sandboxes are still built (NEW-08 is decided) | No scenario acceptance test. Users who model restructures today lose a named concept |

### D3: Sequence

| Option | Order | Notes |
|---|---|---|
| **A. Protocol order (recommended)** | Approve the Phase 3 gate, then:<br>Phase 4: loader, synthetic generator, golden harness, IMP-01, IMP-02<br>Phase 5: NEW-08, SEC-01 and SEC-02 in full, PRP-06, QRY-01 to QRY-05, IMP-03, BLD-03<br>Phase 6: ownership and UBO<br>Phase 8: export core, EXP-01 to EXP-08, NEW-07, NEW-09 | No protocol change, and each item lands after the things it depends on |
| B. Exports before ownership | As A, but Phase 8 runs before Phase 6 | BUILD_PROTOCOL §2 changes, and so do the dependency lines in the Phase 6 and 8 LLDs; the object-storage adapter moves from Phase 6 into Phase 8. Phases 4 and 5 are the same as in A, so this can wait until the Phase 5 gate |
| C. A fourth Phase 3 scope extension | All five areas now, the way versions were added | Not recommended. It is most of Phases 4, 5 and 8 at once, built before the golden harness that every acceptance criterion needs, and it skips decided infrastructure (loader, sandboxes, the full SEC model) |

### D4: New dependency for formulas (OD-19)

| Option | What | Notes |
|---|---|---|
| **A. Google's CEL for Java (`dev.cel`, Apache-2.0) (recommended)** | Formulas are CEL expressions, evaluated in Java over a node's resolved values | No side effects and no I/O, so a formula cannot reach the database (removes D-39 for new formulas). The exact version is proposed in the Phase 5 plan and must have been published at least four days earlier; the second laptop's 72-hour registry rule may apply to Maven too (unverified) |
| B. No library: only the existing `sql` engine | Each formula is stored SQL, run with `EXECUTE` | A formula author can run any SQL the function's role allows (D-39), and exports evaluate formulas row by row |
| C. A formula language written for Nexus | Our own parser and evaluator | A second language to specify, secure and test. Already rejected under OD-19 |

No other new dependencies are proposed:
- XML (EXP-03) uses the JDK's StAX.
- Import files and action scripts are delimited text, read with the JDK.
- Golden case files stay JSON, so no YAML library.
- Delivery adapters beyond object storage and a file share are proposed only when a consumer needs one.

### D5: What "parity" means when each phase closes

| Option | Meaning | Notes |
|---|---|---|
| **A. Build with synthetic data and Oracle's published file formats; parity stays unproven until the golden run (recommended)** | Readers and writers follow DRM's documented formats for import files, action scripts and exports. Each format lives in one adapter class. Each gate reports "built, parity not proven" until masked DRM outputs are compared (OD-31a, OD-32a) | Phases 1 to 3 reported their gaps the same way. If a real file differs from the documentation, only one adapter changes |
| B. Wait for masked DRM samples | Each item is built only after a masked sample of the real file is in the internal store | Exact from the start, but nothing can be built until the samples exist |

## Decision
Taken by the repository owner on 2026-11-14 (OD-46):
- **D1:** every row as recommended. EXP-03 stays "Parity if in use"; Product confirms it from the export inventory.
- **D2: A.** BLD-03 is Improve and is met by NEW-08 sandboxes. This closes OD-12.
- **D3: amended.** The owner approved option A, then the same day said "if you are building phase-4, wait lets complete
  phase-5". The build order is now **0, 1, 2, 3, 5, 4, 6, 8, 9**. Nothing had been built for Phase 4.
- **D4: A.** Google's CEL for Java (`dev.cel`). The exact version is proposed in the Phase 5 plan and must have been
  published at least four days earlier.
- **D5: A.** Build with synthetic data and Oracle's published formats; each gate reports parity as not proven until the
  golden run.

## Consequences
- **Protocol stops.** Every phase goes through them in order:
  1. The phase LLD gains a detailed design section for each capability decided here (DESIGN_PROTOCOL; stop for review). The
     §15 outlines are the starting points.
  2. The phase plan (stop for approval).
  3. Build and the gate (stop for approval).
- **Building Phase 5 before Phase 4 (D3 as amended).** Three Phase 5 items need Phase 4, so they wait for it and the
  Phase 5 gate reports them as "waits for Phase 4":
  - Increment 5-6, the DRM access-group mapper. It reads the staged DRM access groups and writes a load run of grants.
  - Every golden check. The harness is Phase 4 work.
  - The translation of the formulas in use. The list comes from Phase 4's profile of the extract. Phase 5 builds the CEL
    engine and the governed way to set a formula, and tests both with synthetic formulas only.
- **Migration numbers.** `V11` is versions (ADR-037). Phase 5 now takes the next numbers (`V12__sandboxes.sql` as designed,
  then the Phase 5 LLD §17 file). Phase 4's `V11__load_runs.sql` takes the next free number when Phase 4 is planned, and
  the later phases move up the same way. This changes the records only, not the design.
- **Records.** The catalogue, TRACEABILITY and the external working copy (OD-28) record each decision. The QRY-04 row
  records what Phase 3 built.
- **PRP-06.** The formulas in use are listed from the profile of the extract (Phase 4) and translated one at a time,
  keeping `drm_formula_orig`. Who may write a formula is a control (D-39): only through a governed change to the property
  definition.
- **IMP-01 and IMP-02** never write to `mdm` directly. A file becomes items in a draft change request (CLAUDE.md layer rule),
  and large files use ADR-026's load runs.
- **Exports.** The existing SQL generators are the reference (Phase 8 I-1). The Phase 4 performance baseline decides whether
  a set-based generator is needed (Phase 8 I-2), so BUILD_STATE open question 2 (run the baseline in Phase 4, or defer it)
  now affects Phase 8 as well.
- **Reconciliation** with DRM's daily files (NEW-09) still needs OD-39 and OD-40. The exports themselves do not.
