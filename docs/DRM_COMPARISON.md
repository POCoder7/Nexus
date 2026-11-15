# Nexus compared with Oracle DRM: review, gaps and recommendations

- **Status:** Review for the repository owner, Product, Architecture and Audit-Risk. It is not a decision record: any
  recommendation that changes scope or design needs its own entry in `docs/design/OPEN_DECISIONS.md` or an ADR.
- **Date:** 2026-11-14 · **Code state:** `develop` at `a3930cc` (Phases 0 to 3 approved; Phase 5 increments 5-1 to 5-3 built)
- **Capability:** PROG
- **Basis:** the tracked records in this repository (the capability catalogue, ADR-001 to ADR-040, the architecture
  overview, the phase designs, the gate test reports and `docs/BUILD_STATE.md`), the code and migrations, and Oracle's
  public documentation for Data Relationship Management (DRM) 11.2 (§9).
- **Limits:**
  - No DRM extract has been loaded yet, so nothing here rests on the organisation's own DRM configuration or usage.
    Statements about which DRM features are actually used are marked "to confirm".
  - The built / partly built / not built status of each capability is this review's reading of the records (listed in
    §10 so it can be checked). It is not a gate result.
  - The description of DRM's internals comes from Oracle's public documentation. Check it against the installed system
    before quoting it.

## 1. Summary

Nexus's design is stronger than DRM's on control, history and change safety, and what has been built is well tested.
It is not yet a replacement for DRM. About a quarter of the 91 catalogued capabilities are built, and none of the things
a cutover depends on exists yet: loading DRM data, DRM-compatible exports, sign-in, measured performance, and proof that
Nexus gives the same results as DRM.

**Where Nexus is ahead by design**
- One store keeps every fact with the date it is true and the time it was recorded. Any past date, and any "as we knew
  it then" view, can be read without rebuilding anything. DRM copies whole versions and rebuilds as-of versions from
  its transaction history.
- Every change goes through a change request, and the database itself enforces maker-checker, separation of duties,
  human-only decisions and an append-only audit log. In DRM, authorised users can also edit a version directly, outside
  governance.
- Changes are previewed exactly before they are applied (validation and sandboxes run the real apply code and roll it
  back), and stale assumptions are detected. DRM has no equivalent.
- It adds things DRM does not do: sandboxes, an ownership graph for beneficial-ownership analysis, and designed AI
  assistance under human approval.

**Where Nexus is behind**
- Nothing can yet be loaded from DRM or exported in DRM's formats (Phases 4 and 8).
- DRM formulas and validations must be rewritten, and the engine for them is not built.
- Many everyday steward features are missing: inactivating nodes, node types, queries, compares, bulk updates, batch
  validations, push-back, comments, analytics (§6.2).
- There is no real sign-in, no shared environment, and no notification of any kind.

**Main risks**
- Parity with DRM is unproven for every capability, and proving it needs data and outputs the team does not yet have.
- Performance at the assumed size (500,000 nodes in a hierarchy) has not been measured.
- A large share of the logic is PostgreSQL stored code. Whether Nexus must also run on Oracle is undecided (ADR-040,
  deferred), and that decision gets much more expensive once a shared environment exists.

**Top recommendations** (all eleven are in §7)
1. Start getting DRM evidence now: a masked extract, captured DRM outputs, and inventories of exports, formulas and
   validations.
2. Run the performance tests that are already written, before more is built on the same read path.
3. Decide database independence, yes or no, before the first shared environment.
4. Start sign-in, hosting and the Audit-Risk reviews now; they gate user testing and the parallel run.
5. Check the version model with DRM users: working versions in Nexus are not isolated from each other.

## 2. DRM today

- **DRM 11.2 is a current, supported release.** Oracle's downloads page lists build 11.2.26. Oracle's own pages give
  Premier Support "through at least" 2030 (the DRM 11.2 documentation), 2032 (the EPM 11.2 documentation index) and
  2033 (Oracle's 2022 Hyperion announcement). Oracle revises this date from time to time, so check the Lifetime Support
  Policy before quoting one. Either way, **no end of vendor support forces a replacement date**. The case for Nexus
  rests on capability (ADR-001), and cutover should be driven by proven parity, not a deadline.
- **Oracle's own successor is Oracle Enterprise Data Management Cloud**, with a documented migration path from DRM.
  ADR-001 considered it and chose to build Nexus (no ownership graph, limited AI). This review does not reopen that.
- **What DRM is.** A hierarchy-management product: versions, hierarchies and nodes, properties (stored, inherited,
  derived by formula or script), validations, queries and compares, imports, action scripts and blenders, and exports
  and books for downstream systems. Data Relationship Governance (DRG) adds request workflows on top. The catalogue
  (`docs/capabilities.md`) lists 81 DRM and DRG capabilities and 10 new ones.

## 3. Coverage at a glance

Status of the 91 capabilities at `a3930cc`. "Built" means built and tested on synthetic data. It never means "proven
equal to DRM": no golden comparison has run yet. §10 lists the capabilities in each cell.

| Area | Total | Built | Partly | Not yet | Out of scope |
|---|---:|---:|---:|---:|---:|
| Versions | 7 | 2 | 1 | 3 | 1 |
| Hierarchies and nodes | 12 | 4 | 2 | 6 | 0 |
| Properties | 10 | 5 | 2 | 3 | 0 |
| Validations | 4 | 0 | 3 | 1 | 0 |
| Queries and compares | 5 | 1 | 1 | 3 | 0 |
| Imports and bulk change | 3 | 0 | 0 | 3 | 0 |
| Exports and distribution | 8 | 0 | 3 | 5 | 0 |
| Blending | 3 | 1 | 0 | 0 | 2 |
| Governance (DRG) | 16 | 7 | 3 | 4 | 2 |
| Security and access | 5 | 0 | 3 | 2 | 0 |
| Audit and history | 4 | 0 | 2 | 2 | 0 |
| Admin and integration | 4 | 0 | 1 | 3 | 0 |
| New capabilities | 10 | 3 | 2 | 1 | 4 |
| **Total** | **91** | **23** | **23** | **36** | **9** |

- **Out of scope (9):** retired (version load and unload, and the two blending capabilities), put out of the build by
  the owner (notifications, alerts), and deferred (the four AI capabilities, Phase 7).
- **Strongest areas:** the core editing path, governance workflow, properties, and the steward UI.
- **Weakest areas:** imports, exports, queries and compares, admin and integration. These are the areas downstream
  systems and power users depend on most.

## 4. Architecture and design compared

| Aspect | DRM 11.2 | Nexus | Assessment |
|---|---|---|---|
| History and versions | Each version is a separate copy of the hierarchies and values. An as-of version is rebuilt from transaction history. Versions are loaded into memory to be used | One bitemporal store: each fact carries the dates it is true and the time it was recorded. A version is a name for a business date, plus a frozen recorded time once submitted. Nothing is copied (ADR-006, ADR-037) | **Stronger** for audit and period close: any date and any "as known at" view, with no rebuild, and a finalized version cannot change. **Different** in one important way: working versions are not isolated (§6.3) |
| How data changes | Authorised users edit a working version directly. DRG requests are a second, governed route | Every change is an item in a change request. Facts are written only by the apply function, after a human decision or an approved commit policy (ADR-019) | **Stronger** control. More ceremony for routine edits, eased by the request tray and, once approved, by straight-through commit |
| Where the controls live | In the application engine and its configuration | In the database: triggers, constraints and least-privilege roles. The API's own login cannot write facts or record decisions (ADR-014) | **Stronger** assurance, including against defects in the API. The cost is a large stored-code layer tied to PostgreSQL (§6.4) |
| Governance workflow | DRG: workflow models, stages (Submit, Enrich, Approve, Commit), tasks, separation of duties, notifications, escalation | The same model in its own schema with a single bridge to the core (ADR-003). Camunda 8 sits behind a port, with an in-process driver (ADR-035). Auto-commit is an explicit, governed policy (ADR-005) | **Comparable** core. Missing notifications, push-back and SLA tracking. The Camunda path has never been run |
| Calculations and rules | Derived properties and validations written in DRM formulas or JavaScript dynamic scripts, run inside the engine | SQL rules and derivations today. CEL expressions evaluated in Java are designed (ADR-038): no side effects, deterministic, and limited to a node, its values and its parent chain | **Safer** and testable. Every DRM formula and validation must be rewritten, and some will not fit (§6.1) |
| Runtime and scale | A server engine on Windows that holds versions in memory, with a relational repository | A stateless Java 21 service on PostgreSQL 16 with lazy, keyset-paged reads, and an Angular UI | **Simpler** to run and scale out. Performance at the assumed volumes is unmeasured |
| Integration | File exports and books, a batch client, a SOAP web-service API, import files and action scripts | A REST API with a committed OpenAPI description and a generated UI client, plus a transactional outbox for change events (ADR-015, ADR-016). DRM-compatible imports and exports are designed | **Better** foundation. None of the DRM-compatible paths is usable yet |
| Security | Roles, node access groups, property-category access; internal users or an external directory | Roles scoped to a hierarchy or sub-tree and to property categories; grants keep their history; database roles per layer. Sign-in is designed as OIDC (ADR-033) and not built | **Comparable** model, better audited. Today there is only a development identity header |
| Audit | Transaction history and request history | An append-only audit log written by trigger, the bitemporal facts themselves, and the workflow action log | **Stronger**: tamper-resistant, and it answers "what did we know, and when". No query screen or export yet; retention undecided |
| What-if work | Copy a version, edit it, compare, blend it back | A sandbox: a private draft with an exact preview, conflict detection, rebase, and submit as one request (ADR-028) | **Safer** and cheaper. One owner, 20,000 changes at most, and no merging between long-lived versions |
| Beyond DRM | None | Ownership graph and UBO analysis (tables, a first calculation and a view; the exact solver is designed, ADR-030). AI assistance (designed, deferred) | New value. None of it is production-ready |
| Assurance | A vendor-tested product | 535 database tests, 133 API tests, 72 UI unit tests, 55 component stories and 44 end-to-end journeys with accessibility checks; traceability from capability to test | **Strong** for this stage. All of it has run on one laptop only (§6.4) |

## 5. Highlights

1. **History without copies.** Reads take a business date and, optionally, a recorded time. A finalized version is
   pinned to the moment it was submitted, so later corrections cannot change it. Period versions cost nothing to create.
2. **Controls that do not depend on the application behaving.** Maker-checker, separation of duties, human-only
   decisions, frozen content after submit, and append-only logs are database guards with stable error codes
   (ADR-020), and the database tests try to break them. A few guards are still untested (listed under known gaps in
   `BUILD_STATE.md`). The API runs as a login that cannot write facts.
3. **Straight-through commit made explicit.** In DRM some requests commit with no approver as a side effect of
   configuration. Nexus replaces that with versioned policies approved by a separate group, hard limits, daily caps,
   freeze windows, a kill switch, shadow mode and sampled review (ADR-005). It stays off until Audit-Risk signs off.
4. **One implementation of "what a change does".** Apply, validation and the sandbox preview all run the same
   handlers, so a preview cannot disagree with the result. A test compares a sandbox's preview with the tree after
   applying the same changes.
5. **Stale changes are caught.** Each item records what it assumed. If another request changed that fact first, the
   item fails at apply, or shows as a sandbox conflict naming the request that changed it.
6. **A modern, replaceable structure.** The workflow engine is behind a port, the UI client is generated from the API
   contract and checked for drift, lists are paged by key, and writes use ETags and idempotency keys.
7. **A steward UI built for large trees and for accessibility.** Lazy loading with virtual scrolling, the source of
   every property value (stored, inherited from which ancestor, derived, default), impact previews before destructive
   changes, a before/after view, and automated WCAG checks on every story and journey.
8. **Honest records.** Every phase gate lists what was not tested and why. Forty ADRs record the decisions, including
   the ones still waiting for Security or Audit-Risk.

## 6. Gaps

### 6.1 Needed before DRM can be switched off

| # | Gap | State today | Planned in |
|---|---|---|---|
| 1 | **Loading DRM data** | Staging tables exist. There is no loader, profiling or property mapping. DRM import files and action scripts are not supported (IMP-01, IMP-02) | Phase 4 |
| 2 | **DRM-compatible exports** | Hierarchy and generation export functions exist in SQL and have never been compared with a DRM file. No export service, schedule, books, delivery, compare or transaction-log exports, or version variables (EXP-03 to EXP-07, VER-05) | Phase 8 |
| 3 | **Proof of parity** | No golden test framework, no masked extract, no captured DRM outputs (OD-31, OD-32). Every built capability is "built, parity not proven" | Phase 4 |
| 4 | **Formulas and validations** | The CEL engine is not built. Nobody yet knows how many DRM formulas and validations exist or what they use. The designed formula environment sees a node, its values and its parent chain only, so formulas that look at children, descendants, siblings or other hierarchies need custom functions or another approach | Phase 5 (5-9, 5-10), translation after Phase 4 |
| 5 | **Sign-in and environments** | No authentication (SEC-05). The identity provider, hosting and storage are open (OD-06, OD-15a, OD-16a). The API refuses to start outside local and test profiles, so no shared environment, user testing or parallel run is possible | Phase 9 |
| 6 | **Performance** | Not measured in any phase. The tests are written and deferred | End of build |
| 7 | **Control sign-off** | Audit-Risk review is pending for the database roles and control fixes (ADR-014, ADR-021, ADR-023), straight-through commit (ADR-005), version finalization (ADR-037 D4) and load-run approval (ADR-026) | Before `main` |
| 8 | **Independent verification** | CI has never run on GitHub. The Camunda engine contract test has never run. The UI has been tested on Chromium only | Open |

### 6.2 Steward-facing features still missing

Designed for Phase 5 unless noted. Items marked "if used" wait for evidence that the organisation uses them (ADR-039 D5).

| Area | Missing today |
|---|---|
| Nodes | Inactivate and reactivate (HIE-06) · orphan list (HIE-04) · promote a leaf to a limb (HIE-05) · reorder siblings (HIE-08) · node types (HIE-09) · model after (HIE-11) · merge on delete and domains, if used (HIE-07, HIE-10) |
| Properties | Lookup properties (PRP-04) · inheritance locks, if used (PRP-05) · formula-derived values (PRP-06) · system properties such as level and child count (PRP-07) · version-level and hierarchy-level properties, if used (VER-07, PRP-10) |
| Validations | Checks as each change is made (VAL-01) · batch runs over a hierarchy or version (VAL-02) · formula rules (VAL-04) |
| Finding and comparing | Property queries, saved and shared (QRY-01) · compares, including baseline versions (QRY-02, VER-04) · search across hierarchies (QRY-03) · editing from results (QRY-05) · bulk property updates (IMP-03) |
| Governance | Push-back and re-approval (GOV-09) · request discussion (GOV-11) · tags (GOV-14) · analytics (GOV-15) · SLA tracking (GOV-07) · notifications and alerts are out of the build (GOV-08, GOV-16) |
| Security | Governed role grants (SEC-01) · sub-tree filtering of what people can read (SEC-02) · read rights by property category (SEC-03) · sharing of saved queries and exports (SEC-04) |
| Audit | A transaction-history query (AUD-01) · full request history (AUD-02) · retention rules (AUD-04, with Audit-Risk) |

### 6.3 Deliberate differences DRM users will notice

1. **Working versions are not isolated.** In DRM, two working versions are separate copies. In Nexus, a committed
   change that takes effect on 1 December shows in every version dated on or after 1 December, whichever version the
   request named (ADR-037). Isolated what-if work is done in a sandbox. A sandbox has one owner and at most 20,000
   changes, so a team restructuring a hierarchy together over several weeks has no equivalent today.
2. **No direct editing.** Every change is a request, even a typo fix. Straight-through commit is the intended relief
   for low-risk changes, and it cannot be switched on until Audit-Risk approves it.
3. **No blending** (ADR-004). Sandboxes cover scenarios; merging one long-lived version into another is not offered.
4. **No notifications or alerts.** People have to look at the worklist. DRG users are used to being told, and SLAs and
   escalation have little effect when nobody is told a deadline is near.
5. **Formulas do not carry over.** Each is rewritten, and its original text is kept beside it for traceability.
6. **Versions are never loaded, unloaded or restored by users.** Database backup and point-in-time recovery replace
   that, which needs a tested restore (Phase 9).
7. **In a sandbox,** the tree marks a node as "changed" without saying whether it was added, moved or renamed, and
   search and the node's path still show the live data.

### 6.4 Design and delivery risks

1. **Parity depends on evidence the team does not control.** Golden tests, formula translation, the "if used"
   decisions and the version-isolation question all wait for a masked extract and captured DRM outputs.
2. **Performance is unmeasured, and the build is proceeding on the unmeasured path.** The architecture overview's own
   risk list says to benchmark tree reads at full size before Phase 5 commits to the approach; Phase 5 is under way and
   the benchmark is deferred. Known hot spots:
   - tree walks, scope checks and inheritance use recursive queries;
   - reads at a past recorded time (every sandbox read) cannot use the "current rows" indexes;
   - below 1,000 changes, a sandbox re-runs all of its changes each time one is added;
   - counting a sandbox's conflicts runs a full trial apply, and the sandbox list and detail pages do it on every read;
   - one recorded finding: bulk inserts into a large hierarchy with stale statistics ran about 25 times slower.
3. **Much of the logic is PostgreSQL stored code.** There are about 142 functions and more than 44 triggers in roughly
   6,200 lines of SQL, against 7,200 lines of Java. That is what makes the controls strong. It is also harder to debug
   and refactor, and it ties Nexus to PostgreSQL. ADR-040 (run on Oracle too, with the logic in Java) was proposed and
   deferred. It would cost about as much as Phases 1 and 2 again, and once a shared environment exists the migrations
   can no longer be rewritten.
4. **Everything has been verified on one machine.** No CI run, no Camunda run (the laptop's Docker memory is too
   small), one browser. Local and demo runs use the database owner account, so privilege defects show only in tests.
5. **Decisions with outside lead time are open:** identity provider, hosting, storage, access to DRM's export files,
   and the Audit-Risk and Security confirmations listed in `OPEN_DECISIONS.md` (OD-08, OD-17a, OD-18a, OD-29a,
   OD-31a, OD-32a, OD-45a).
6. **Derived decimal values are computed as floating-point numbers** in the formula design (Phase 5 LLD risk R-4),
   which matters if formulas produce amounts or percentages that are compared exactly.
7. **The records are drifting.** The README's status section still describes Phase 3 as awaiting approval and has a
   leftover merge marker at the top. The catalogue's master copy lives outside the repository and could overwrite
   recorded decisions (OD-28). ADR-005 to ADR-008 are still "Proposed" with placeholder dates although the build
   depends on them. `BUILD_STATE.md` mixes current state with a long history.

## 7. Recommendations

In priority order. "Owner" is who would need to act.

| # | Recommendation | Why | Owner |
|---|---|---|---|
| 1 | **Start the DRM evidence track now.** Obtain a masked extract and captured DRM outputs (OD-31, OD-32), and inventories of exports and consumers, formulas, validations, and how versions are used. Bring the Phase 4 loader and profiling forward as soon as an extract exists | It unblocks parity proof, sizes the formula work, settles the "if used" capabilities and the version question, and it has lead time outside the team. The Phase 5 items that need it are listed in Phase 5 LLD §17.1 | Product, Platform, Security |
| 2 | **Run the performance tests that already exist** (`PerfTest`, the synthetic generator, the `@perf` journeys) at the assumed volumes, or at a stated fraction if the laptop cannot hold them, before building queries, compares and exports | Those features all sit on the same read path. A finding now is a design change; a finding after Phase 8 is a rewrite | Repository owner |
| 3 | **Decide database independence before the first shared environment:** accept ADR-040 or reject it on the record. Until then, adopt a short placement rule: the database holds controls, fact writes and anything that must share the apply path; Java holds read composition, reporting, orchestration and formulas | The cost of changing course rises sharply at the first shared deployment. The rule stops the stored-code layer growing through increments 5-9 to 5-16 either way | Repository owner, Architecture |
| 4 | **Start sign-in, hosting and the control reviews now, not in Phase 9.** Ask Security for the identity provider (OD-06) and Platform for hosting, storage and DRM file access (OD-15a, OD-16a, OD-39). Give Audit-Risk one review pack: ADR-005, ADR-014, ADR-021, ADR-023, ADR-026, ADR-037 D4 | No shared environment, user testing or parallel run can start without them, and none of them is build work | Security, Platform, Audit-Risk |
| 5 | **Get CI running.** Open a pull request so GitHub Actions runs for the first time; run the Camunda contract test there or on a machine with enough memory; add a second browser | Every test result so far comes from one laptop | Repository owner |
| 6 | **Check the version model with DRM users,** and check the extract for working versions that are edited in parallel and differ. If teams restructure together over weeks, extend sandboxes (shared editing, higher limits) before cutover | It is the largest behavioural difference from DRM, and it is cheaper to find out now than in user testing | Product |
| 7 | **Revisit notifications before cutover:** at least "you have work waiting" and "your request was decided", sent from the existing event outbox | The decision to leave them out of the build stands, but DRG users rely on them and SLAs do little without them | Product |
| 8 | **Order the remaining parity work by what exports depend on:** inactive nodes (HIE-06), system properties (PRP-07), node types (HIE-09), derived properties (PRP-06), sort order (HIE-08). Keep the "if used" capabilities unbuilt until the evidence arrives | Downstream feeds are the first thing a parallel run compares | Repository owner |
| 9 | **Plan formula translation from an inventory.** Group DRM formulas by what they read. For those that look down or across the tree, choose per group: a custom function (with an ADR), a stored value kept correct by a rule, or retirement. Settle the decimal type (risk R-4) first | The formula environment is deliberately narrow, so the hard cases should be found before the engine is built around the easy ones | Architecture, Product |
| 10 | **Sandbox follow-ups:** report the kind of change so the UI can show added, moved, removed and modified; make search and the path follow the sandbox; stop running a trial apply for the conflict count on every list and detail read (compute on demand, or cache per row version) | Small changes that remove a known performance cost and a known usability gap | Repository owner |
| 11 | **Tidy the records:** refresh the README status and remove the merge marker; make the repository's catalogue the master (OD-28); set the status and date of ADR-005 to ADR-008; separate current state from history in `BUILD_STATE.md` | New readers, including reviewers from Audit-Risk, start from these files | Repository owner |

## 8. What this review did not cover

- A line-by-line code review. The architecture findings come from the designs, the migrations and the code read during
  the Phase 5 build.
- Cost, staffing and timeline, and the comparison with Oracle's cloud product (decided in ADR-001).
- Anything about how the organisation actually uses DRM today.

## 9. Sources

Repository records: `docs/capabilities.md`, `docs/adr/` (ADR-001 to ADR-040), `docs/architecture/overview.md`,
`docs/design/` (phase designs, `TRACEABILITY.md`, `OPEN_DECISIONS.md`), `docs/phases/` (gate test reports) and
`docs/BUILD_STATE.md`.

Oracle, read 2026-11-14:
- [Oracle Data Relationship Management downloads](https://www.oracle.com/technetwork/middleware/epm/downloads/drm-1112x-2409244.html) (current 11.2 build)
- [DRM 11.2 documentation](https://docs.oracle.com/en/applications/enterprise-performance-management/11.2/drmex) (Premier Support statement)
- [EPM 11.2 documentation index](https://docs.oracle.com/en/applications/enterprise-performance-management/11.2/rmepm/index.html) (Premier Support statement)
- [Oracle Hyperion EPM support announcement](https://oracle.com/a/ocom/docs/support/hyperion-epm-announcement.pdf)
- [Migrating enterprise data from DRM to Cloud EDM](https://docs.oracle.com/en/cloud/saas/enterprise-data-management-cloud/dmcaa/s6_migrating_enterprise_data.html)

## 10. Appendix: status of each capability

The reading behind §3. "Partly" notes say what exists and what does not.

| Status | Capabilities |
|---|---|
| **Built (23)** | VER-01, VER-02 · HIE-01, HIE-02, HIE-03, HIE-12 · PRP-01, PRP-02, PRP-03, PRP-08, PRP-09 · QRY-04 · BLD-03 (met by sandboxes) · GOV-01, GOV-02, GOV-03, GOV-05, GOV-06, GOV-12 (shadow mode only until Audit-Risk approves), GOV-13 · NEW-01, NEW-08, NEW-10 |
| **Partly (23)** | VER-03 (reads at any date; no as-of exports) · HIE-05 (leaf rule; no promotion) · HIE-08 (order stored and used; no reorder action) · PRP-05 (inheritance; no locks) · PRP-06 (SQL derivations; no formula engine) · VAL-01 (rules run at validate and submit, not on each change) · VAL-03 (node and hierarchy levels) · VAL-04 (SQL rules only) · QRY-03 (search in one hierarchy) · EXP-01, EXP-02, EXP-08 (SQL export functions and profile options; no export service, no parity proof) · GOV-04 (conditions; splitting unconfirmed) · GOV-07 (claims; no SLA tracking) · GOV-11 (decision comments only) · SEC-01 (roles and grants; grants not yet governed) · SEC-02 (scopes on writes; reads filtered by hierarchy only) · SEC-03 (edit rights; no read rights) · AUD-01 (log written; no query) · AUD-02 (history recorded and shown as a timeline; no full read API) · ADM-02 (REST API for what is built) · NEW-02 (tables, a first calculation and a view) · NEW-07 (events written; no consumer feed) |
| **Not yet (36)** | VER-04, VER-05, VER-07 · HIE-04, HIE-06, HIE-07, HIE-09, HIE-10, HIE-11 · PRP-04, PRP-07, PRP-10 · VAL-02 · QRY-01, QRY-02, QRY-05 · IMP-01, IMP-02, IMP-03 · EXP-03, EXP-04, EXP-05, EXP-06, EXP-07 · GOV-09, GOV-10, GOV-14, GOV-15 · SEC-04, SEC-05 · AUD-03, AUD-04 · ADM-01, ADM-03, ADM-04 · NEW-09 |
| **Out of scope (9)** | Retired: VER-06, BLD-01, BLD-02 · Out of the build: GOV-08, GOV-16 · Deferred with Phase 7: NEW-03, NEW-04, NEW-05, NEW-06 |
