# Build state

- **Current phase:** 5 — Remaining parity, built before Phase 4 (repository owner, 2026-11-14; ADR-038 D3 amended)
- **Step in loop:** Build (BUILD_PROTOCOL step 3). On 2026-11-14 the owner said "all approved", which approved the Phase 5 plan, `dev.cel`, ADR-039 (every recommendation) and the demo rebuild. Building 5-1a on branch `feature/NEW-08-phase-5-remaining-parity`
- **Baseline:** db-test **pass** 411/411 · mvnw verify **pass** 126/126 · UI: lint pass, contract pass, unit 64/64, stories 49/49 (axe), production build and budgets pass, end to end 38/38 (axe) (2026-11-14, Phase 5 orient)
- **Last commit:** see `git log -1`

## Completed phases
| Phase | Gate result | Summary | Date |
|---|---|---|---|
| 0 — Foundation | Pass locally; approved by the repository owner. Gap: CI not yet run on GitHub (OD-11) | `docs/phases/phase-0/SUMMARY.md` | 2026-11-11 |
| 1 — Core write path | Pass with gaps; **approved by the repository owner** (performance not measured; test gaps listed in the report; CI not run, OD-11) | `docs/phases/phase-1/SUMMARY.md`, `TEST_REPORT.md` | 2026-11-11 |
| 2 — Governance | Pass with gaps; **approved by the repository owner** 2026-11-12 (Camunda contract run and performance deferred; AI eligibility test with Phase 7; golden in Phase 4; CI not run) | `docs/phases/phase-2/SUMMARY.md`, `TEST_REPORT.md` | 2026-11-11 |
| 3 — Steward UI | Pass with gaps; **approved by the repository owner** 2026-11-14 ("approved for going ahead") (performance deferred; golden in Phase 4; visual sign-off waits for OD-02 to OD-04; manual screen-reader check; CI not run) | `docs/phases/phase-3/SUMMARY.md`, `TEST_REPORT.md` | 2026-11-12 |

## Current phase progress
### Phase 5 progress
| Step | Capability | Status | Notes |
|---|---|---|---|
| Orient | PROG | Done 2026-11-14 | Phase 5 LLD, ADR-028, ADR-029, ADR-038, OPEN_DECISIONS and the code it touches read. No Phase 4 work was started |
| Design for the ADR-038 decisions | PRP-06, QRY-01 to QRY-05, IMP-03, VER-04, BLD-03 | **Approved 2026-11-14** by the repository owner ("approved"), with C-1 to C-5 and the parameters | Phase 5 LLD §17. Increments 5-9 to 5-16. Error codes N2801 to N2808. Migration V13 plus edits to V1, V3, V6 and V11 (rule 6 still allows them, OD-44). Choices for the reviewer C-1 to C-5 (§17.15). §17.1 lists what waits for Phase 4 |
| Remaining capability decisions | VER-07, HIE-03 to HIE-11, PRP-02 to PRP-10, VAL-01 to VAL-04, SEC-03, SEC-04, AUD-01 to AUD-04, GOV-03 to GOV-09, GOV-11, GOV-14 to GOV-16 | **ADR-039 accepted 2026-11-14** (OD-47, every recommendation; "all approved") | Catalogue and TRACEABILITY updated. 21 rows are built in Phase 5 after 5-16, once LLD §18 has been written and reviewed (a design stop). 10 rows are recorded as already built. The gate lists these explicit gaps: the D5 "confirm" rows, GOV-08, GOV-16, AUD-04, GOV-11 attachments and AUD-03 (Phase 8) |
| Plan | PROG | **Approved 2026-11-14** ("all approved") | `docs/phases/phase-5/PLAN.md`:<br>• 5-1, 5-10, 5-12 and 5-13 split into a and b; no other deviation from the LLD.<br>• `dev.cel:cel` 0.15.0 (18 days old), with `protobuf-java` 4.36.2 and `guava` 33.7.2-jre pinned. These also upgrade the Camunda client's 4.31.1 and 33.3.1-jre; a protobuf smoke test runs with no Docker, and the Camunda run stays deferred.<br>• Finding: there is no application SQL grant path to remove (F-4). `nexus_api` has only SELECT on `user_role`, and only the database owner can grant |

### Phase 3 progress
| Increment | Capability | Status | Tests | Notes |
|---|---|---|---|---|
| Orient + plan | PROG | Done `549fd67`; plan approved by the repository owner 2026-11-12 ("complete all of this phase, go with your recommendation": dependencies, Node.js install, CI job approved) | baseline green | fixtures in `HierarchyApiTest` and `NodePropertiesApiTest` now set `valid_period` from `mdm.business_today()` (they failed between 00:00 UTC and midnight New York) |
| 3-1 Backend: V10, `/me` + preferences, `/home`, search + path, submit-form, request detail, client errors | NEW-10, HIE-12, GOV-03 (infra) | Done `507477b` | pgTAP 21 (13), JUnit `UiSupportApiTest` 11 | `WorklistQuery` extracted for Home; trigram index on description too (LLD names name only); OpenAPI regenerated |
| 3-2 Generated client + drift check | PROG | Done (UI commit) | `npm run api:check` | springdoc default JSON media type; `/me` `workingVersion`, stage `whyNot` added (LLD notes) |
| 3-3 Workspace, tokens, Stylelint, adapters, Storybook + axe, Playwright, budgets, CI `ui` job | PROG | Done (UI commit) | lint self-test; prod-build check; 29 stories with axe | Node.js 26 LTS via winget; Angular 22.2; compressed budgets in a script (Angular budgets are raw) |
| 3-4 Shell, context bar, historical mode, start page, dev picker, interceptors | NEW-10 | Done (UI commit) | unit `ContextStore`, `UiError`, `NodePanel`; e2e 01 | |
| 3-5a / 3-5b Tree store + rendering; keyboard, type-ahead, search reveal | HIE-12 | Done (UI commit) | unit store 6, tree 7; stories 8; e2e 02 | axe found the viewport not focusable: the viewport is now the tree |
| 3-6 Node panel + property grid | HIE-12 | Done (UI commit) | unit 3; stories 3; e2e 03 | |
| 3-7 Add-leaf dialog, tray, review and submit | SLICE-01 | Done (UI commit) | unit tray 3; e2e 04 | duplicate name shown at the item on review (server finds it at validation; LLD note) |
| 3-8 Worklist | GOV-13 | Done (UI commit) | stories 4; e2e 05 | model filter is a text field (no non-admin model list) |
| 3-9 Request page, timeline, decision panel | SLICE-01, GOV-12 | Done (UI commit) | unit 4; stories 9; e2e 04 | |
| 3-10 Home | NEW-10 | Done (UI commit) | e2e 01, 05 | |
| 3-11 SLICE-01 end-to-end suite, keyboard and axe runs | SLICE-01 | Done (UI commit) | e2e 01–05 (20) | found and fixed: `set_property` on a node added earlier in the same request (API, Phase 1 defect); Space in type-ahead; focus on query changes; defaults pre-filled as stored values; request page not refreshing after submit |
| 3-12 Records | PROG | Done (records commit) | — | test report, summary, data model V10, UI_STANDARD token status, patterns, changelog, setup |
| 3-13 to 3-17 Scope extension: impact endpoint, generic tray action, edit details and properties, place / move / remove / delete with impact preview, new hierarchy | HIE-01, HIE-02, PRP-01 | Done (UI commit) | JUnit impact 1; unit 7; e2e 06 (7) | owner moved these screens from Phase 5 to Phase 3; `MAINTAIN` model for other drafts |
| 3-18 to 3-22 Second scope extension: property edit rights by category (ADR-036), History tab, Ownership tab (view), before/after view, drag and drop | PRP-09, SEC-03 (edit), QRY-04, NEW-02 (view), HIE-02, NEW-10 | Done (third Phase 3 commit) | pgTAP 21 (+2); JUnit 3; unit 4; stories 5; e2e 07 (5) | owner: "implement everything else except AI suggestions and notifications"; `mdm.user_role.category_codes` in V10
| 3-23 V11: version lifecycle, guards, transition log, freeze lock, `VERSION_ADMIN` | VER-01, VER-02 | Done `abf0151`; design, R1 to R4 and the `UPDATE (version_id)` privilege approved by the repository owner 2026-11-12 ("Build it as designed") | pgTAP 22 (77) | nine codes `N1028`–`N1030`, `N2701`–`N2706`; V1 to V10 unchanged |
| 3-24 Versions API, `/me` working version, moving a draft, `NEXUS.VERSION_DATE` | VER-01, VER-02 | Done `34393e1` | JUnit `VersionApiTest` (10) | `edit{allowed, whyNot}` added; a copy takes its base's date; no slice changes needed for search, path, impact, ownership, home (LLD V.9) |
| 3-25 Versions page and dialogs, context-bar picker, version pictures, move on Review and submit | VER-01, VER-02 | Done `e24bf87` | unit +18; stories +14 (axe) | move and withdraw on Review and submit, not the tray; the hierarchies guard keeps the query string |
| 3-26 End-to-end journey `08-versions` | VER-01, VER-02 | Done `0f32aa4`; the development user picker offers both version administrators (`e8fe53a`) | e2e 08 (6) | two synthetic version administrators in the seed; requests raised as `e2e_architect`; three locator fixes, no assertion weakened |
| 3-27 Versions records | PROG | Done (records commit) | — | LLD V.9, data model V11, patterns, capabilities, traceability, CONSISTENCY_REVIEW, changelog, README, summary, test report |

### Phase 1 progress
| Increment | Capability | Status | Tests | Notes |
|---|---|---|---|---|
| 1-1 Error codes + Problem Details | PROG | Done `6cde7c0` | pgTAP 03 (10), JUnit 11 | 68 guards coded; registry extended |
| 1-2 Change-request controls | PROG, HIE-02 | Done `8a29869` | pgTAP 04 (19) | + delete-only-drafts guard (LLD updated); 01 fixture submits first |
| 1-3 Roles and privileges | PROG (D-04) | Done `76ecde7` | pgTAP 05 (17), JUnit 3 | audit trigger and bridge as definer; app runs as nexus_api login |
| 1-4 Entitlements, actor, settings, BusinessClock, `/me` | SEC-01, SEC-02 | Done `4b356d1` | pgTAP 06 (11), JUnit 23 | settings/clock moved here from 1-5 (plan updated) |
| 1-5 Keyset paging, `recordedAsOf`, UTC sessions | HIE-01, NEW-01 | Done `411f5f8` | JUnit 5 | offset paging removed (ADR-015) |
| 1-6 Resolved properties with provenance | PRP-01 | Done `f85b9f9` | pgTAP 07 (12), JUnit 2 | `node_properties_resolved` in V3 |
| 1-7 Change requests: create, edit, items, withdraw | HIE-02, PRP-01 | Done `8267f23` | pgTAP 08 (8), JUnit 16 | `allocate_node`, `withdraw_change_request` (N1025, N2104); ETag 428/412; Idempotency-Key; expected values across earlier items; ProblemShapeTest slice excludes IdempotencyFilter (setup only) |
| 1-8a Apply: framework, set-from-D, add/insert/move, stale base, events | HIE-02 | Done `d414008` | pgTAP 09 (26) | `apply_fact` generic routine; `change_event`, `change_item_clearance`; new code N2105; stale-base JSON in DETAIL (ADR-020; LLD noted) |
| 1-8b Apply: remove, delete, update node, add hierarchy | HIE-02, HIE-01 | Done `c18dba8` | pgTAP 10 (24), JUnit 1 | delete refused for top node / children / references / scheduled changes; cascade follows primary links (LLD noted); 09 fixture: unavailable action now `clear_property` (setup only) |
| 1-8c Apply: set and clear property, item limit by origin | PRP-01 | Done `e3ee4d6` | pgTAP 11 (18) | limits in `system_setting`; JSON null kept; 09 fixture: unavailable action now `inactivate_node` (setup only) |
| 1-9 Validation (trial apply + rules) and submit | HIE-02, PRP-01 | Done `40c837b` | pgTAP 12 (17), JUnit 4 | shared item path for apply and trial; `NEXUS.TRIAL_APPLY` system rule; N2106; 422 keeps findings |
| 1-10 Decision, apply service, sweeper, review queue | HIE-02, PRP-01 | Done `6314e63` | pgTAP 13 (14), JUnit 6 (SLICE-01 end to end) | `record_apply_failure` added (LLD noted); serialization-retry path not exercised by a test (hard to force; reviewed) |
| 1-11 Performance tests + synthetic generator | HIE-01, PRP-01 | **Deferred** (scaffold committed, not run) | none run | owner deferred performance testing to the end of the build (2026-11-11); `PerfTest` (tag `perf`, excluded from default build) and `SyntheticHierarchy` committed unverified; finding kept below |
| 1-12 Records | PROG | Done (this commit) | — | data model, registry, README, setup, CHANGELOG, patterns, test report, summary |
### Phase 2 progress
| Increment | Capability | Status | Tests | Notes |
|---|---|---|---|---|
| 2-1 Business-day functions, `wf` day boundaries, activation guard | PROG, GOV-12 | Done `aaebdd1` | pgTAP 14 (11) | `system_setting` moved V8 → V1; guard in `trg_policy_guard`, `N2225` |
| 2-2 Bitemporal membership, `wf.is_member`, governed changes, config audit | PROG | Done `0b971f1` | pgTAP 15 (21) | new V9; only definer functions write membership; D-15 fixed; codes N1026, N2230–N2233 |
| 2-3 Claims (D-12), close rules (D-13), `record_stage_decision` | PROG, GOV-02 | Done `1345834` | pgTAP 16 (24) | functions owned by `nexus_wf`, callable by the API; SoD and human-only proven |
| 2-4 Scope by ancestor walk at the effective date (D-10, D-11) | PROG | Done `96d6684` | pgTAP 17 (9) | old vs new equal on 28 cases; old rule kept only in the test |
| 2-5 Policy row lock for the daily cap (D-14) | GOV-12 | Done `7ebe806` | JUnit 1 (two connections) | activation guard already in 2-1 |
| 2-6 Bridge: D-06 attribution, clearance, governed flag, enrichment, `requires_workflow` | PROG, GOV-02 | Done `40e1c80` | pgTAP 18 (16) | draft-only guard split into an invoker check and an owner-run version bump (LLD noted); N2107 |
| 2-7 Stage progression, model activation by a second admin, model loader | GOV-01, GOV-02 | Done `e39d28f` | pgTAP 19 (19), JUnit 2 | fixtures in 16–18 and the concurrency test name an activator (setup only); N2234, N2235 |
| 2-8a Submit with a workflow model, urgent flag, governed withdraw | GOV-02 | Done `9944844` | JUnit 3 | 2-8 split into a/b/c (size); `start_instance` owner-run with requester and model checks (N2236); OpenAPI regenerated |
| 2-8b Stage decisions, claims, enrichment, instance view, refusals in words | GOV-02 | Done `c99dea1` + `138c50f` | JUnit 3 | `wf.why_cannot_act`; `WorkflowGateway`; N2201 is 422 per ADR-020 (LLD table corrected in a note); OpenAPI operation ids kept unique (test added) |
| 2-8c Model and commit-policy admin endpoints | GOV-01, GOV-12 | Done `5aecb5f` | JUnit 3 | V6 lifecycle functions owner-run as `nexus_wf`; `wf.propose_commit_policy` (N1027) |
| 2-9 Worklist: nine views, counts, search, model filter, keyset | GOV-13 | Done `3fba8dc` | JUnit 2 | perf test deferred with the other performance work |
| 2-10a Engine-neutral ports, outbox offsets, relay, in-process driver, contract suite | GOV-02, PROG | Done `08f8ce6` | JUnit 6 (contract 5, boundary 1), pgTAP +2 | bug fixed: `close_instance` recorded the commit after the status change (bridge saw no decider) |
| 2-10b Camunda adapter: SDK config, BPMN, job adapters, contract suite on Camunda | GOV-02 | **Written, not yet run** `26f76cb` | contract suite on Camunda written (tag `camunda`) | blocked: Docker has 3.7 GiB; Camunda test runtime needs Elasticsearch (2 GB heap) + Camunda; decision asked |
| 2-11 Reconciler, resume from database state, resilience cases | PROG | Done `2a814a8` | contract +1, in-process +1 | next-stage reports stages decided while no process listened; in-process redelivery fix |
| 2-12 Records and gap tests | PROG | Done (this commit) | pgTAP 20 (6) | data model, registry, patterns, changelog, README, setup, test report, summary |

## Decisions awaiting human review
| ADR | Title | Why it needs review |
|---|---|---|
| ADR-005 | Policy-governed straight-through commit | Needs Audit/Risk sign-off before any policy is activated |
| ADR-006 to ADR-008 | Bitemporal model, ownership graph, AI proposes/humans approve | Proposed; awaiting team confirmation |
| ADR-013 to ADR-034 | Design-track decisions | Accepted by the owner; confirmations pending for ADR-014, 021, 023, 026, 027 (Security / Audit-Risk), see `docs/design/OPEN_DECISIONS.md` |
| ADR-037 | Versions: create, copy and status lifecycle (VER-01, VER-02) | **Accepted 2026-11-12** (every recommendation, OD-45). Refinements R1 to R4 approved with the LLD section on 2026-11-12 and built (3-23 to 3-27); D4 needs Audit-Risk confirmation (OD-45a) before merging to `main` |
| ADR-038 | Imports, derived properties, queries and compares, scenarios and exports | **Accepted 2026-11-14** (every recommendation, OD-46); D3 amended so Phase 5 is built before Phase 4. Product confirms EXP-03 from the export inventory |
| ADR-039 | Decisions for the remaining undecided capabilities (Phases 1, 2 and 5) | **Accepted 2026-11-14** (OD-47, every recommendation). Product confirms the D5 rows; Audit-Risk keeps AUD-04 (OD-25) |


## Open questions for the human
1. *Resolved 2026-11-14:* the repository owner approved LLD §17 ("approved"), including C-1 to C-5 and the parameters. The owner then answered "all approved" to the five plan questions:
   - the plan and its splits;
   - `dev.cel:cel` 0.15.0 with the protobuf and guava pins;
   - ADR-039 with every recommendation;
   - stopping and rebuilding the demo database;
   - committing the records.
2. **Phase 4 performance baseline (4-9):** run it in Phase 4, or defer it with the rest of the performance work to the end of the build?
3. **Masked extracts and DRM outputs (OD-31, OD-32)** for Phase 4 golden parity: without them Phase 4 is synthetic-only.
4. OD-11: remote `origin` is `https://github.com/POCoder7/Nexus` (public, repository owner 2026-11-12). The three phase branches are pushed and merged into `develop` by the owner; `develop`, with the versions commits, was pushed on 2026-11-13 with the owner's approval (a fast-forward, no force); `main` waits for the owner's one-time `git push --force origin main` (it replaces GitHub's starter commit; agents may not force-push). Every commit id changed on 2026-11-12 when the history was rewritten to the noreply email; the ids quoted in these records are the new ones.
5. OD-18a: Audit-Risk review of ADR-021 and ADR-023 **skipped for now** by the repository owner (2026-11-11); merging to `main` needs the review or your explicit waiver.
6. *Resolved 2026-11-12:* the versions design, R1 to R4, the `UPDATE (version_id)` column privilege, the nine codes and `VERSION_ADMIN` were approved by the repository owner ("Build it as designed") and built in 3-23 to 3-27. Review the build with the gate (open question 1): LLD V.9 lists what differs from the design.
7. *Resolved 2026-11-14:* ADR-039 (OD-47) was accepted with every recommendation ("all approved"). Still open: Product to confirm use of VER-07, HIE-07, HIE-10, PRP-10, GOV-04 splitting and PRP-05 locks (from discovery, or from the Phase 4 extract profile), and the GOV-15 metric list.
8. **Nexus vs Oracle DRM comparison document** (asked on 2026-11-14, then interrupted): still wanted under `docs/`? When written, it must say that DRM 11.2.x is current and Premier Support runs to at least 2030 (an earlier answer here said otherwise).
9. *Resolved 2026-11-14:* the Phase 3 gate and ADR-038 (OD-46) were approved by the repository owner ("approved for going ahead"); D3 amended to build Phase 5 before Phase 4.

## Scope changes
- **Phase 5 before Phase 4** (repository owner, 2026-11-14: "wait lets complete phase-5"; ADR-038 D3 amended, BUILD_PROTOCOL order 0, 1, 2, 3, 5, 4, 6, 8, 9). Waiting for Phase 4: the access-group mapper (5-6), golden runs (synthetic self-tests until then, parity unproven) and the translation of real DRM formulas. Phase 4 takes the next free migration number.
- **Camunda contract run deferred to the end of the build** by the repository owner on 2026-11-11 (Docker has 3.7 GiB; the Camunda test runtime needs Elasticsearch + Camunda). Adapter, BPMN and tests are written (`-Dcamunda`).
- **Camunda must stay replaceable** (repository owner, 2026-11-11): ADR-035 proposed with the Phase 2 plan.
- **Phase order kept:** the owner considered building Phase 3 (UI) before Phase 2 and chose Phase 2 first (2026-11-11).
- **OpenAPI added** (springdoc 2.8.6, JSON only; endpoint on only in `local`/`test`), approved by the repository owner 2026-11-11; committed description `docs/api/openapi.json`, kept current by `OpenApiDocumentTest`.
- **Performance testing deferred to the end of the build** by the repository owner on 2026-11-11: Phase 1 increment 1-11 is not run; its tests and generator are kept (`./mvnw -B verify -Dperf`). Phase 1 gate reports the LLD §10 targets as "not measured".
- **Phase 3 scope extended** by the repository owner on 2026-11-12: all editing screens for actions the API already has (edit details and properties, place, move, remove, delete, new hierarchy) moved from Phase 5 into Phase 3.
- **Phase 3 scope extended again** by the repository owner on 2026-11-12: History tab (QRY-04), Ownership tab as a view (NEW-02; UBO stays Phase 6), before/after view, drag and drop, property edit rights by category (ADR-036). AI suggestions (Phase 7) and notifications (GOV-08/16) stay out.
- **Phase 3 scope extended a third time** by the repository owner on 2026-11-12: versions (VER-01 create and copy, VER-02 lifecycle; ADR-037, OD-45). VER-03 exports and VER-05 aliases go to Phase 8, VER-04 baseline compare stays in Phase 5, VER-06 is retired as a feature (point-in-time recovery), VER-07 waits for discovery.
- **Phase 7 (AI assistance) deferred** by the repository owner on 2026-11-11 (OD-38): design approved; the build goes from Phase 6 to Phase 8. The `BUILD_PROTOCOL.md` phase table is updated in design step 5 (wiring).

## Known gaps, stubs and technical debt
- Running the API locally uses the docker-compose owner account; only tests run as the least-privilege login (documented in DEVELOPER_SETUP).
- Perf finding (1-11, before deferral): one statement inserting many placements into a large hierarchy whose statistics are stale runs the cycle-check trigger with an "empty table" plan (measured 29 s per 5 000 rows from empty vs 1.2 s with current statistics; one guarded insert under a 50 000-child parent about 21 ms). Guards unchanged. Phase 4 bulk loading must refresh statistics between batches; the generator does.
- CI has never run on GitHub: it runs on pushes to `main` and on pull requests, and no pull request is open yet.
- Column defaults `daterange(current_date, NULL)` (V1, V2) use the UTC session date, not the business day. Production fact writes set the period through `mdm.apply_fact`, so only direct inserts (test fixtures, owner scripts) are affected; fixtures must set `valid_period` explicitly.
- Mockito dynamic-agent warning in tests (future JDKs will block it).
- `scripts/check-setup.*` still requires a local `mvn`.
- Schema control gaps and untested guards (D-04 to D-07, D-12 to D-15, D-22, D-29, D-33 in `docs/design/DESIGN_STATE.md`; OD-18).

## Next action
Phase 5 build under way; the plan was approved on 2026-11-14.
1. Branch `feature/NEW-08-phase-5-remaining-parity` from `develop`. The records commit (PROG) goes on that branch.
2. Build, in order:
   - 5-1a, 5-1b, 5-2, 5-3, 5-4, 5-5;
   - 5-9, 5-10a (the `dev.cel` dependency and the protobuf smoke test come first), 5-10b, 5-11, 5-12a, 5-12b, 5-13a, 5-13b, 5-14, 5-15, 5-16;
   - then write LLD §18 for the 21 ADR-039 rows, and **stop for review** (design stop);
   - then the §18 increments;
   - then the 5-8 gate.

   5-6 waits for the Phase 4 loader.
3. Ask before each commit. Never push. If ADR-039 is decided, write Phase 5 LLD §18 for its Phase 5 rows and stop for review before building them. Merging to `main` also needs OD-45a (Audit-Risk on ADR-037 D4) and OD-18a. On the gate approval: Phase 4 (data loading and parity harness) orient and plan. Deferred to the end: performance tests (Phases 1–3), Camunda contract run. The Phase 5 protobuf and guava upgrade is one more reason to do that run. The local demo is running with V11 (API on 8080 from a scratchpad copy of the jar, UI on 4200, database `nexus_demo`, synthetic; `e2e_vadmin` and `e2e_vadmin2` are its version administrators); stop it when the owner is done. Also requested and not yet written: an architecture code review, a summary design document and a new-machine setup guide. On 2026-11-13 `ui/package-lock.json` was re-resolved with `npm install --before=2026-11-09T10:42:56Z` (owner's approval): the owner's second laptop uses a curated npm registry that refuses versions under 72 hours old; every exact pin was already older, so only transitive versions moved (DEVELOPER_SETUP §2). An `overrides` entry holds `playwright` at 1.64.1 so the story and end-to-end tests share one browser build (`0c6b175`); after the re-pin lint, contract, unit 64/64, build, stories 49/49 and end to end 38/38 pass.
