# Phase 5 — Remaining parity: plan

- **Status:** **Approved 2026-11-14** by the repository owner ("all approved"). That answers questions 1 to 5 below: the plan, `dev.cel` with the two pins, ADR-039 with every recommendation, the demo rebuild, and the commit of these records. The build is under way.
- **Follows:** `docs/design/phase-5-remaining-parity/LLD.md` (approved 2026-11-11; §17 approved 2026-11-14), ADR-028
  (sandboxes), ADR-029 (role grants), ADR-038 (accepted, OD-46; D3 amended: Phase 5 before Phase 4), ADR-039 (accepted with this plan, OD-47), ADR-036 (edit rights by
  category), ADR-037 (versions), ADR-015 (paging, ETags), ADR-020 (error codes), ADR-022 (entitlements), `UI_STANDARD.md`.
- **Exit criterion (LLD):** every capability decided Parity, Improve or New has passing acceptance tests, or is listed as an
  explicit gap with its reason. Golden parity is reported as unproven until Phase 4 (ADR-038 D5).

## Orient (baseline, 2026-11-14)
| Check | Result |
|---|---|
| `git status` | `develop` at `8cd384b`, two commits ahead of `origin/develop` (not pushed). Working tree: only the §17 approval records (LLD status, TRACEABILITY, OPEN_DECISIONS) and this plan |
| `scripts/db-test.sh` | **pass**, 411/411 pgTAP in 22 files, V1–V11 |
| `mvnw -B verify` | **pass**, 126/126 JUnit with Testcontainers (the `perf` and `camunda` tags are excluded by default, as before) |
| UI (`npm run ci`) | **pass**: lint (self-test refuses 4 forbidden declarations), API contract check, unit 64/64 (15 files), production build and budgets (initial JS 129.9 kB compressed, budget 350), stories 49/49 with axe |
| UI end to end (`npm run e2e`) | **pass**, 38/38 with axe, 4.2 min, run against the jar the Java build just made |
| Shared environment (OD-44) | **None.** The GitHub remote holds code, not a database. The local demo database `nexus_demo` keeps data, but it is on this machine and has one user, so OD-44 does not count it. Every "edit Vn" in the LLD stays an edit (CR-07). After the V1 edit, `nexus_demo` fails Flyway's checksum check and must be rebuilt (question 4) |
| Consistency review | CR-04 (item limit by origin, sandbox 20 000) was built in Phase 1 (1-8c), so 5-1 only sets `origin = 'sandbox'`. CR-07 as above |
| Open decisions this phase waits on | ADR-039 (OD-47) was accepted with this plan (see "Decided by ADR-039"). **OD-31 / OD-32** (masked data) for golden parity, which waits for Phase 4 anyway. Nothing blocks the designed scope |
| Finding: the "Phase 1 SQL grant path" (LLD F-4, increment 5-4) | `nexus_api` has only `SELECT` on `mdm.user_role` (V7 line 35); no application role can write grants today. The only path is the database owner, which bootstraps the first administrators and runs the seeds and fixtures, and privileges cannot remove it. So 5-4 has no privilege to revoke. It grants `nexus_apply` the writes that apply needs, and adds a pgTAP test that `nexus_api` cannot write `mdm.user_role`. I will add this as a note to the LLD. It is a clarification, not a change of behaviour, so no ADR |

## Scope
**In (decided and designed):**
| ID | Decision | Design | Increments |
|---|---|---|---|
| NEW-08 Sandboxes | New | LLD §3–§13 | 5-1a, 5-1b, 5-2, 5-3 |
| SEC-01 full: governed role grants | Improve | LLD §3.2 | 5-4 |
| SEC-02 full: sub-tree read filtering | Improve | LLD §3.2, §7.4 | 5-5 |
| PRP-06 Derived properties | Parity (ADR-038) | §17.3 | 5-9, 5-10a, 5-10b, 5-11 |
| QRY-02 Compares, VER-04 Baselines | Parity | §17.4 | 5-12a, 5-12b |
| QRY-01 Property queries | Parity | §17.5 | 5-13a, 5-13b |
| QRY-03 Search | Parity | §17.6 | 5-14 |
| QRY-05 Edit from results, IMP-03 Bulk property updates | Parity | §17.7 | 5-15 |
| BLD-03 Scenarios | Improve, met by NEW-08 (OD-12) | §17.8 | 5-16 |
| QRY-04 Node history | Parity, built in Phase 3 | §17.9 | record only, in 5-8 |

**Waiting for Phase 4 (explicit gaps at the gate, LLD §17.1):**
- 5-6 `AccessGroupMapper`, and with it the SEC-02 case "mapped DRM access groups reproduce the access matrix".
- Every golden case. Each is written as a synthetic self-test now; parity stays unproven.
- Translating the DRM formulas in use (§17.3.6). The list of formulas is a Phase 4 output.

**Decided by ADR-039 (accepted 2026-11-14 with this plan, OD-47):**
- **Built in Phase 5, after 5-16 (21 capabilities):**
  - hierarchy: HIE-04, HIE-05 (promotion and demotion), HIE-06, HIE-08, HIE-09, HIE-11;
  - properties: PRP-04, PRP-07;
  - validation: VAL-01 (Improve), VAL-02, VAL-03, VAL-04 (the engine now; the rules in use are translated after Phase 4);
  - security: SEC-03 (read side), SEC-04;
  - audit: AUD-01, AUD-02;
  - governance: GOV-07 (without escalation messages), GOV-09, GOV-11 (comments), GOV-14, GOV-15.

  First I write LLD §18 for these, with their increments (numbered from 5-17) and tests. Then I **stop for your review** before building them, as DESIGN_PROTOCOL requires.
- **Decision recorded, already built:** HIE-03, PRP-02, PRP-03, PRP-05 (inheritance), PRP-08, PRP-09, GOV-03, GOV-04 (conditions), GOV-05, GOV-06. The gate report names their existing tests. Parity stays unproven until the golden run.
- **Explicit gaps at the gate:**
  - VER-07, HIE-07, HIE-10, PRP-10, GOV-04 splitting and PRP-05 locks wait for confirmation of use (D5);
  - GOV-08 and GOV-16 stay out (D3);
  - AUD-04 waits for Audit-Risk (OD-25);
  - GOV-11 attachments wait for Phase 6;
  - AUD-03 is built in Phase 8.

**Not in this phase:** IMP-01 and IMP-02 (Phase 4); EXP-01 to EXP-08 (Phase 8); VER-03 and VER-05 (Phase 8); VER-06 (retired
as a feature); AI assistance (Phase 7, deferred); notifications and alerts (GOV-08 and GOV-16, which you kept out on
2026-11-12; ADR-039 D3). Performance runs stay deferred to the end of the build, as you decided. The `perf` tests are written and tagged, not run.

## Way of working
- New local branch `feature/NEW-08-phase-5-remaining-parity` from `develop`. One local commit per increment, with its capability ID. I ask before each commit, as the permission rules require, and never push.
- Tests first. Before every commit, every suite is green: `db-test`, `mvnw verify`, `npm run ci`, and Playwright once the increment touches the UI.
- **Synthetic data only.** The end-to-end seed gains obviously fictional users, such as `e2e_sysadmin` and `e2e_sysadmin2`, the two system administrators that grants and formulas need. Generated hierarchies use `SYN-` codes, and test formulas are written for the test.
- **Migrations (rule 6 allows edits; OD-44: no shared environment):**
  - edit V1: request `kind` and the sandbox columns; the three new `change_action` values; the `apply_item` dispatch; `version.version_type`;
  - edit V3: `node_passes_filter`, and the export guards N2805 and N2806;
  - edit V6: the hard-limit CHECK;
  - edit V7: privileges for `user_role`, the delta tables and the V13 tables;
  - edit V11: `create_version` takes the type;
  - new `V12__sandboxes.sql`;
  - new `V13__derivations_queries_compares.sql`.

  I list every edited migration in the summary, and note that existing local databases must be rebuilt.
- After each increment, I add a *Built in …* note to the LLD wherever the build differs in detail, as in Phase 3.

## Work breakdown (LLD §16 and §17.14; differences in **bold**)
Order as the LLD sets it:
1. 5-1 to 5-5.
2. 5-9 to 5-16.
3. The ADR-039 increments, after LLD §18 has been reviewed.
4. 5-8, the gate.

5-5 comes before 5-12 to 5-14, so the new read endpoints are filtered from their first commit. 5-6 follows the Phase 4 loader.

| # | Increment | Size | Capabilities | Tests written first |
|---|---|---|---|---|
| **5-1a** | V1: `change_request.kind` (`request` / `sandbox`), `sandbox_base_recorded_at`, `sandbox_name`; a guard that `kind` changes only once, from sandbox to request, at submit; sandbox creation sets `origin = 'sandbox'`; codes N2301–N2303. V12: the three delta tables and index; privileges | M | NEW-08 | pgTAP `23_sandboxes`: default `kind`; the one-way change (N2303 when not a draft); origin and item limit 20 000 (N2302); no `wf` reference (grep); no fact row changes from any sandbox operation |
| **5-1b** | `mdm.refresh_sandbox_delta`: trial apply with a capture hook in the apply handlers, always rolled back (§7.1); incremental refresh above `SANDBOX_INCREMENTAL_THRESHOLD`; `sandbox_children`, `sandbox_node_properties`, `sandbox_conflicts` (§7.2, §7.3) | M | NEW-08 | pgTAP: the overlay equals the result of apply for every action kind; for an `expected` that no longer matches, a conflict is returned with the request that changed it; rebase moves the base; still no fact row changes |
| 5-2 | Sandbox API (§5): create, list, detail, items, overlay children and node, diff, conflicts, rebase, submit, discard; `If-Match`; paging envelope; metrics (§11) | M | NEW-08 | JUnit `SandboxApiTest`: the lifecycle P and N cases of §13; the overlay of a generated sandbox equals the tree after applying the same items; submit with conflicts (N2301); over the limit (N2302); owner versus viewer (F-1); OpenAPI regenerated |
| 5-3 | Sandbox UI (§12): switcher in the context bar, banner, change markers with tokens and icons, the tray as the sandbox item list, the diff view (the existing `nx-diff-view`), conflicts panel with Rebase and Remove item, Submit as request | M | NEW-08 | Vitest for the store and markers; stories with axe; Playwright `09-sandboxes`: create, three kinds of item, overlay, diff, submit and apply; discard |
| 5-4 | `grant_role` and `revoke_role`: handlers that write `mdm.user_role` bitemporally through apply; a decision by a second `SYSTEM_ADMIN`; both actions join the V6 hard-limit CHECK; `nexus_apply` privileges (see the orient finding); Administration → Access (request a grant, decide it in the worklist) | M | SEC-01 | pgTAP `24_role_grants`: self-grant refused (CHECK); self-decision refused; a commit policy that lists either action refused; `nexus_api` cannot write `user_role`; grant history reconstructable at a past date. JUnit: propose, decide, apply. Playwright: two administrators |
| 5-5 | Sub-tree read filtering (§3.2, §7.4) on every read endpoint that returns nodes: children, node detail (404 outside scope), in-tree search, path, impact, history, ownership, home, sandbox overlay. Ancestors are returned `pathOnly`, with no properties (F-6); the tree renders them without the property panel | M | SEC-02 | JUnit negative matrix: one P and one N per endpoint, plus B: a node at the top of the scope. Vitest: a `pathOnly` row shows no properties |
| 5-9 | Foundations: `set_property_derivation` in the enum and the hard-limit CHECK; `version_type` (V1 column, V11 `create_version`, N2701 on change); `resolve_properties_batch` (V13); `node_passes_filter` groups, the new operators and attributes, N2806; `run_export` / `export_drm` refuse CEL-derived properties (N2805); `system_setting` rows for the §17.15 parameters | M | PRP-06, QRY-01, VER-04 | pgTAP `25_query_foundations`: `resolve_properties_batch` equals `node_properties_resolved` row for row on a generated hierarchy; every operator × data type; nested groups; bare arrays keep their meaning; N2805; N2806; `version_type` immutable |
| **5-10a** | `dev.cel` dependency (below); `DerivationEngine` port; `CelDerivationEngine`: the environment of §17.3.2, type mapping, literal-key check, the limits through `CelOptions.maxExpressionCodePointSize` (4 000) and `comprehensionMaxIterations` (1 000), no clock and no I/O | M | PRP-06 | Unit tests, no database: string building, conditional, level and leaf, an inherited input, recursion through `parent`; a compile error and a computed key (N2801); a type mismatch (N2803); the iteration limit; the same input gives the same output |
| **5-10b** | `derivation_history` (V13) with its backfill and append-only trigger; `DerivationCatalog` (slice-aware, cache by expression hash); `DerivedPropertyResolver` in node detail and the property grid; `derived_error` provenance; `GET /property-definitions?origin=derived`; `POST …/derivation-check` | M | PRP-06 | JUnit with Testcontainers: values correct through the API; derived on derived in order; depth 50; a top node with no parent; a read error gives NULL with `derived_error` and the page still loads; the same slice read twice gives the same values. pgTAP: history append-only (N2011); for every derived property the latest history row equals the definition |
| 5-11 | `set_property_derivation`: item-factory checks (N2801–N2804, cycles with the catalog and within the request); the same checks again at submit; `apply_set_property_derivation` with the stale-base check (N3001) and a history row; decision by a second `SYSTEM_ADMIN`; Administration → Derived properties (list, editor, Check, Propose change) | M | PRP-06 | pgTAP: maker-checker; a policy listing the action refused; stale `expected` (N3001). JUnit: cycle within one request (N2802); a `sql` engine or stored values (N2804); a frozen version reads the formula of its time after a later change. Playwright `10-formulas`: propose and decide (two users) |
| **5-12a** | Compares, backend: `compare_run` and `compare_row` (V13); set-based structure, rename and property compares (§17.4.2); bounded executor; timeout; reuse of frozen runs; expiry cleanup; the `/compares` endpoints; baselines (`versionType` on create, `GET /versions?type=baseline`) | M | QRY-02, VER-04 | pgTAP: each kind on a synthetic pair of slices with known edits (add, remove, move, reorder, shared edge, rename, a property change including inherited values); identical slices give no rows; a sub-tree. JUnit: CEL values compared; two hierarchies; a frozen run is reused; rows filtered by the reader's scope; unknown version; expired run (N2808); a baseline against the working version |
| **5-12b** | Compare UI (§17.12): side pickers, kinds and options, run status, result tabs with counts using the diff component and change tokens; "Compare with baseline" on the Versions page | M | QRY-02, VER-04 | Vitest; stories with axe; Playwright `11-compare`: compare with a baseline |
| **5-13a** | Queries, backend: `QueryPlanner` (indexed, resolved, java), a runner with the scan budget and continuation, `saved_query` (V13), the `/queries` endpoints | M | QRY-01 | pgTAP for the SQL side. JUnit: every operator × data type; nested groups; attributes; a CEL condition; at the scan budget a partial page, and the union of the continued pages equals the full answer; N2604, N2605, N2807; a shared query run by another user shows only that user's scope; 200 saved queries per user |
| **5-13b** | Queries UI: the builder (AND/OR groups, a property picker by category, operators by data type), a results grid with the continue bar, save and share | M | QRY-01 | Vitest; stories with axe; Playwright `12-queries` |
| 5-14 | Search across hierarchies (§17.6): full-text GIN index (V13); rank, then keyset order; `GET /search`; the header search box and a results page grouped by hierarchy | M | QRY-03 | JUnit: name, description, identifier, several words; shared nodes across hierarchies; deterministic order and keyset; scope filtered. Playwright: search, then open the node. Performance test written and tagged, not run |
| 5-15 | Batch items for requests and sandboxes (§17.7): all or nothing; the limit checked before insert (N2103); errors per item. Multi-select and "Set property…" in query results and the children grid; editing a cell inline in the results | M | QRY-05, IMP-03 | JUnit: a 500-item batch; one bad item adds nothing; over the limit (N2103); applied atomically and validated at submit. Playwright: query, then bulk edit, then submit |
| 5-16 | Scenario acceptance test (§17.8) | S | BLD-03 | JUnit and Playwright: build a restructure in a sandbox, read its diff, submit and apply in one case, discard in the other; no fact changes before apply |
| 5-8 | Gate and records: test report with the gaps, summary, data model (V12, V13 and the edits), patterns (P-28 overlay by trial apply; stored compare runs; batch resolution of derived values), UI_STANDARD provenance marker `derived_error`, CHANGELOG, OpenAPI, capabilities, traceability, build state | S | PROG | review |

**Why the splits.** The LLD sizes 5-1, 5-10, 5-12 and 5-13 as L. Each is split into a and b, as Phase 3 split 3-5, so that every increment fits one sitting. The content and the tests do not change. Nothing else departs from the LLD, so no ADR is needed.

## Decisions I expect to need
- **No new ADR for the designed scope.**
- **CEL option names**, which the LLD left to the plan:
  - `CelOptions.maxExpressionCodePointSize` for `CEL_MAX_EXPR_CHARS`;
  - `CelOptions.comprehensionMaxIterations` for `CEL_MAX_ITERATIONS`.

  Both exist in `dev.cel:common` 0.15.0.
- **Exact decimal arithmetic (R-4)** comes back through the LLD only if a translated formula needs it, which cannot happen before Phase 4.
- **ADR-039** was accepted with this plan. LLD §18 is the next design stop.

## New dependencies (your approval needed, CLAUDE.md rule 8)
| Dependency | Why | Where |
|---|---|---|
| **`dev.cel:cel` 0.15.0** (Google CEL for Java, Apache 2.0, github.com/cel-expr/cel-java), from Maven Central. Published 2026-10-27, 18 days ago; the latest release, and past the four-day curated-registry rule | OD-19 and ADR-038 D4: CEL evaluated in Java. The bundle is needed rather than only `dev.cel:compiler` and `dev.cel:runtime`, because the strings extension (`CelStringExtensions`) that §17.3.2 names ships only in `dev.cel:cel` | `services/mdm-api` |
| Its transitive dependencies (from its POM):<br>• `guava` 33.7.2-jre<br>• `protobuf-java` 4.36.2<br>• `re2j` 1.8<br>• `antlr4-runtime` 4.13.2<br>• `threeten-extra` 1.11.0<br>• `jspecify` 1.0.1<br>• `auto-value-annotations` 1.11.1 (annotations only)<br>• `snakeyaml`, already on the classpath through Spring Boot, which manages its version | Needed by the CEL parser, checker and runtime | the same |

**Version overlap with Camunda.** I checked this on 2026-11-14 with `dependency:tree`. The Camunda client already brings `protobuf-java` 4.31.1 and `guava` 33.3.1-jre. It gets them through `spring-boot-starter-camunda-sdk`, then `zeebe-client-java` and its gRPC transport. CEL needs 4.36.2 and 33.7.2-jre. Only one version of each can be on the classpath, and it has to be the newer one:
- **protobuf:** classes generated for an older 4.x runtime run on a newer 4.x runtime, but not the reverse. CEL's generated classes would refuse to load on 4.31.1.
- **guava:** releases within 33 are backward compatible, apart from `@Beta` APIs.

I will pin both versions in `<dependencyManagement>`, with a comment explaining why. Maven's own rule picks a version by its depth in the tree, so the result could change silently when another dependency changes.

This upgrades two libraries the Camunda client uses. The full Camunda contract suite (`./mvnw -B verify -Dcamunda`) stays deferred to the end of the build, as you decided on 2026-11-11: Docker here has 3.7 GiB, and Camunda's test runtime needs Elasticsearch as well.

Instead, 5-10a adds a small test, `ProtobufCompatibilityTest`, that needs no Docker. On the pinned versions, it:
- builds one Camunda gateway message and one CEL message, which runs protobuf's check that generated code and runtime versions match;
- builds a Camunda client without connecting to it, which loads its gRPC and guava classes.

This is a smoke test, not the contract run.

If either check fails, I stop and explain. I will not downgrade CEL or work around the failure. The upgrade is also recorded as one more reason for the deferred Camunda run.

**snakeyaml:** Spring Boot keeps 2.3, although CEL asks for 2.7. CEL reads YAML only for environment and policy files, which Nexus does not use, and the 5-10a unit tests run against 2.3.

No new UI dependency: the query builder, compare and search screens use Angular and the CDK that are already installed. No CI change.

## Risks, assumptions and questions
| # | Item | Handling |
|---|---|---|
| R-1 | ADR-039 adds 21 capabilities to Phase 5, about as much again as the designed scope | §18 sizes and orders them, and you can cut or reorder them at the §18 review. Anything not built is an explicit gap with its reason |
| R-2 | A large sandbox applies in one long transaction | Measured by the deferred performance run (§10); splitting stays an option |
| R-3 to R-9 | As LLD §17.15: DRM formula functions unknown until Phase 4; `decimal` as double; SQL reading a CEL value gets NULL (guards N2805 and N2806); a query with no indexed condition scans (scan budget); `compare_row` volume (expiry); `sql` formulas changed without a history row (pgTAP equality test); transitive dependencies of `dev.cel` | As the LLD says. For R-9, the overlap with Camunda (protobuf, guava) is handled as described under "New dependencies": the versions are pinned, a compatibility test runs with no Docker, the full Camunda run stays deferred, and a failure stops the work |
| R-10 | Four new Playwright journeys add run time on a 3.7 GiB Docker allowance | As in Phase 3: only PostgreSQL runs in Docker; the API and the dev server run on the host |
| A-1 | LLD assumptions F-1 to F-6 and choices C-1 to C-5 hold | As approved |

**Questions for you.** Answered 2026-11-14: "all approved", so yes to each, including a fifth question asked in the chat, to commit these records (PROG).
1. Do you approve this plan, including the a/b splits of 5-1, 5-10, 5-12 and 5-13?
2. Do you approve `dev.cel:cel` 0.15.0 and its transitive dependencies from Maven Central? That includes pinning `protobuf-java` 4.36.2 and `guava` 33.7.2-jre, which also upgrades them for the Camunda client (they are 4.31.1 and 33.3.1-jre today).
3. **ADR-039 (OD-47).** I read your "approved" as approving LLD §17 and `dev.cel` in principle, not ADR-039, because the open decisions are yours to make. Do you want to decide it now: all recommendations, some of them, or later? Until then, its rows are gaps at the gate.
4. The local demo (API on 8080, UI on 4200, database `nexus_demo`) cannot run once V1 is edited, because Flyway refuses the changed checksum. May I stop it now and rebuild it from the new migrations and the seed when you next want a demo?
