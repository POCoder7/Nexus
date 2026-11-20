# Phase 4 — Data loading and parity harness: low-level design

- **Status:** Approved 2026-11-11 (consistency fixes CR-nn applied the same day, see `../CONSISTENCY_REVIEW.md`).
  **2026-11-14:** the repository owner moved this phase after Phase 5 (ADR-038 D3, amended). Two things follow for its plan:
  - Migrations: V11 is now versions (Phase 3), V12 sandboxes and V13 the Phase 5 §17 objects. `V11__load_runs.sql` below takes
    the next free number.
  - Formulas: this phase profiles which DRM formulas are in use and loads them. It must say how a formula not yet translated
    to CEL is held. Phase 5 LLD §17.3.6 suggests engine `cel` with the CEL literal `null` as its
    expression text (so the definition CHECK holds), and the original kept. The access-group mapper (Phase 5
    increment 5-6) is built straight after the loader.
- **Migration rule (CR-07):** where this design says "edit Vn", that is allowed only while no shared environment exists (CLAUDE.md rule 6, OD-18). If one exists when this phase is built, the same change goes into a new V-numbered migration (`ALTER` / `CREATE OR REPLACE`). What counts as shared: OD-44.
- **Phase goal (BUILD_PROTOCOL §2):** realistic volumes and objective parity checks.
- **Exit criteria:** staging loader; synthetic data generator at production-like scale; golden-test framework; performance baseline recorded.
- **Reads with:** ADR-002, ADR-009, ADR-019, ADR-021, ADR-022, P-20, P-22, P-23; `tests/golden/README.md`;
  `tools/drm-analysis/README.md`; V3 staging tables; Phase 1 LLD (apply), Phase 2 LLD (workflow). DDL below is a proposal.

---

## 1. Purpose and scope

**Goal.** Load a (masked) DRM extract into Nexus through the same governed path as every other change; generate synthetic
data at production scale; compare Nexus outputs with captured DRM outputs automatically; measure performance at scale and record a baseline.

| Item | Decision | Phase 4 delivers |
|---|---|---|
| PROG — migration loader | — | Staging intake (COPY), profiling, property mapping, conversion of staged versions into governed change requests, load-run approval and reconciliation report |
| PROG — synthetic generator | — | Deterministic, seeded generator at `PERF_SCALE_FACTOR` × the assumed volumes |
| PROG — golden framework | — | Case format, comparators (byte, row, tree, value), runner, capability tagging, report |
| PROG — performance baseline | — | Load-test harness without new dependencies; baseline report |
| NEW-09 | New (primary Phase 8) | The comparison engine that Phase 8's daily reconciliation reuses |
| PROG — Phase 1 amendment | — | `add_hierarchy` change action (§4.1), found missing while designing the loader |

**Outline only, pending decision (§15):** IMP-01 (flat-file imports for users), IMP-02 (action scripts), GOV-10 (bulk requests
from file), ADM-04 (downstream integrations inventory and cutover). The loader's converter is the shared core they would use.

**Dependencies.** Phase 1 (change requests, apply, roles), Phase 2 (workflow, for loads that must be governed by a model),
Phase 3 (not required). Masked extracts and DRM outputs captured inside the organisation's network (OD-31, OD-32).

## 2. Confidence and assumptions

**Confidence: Medium** for the loader and harness design; **Low** for anything that depends on the actual DRM extract
format, which nobody in this repository has seen (`tools/drm-analysis` produces counts only).

| # | Assumption | Effect if wrong |
|---|---|---|
| E-1 | Extracts can mark each property value as **defined at the node** vs inherited or derived | If only resolved values are available, every value would load as stored and inheritance parity would be lost; the loader would then compare resolved values with Nexus's inherited result and store only the differences (§7.3 option b) |
| E-2 | Each DRM node has a stable internal id in the extract (`raw` JSON), so renames across versions are detected | Without it, renames look like delete + add; history continuity is lost for renamed nodes |
| E-3 | DRM versions are period snapshots; loading them oldest first and diffing gives valid-time history | — |
| E-4 | Number of historical versions to migrate: decided by OD-30 (recommendation: current + the versions needed for the parallel run and golden comparisons) | Load time and storage scale linearly |
| E-5 | Volumes: `MAX_NODES_PER_HIERARCHY` 500 000; ~100 hierarchies; ~300 properties; ~10⁸ property values over history | Benchmarks re-run with confirmed NFRs (OD-10) |
| E-6 | Masking is deterministic and rank-preserving for names and codes (OD-31) | Export row order could differ between masked DRM output and Nexus output |

**Human decisions this phase waits on:** OD-29 (how load runs are approved), OD-30 (versions to migrate), OD-31 (masking
approach), OD-32 (where masked golden datasets are stored), OD-09 for IMP/GOV-10/ADM-04; ADR-009 is still Proposed and needs acceptance.

## 3. Component design

New Maven module code stays inside `services/mdm-api` (ADR-013) under `com.mdm.api.load`, `com.mdm.api.generator`,
`com.mdm.api.golden`, `com.mdm.api.perf`, each runnable as a Spring Boot command with its own profile.

```mermaid
flowchart LR
  subgraph org[Inside the organisation's network]
    DRM[(DRM)] --> EXT[Extract files]
    EXT --> MASK[Masking tool<br/>OD-31]
    DRMOUT[DRM outputs<br/>exports, inherited values, validations] --> MASK
  end
  MASK --> MEXT[Masked extract] --> INT[StageIntake<br/>COPY into mdm_stage]
  INT --> PROF[Profiler] --> MAP[PropertyMapper<br/>drm_property_map]
  MAP --> CONV[ChangeRequestConverter] --> RUN[LoadRun]
  RUN -->|change requests, system_feed requester| CR[(mdm.change_request / change_item)]
  RUN --> REC[LoadReconciler] --> RPT[Load report]
  CR -->|human approves the run, OD-29| AP[mdm.apply_change_request]
  MASK --> MOUT[Masked DRM outputs] --> GOLD[GoldenRunner]
  AP --> GOLD
  GEN[SyntheticGenerator] -->|perf and test databases only| DB[(PostgreSQL)]
  PERF[PerfHarness] --> API[mdm-api]
```

### 3.1 `load`
| Type | Responsibility | Key signatures | Must not |
|---|---|---|---|
| `StageIntake` | Load extract files into `mdm_stage.*` with `CopyManager` (PostgreSQL JDBC, no new dependency) in chunks of `STAGE_CHUNK_SIZE`; one `mdm_stage.intake_batch` row per file with SHA-256 | `IntakeResult load(Path file, StageTable table, String versionName)` | Touch `mdm` |
| `Profiler` | Counts, null rates, duplicate names per version, orphan relationships, unknown properties; writes `mdm_stage.profile_finding` | `Profile profile(String versionName)` | Change staged data |
| `PropertyMapper` | Maintains `mdm.drm_property_map` (exists): proposes rows (rules: same name → same code; DRM type → `property_data_type`), a human confirms (`status = 'confirmed'`); value transforms from a fixed library | `List<MapProposal> propose()`; `void confirm(String drmName, Actor a)` | Use an AI model (Phase 7 may *propose* rows; transforms stay code, CLAUDE.md rule 4) |
| `ValueTransforms` | Deterministic conversions named in `value_transform`: `text`, `Y/N->boolean`, `True/False->boolean`, `date:<pattern>`, `decimal:<locale>`, `list`, `node_ref:by_name` | `JsonNode apply(String transform, String raw)` | Guess formats |
| `DefinitionLoader` | Creates categories, property definitions and list values from confirmed mappings (configuration, not facts) under a load run | `void load(LoadRun run)` | Run without an approved load run |
| `ChangeRequestConverter` | Turns a staged version (or the diff between two staged versions) into change requests of ≤ `MAX_ITEMS_PER_CHANGE_REQUEST` items, ordered so parents precede children | `List<UUID> convert(LoadRun run, String versionName, String previousVersionName)` | Bypass change requests |
| `LoadRun` (entity) + `LoadRunService` | Lifecycle: prepared → reviewed → approved → applying → applied \| failed; manifest of request ids and item hashes; approval by a human ≠ preparer (OD-29) | `LoadRun prepare(...)`; `void approve(UUID runId, Actor a)`; `void applyAll(UUID runId)` | Apply anything before approval |
| `LoadReconciler` | After apply: counts per version and hierarchy (nodes, relationships, stored values) vs staging; tree equality per hierarchy; report | `ReconciliationReport reconcile(UUID runId)` | — |

### 3.2 `generator`
| Type | Responsibility |
|---|---|
| `SyntheticGenerator` | From a `GeneratorSpec` and a seed, writes hierarchies, nodes, relationships, properties, history, change requests and workflow instances. Writes with `COPY` as the owner role for speed (test data only); refuses to run unless `mdm.system_setting('environment_kind')` ∈ {`local`, `test`, `perf`} |
| `GeneratorSpec` (record) | `hierarchies`, `nodesPerHierarchy` (distribution), `maxDepth`, `fanOut` (Zipf exponent), `sharedPct`, `propertiesPerNode`, `localPct`, `inheritedPct`, `historyCorrectionsPerFact`, `openRequests`, `seed` |
| `NameFactory` | Synthetic names from fixed syllable lists and counters (e.g. "Varnel 0412 Holdings"), checked against a deny-list of real company suffix patterns combined with real-looking words; never real names (CLAUDE.md rule 5) |

### 3.3 `golden`
| Type | Responsibility |
|---|---|
| `GoldenCase` | One case: `tests/golden/cases/<id>/case.yaml` (capability IDs, input reference, comparator, expected reference) |
| `Comparator` (interface) | `ComparisonResult compare(Expected e, Actual a)`; implementations `ByteComparator` (exports, with SHA-256 and first differing line), `RowComparator` (keyed rows, per-column differences, tolerance none), `TreeComparator` (parent-child sets, sort order), `ValueComparator` (node × property resolved values) |
| `GoldenRunner` | Runs cases, writes `target/golden/report.json` and a Markdown summary per capability (pass rate rolls up to the tracker) |
| `NexusOutputs` | Produces the actual side: `mdm.export_drm` lines, `node_properties_resolved` for all nodes, validation results |

### 3.4 `perf`
`PerfHarness` drives the API with the JDK `HttpClient` on virtual threads (no new dependency): scenarios (browse, node
detail, worklist, submit, decide+apply) with a target rate, records latency histograms (HdrHistogram-style buckets in
code), writes `docs/phases/phase-4/PERF_BASELINE.md` data. SQL-level timings via `EXPLAIN (ANALYZE, BUFFERS)` for the
heaviest queries.

## 4. Data design

### 4.1 Phase 1 amendment: `add_hierarchy` (edit V1; amends the approved Phase 1 LLD)
Phase 1 has no way to create a hierarchy and its top node through a change request (found here; ADR-026).
- `mdm.change_action` gains `'add_hierarchy'`; payload `{code, name, purpose, group, allowSharedNodes, sortSeq, topNode: {nodeKind, name, description}}`; the top node identity is allocated at draft (A-5 of Phase 1).
- Apply handler: insert `mdm.hierarchy` (the row's creation is audited; `hierarchy` stays non-bitemporal, D-08) and the top node's `node_attr` [D, ∞).
- Entitlement: PROPOSE with a grant on all hierarchies (`hierarchy_id` NULL).
- `wf.commit_policy` hard limits gain `'add_hierarchy'` (structural; always human).

### 4.2 Staging additions — edit V3 (`mdm_stage`)
```sql
CREATE TABLE mdm_stage.intake_batch (
  batch_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), file_name text NOT NULL, file_sha256 char(64) NOT NULL,
  stage_table text NOT NULL, version_name text, row_count bigint NOT NULL, loaded_at timestamptz NOT NULL DEFAULT now(),
  loaded_by uuid NOT NULL REFERENCES mdm.app_user, UNIQUE (file_sha256, stage_table));
ALTER TABLE mdm_stage.drm_node             ADD batch_id uuid, ADD drm_internal_id text;   -- E-2
ALTER TABLE mdm_stage.drm_relationship     ADD batch_id uuid;
ALTER TABLE mdm_stage.drm_property_value   ADD batch_id uuid, ADD is_defined_here boolean;  -- E-1
CREATE TABLE mdm_stage.node_identity_map (                -- stable identity across versions
  drm_key text PRIMARY KEY,                                -- drm_internal_id, else 'name:' || node_name
  node_id uuid NOT NULL UNIQUE REFERENCES mdm.node);
CREATE TABLE mdm_stage.profile_finding (batch_id uuid, version_name text, kind text, detail jsonb, count bigint);
```
Staging is not governed data; it may be truncated after a successful reconciliation (`STAGE_RETENTION_DAYS` 30).
`mdm_stage` is written only by role `nexus_loader` (new, ADR-026); it reads `mdm` for identity lookups.

### 4.3 Load runs — new file `V11__load_runs.sql` (in `mdm`, because it governs `mdm` changes)
```sql
CREATE TABLE mdm.load_run (
  load_run_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind          text NOT NULL CHECK (kind IN ('definitions','baseline_version','version_delta')),
  version_name  text, previous_version_name text,
  status        text NOT NULL DEFAULT 'prepared' CHECK (status IN ('prepared','approved','applying','applied','failed','cancelled')),
  prepared_by   uuid NOT NULL REFERENCES mdm.app_user,       -- a human operator; requests use the system actor as requester
  approved_by   uuid REFERENCES mdm.app_user,
  approved_at   timestamptz,
  manifest_sha256 char(64),                                  -- hash over (request id, item count, items hash) in order
  report        jsonb,
  CHECK (approved_by IS NULL OR approved_by <> prepared_by)
);
CREATE TABLE mdm.load_run_request (load_run_id uuid REFERENCES mdm.load_run, change_request_id uuid UNIQUE REFERENCES mdm.change_request, seq int, items_sha256 char(64), PRIMARY KEY (load_run_id, seq));
-- guard: approved_by must be a human; status transitions as listed; manifest frozen after 'approved'; audited
```
Load-run requests have `requester_kind = 'system_feed'`, `origin = 'load'`, `risk_tier` from OD-29, `effective_from` = the version's business date.
**Hierarchies that require workflow** (Phase 2 `requires_workflow`) refuse core-mode decisions. Load runs therefore run
before an administrator sets the flag (the baseline and the pre-cutover deltas), and the run is refused with a clear
message if any target hierarchy has the flag; after cutover, loads into governed hierarchies go through a workflow model
`LOAD_RUN` whose Commit stage the run approver holds (CR-05).

### 4.4 Bitemporal behaviour
- **Baseline version** (oldest loaded): every fact gets `valid_period [business_as_of, ∞)` and recorded time = load time.
- **Each later version**: the converter diffs staged version N−1 and N by stable identity and emits items effective at N's
  business date: `add_node`, `move_node`, `remove_node`/`delete_node`, `set_property`, `clear_property`, renames as an
  attribute change (a set-from-D on `node_attr`, handled by an `update_node` item: `change_action` value exists in V1; its
  handler is added here, payload `{name?, description?}`).
- Recorded time is always the load time: Nexus records honestly that it learned the past at migration (NEW-01 queries for
  times before the load return nothing). `mdm.version` rows for migrated DRM versions keep their names, business dates and,
  for finalized ones, `recorded_as_of` = the end of their load run.

### 4.5 Volumes and indexes
| Object | Volume | Strategy |
|---|---|---|
| Staged property values | ~10⁷ per version | `COPY`; index `(version_name, node_name)` created after load |
| Change items per baseline | ~500 000 nodes + ~3 × 10⁶ values → ~700 requests of 5 000 items | Converter streams (P-20); apply runs requests sequentially per hierarchy, hierarchies in parallel (`LOAD_PARALLELISM` 4) |
| Guards during load | `trg_hierarchy_integrity` ancestor walk per relationship insert | Parents first (top-down order) keeps each walk short; measured in the baseline |

## 5. Interface design

Operators use commands (Spring Boot runner, profile `load`), and approvers use the API.

| Command / endpoint | Purpose | Auth |
|---|---|---|
| `load intake --table drm_node --file … --version FY26_Oct` | Stage a file | Operator login with `nexus_loader` |
| `load profile --version …` | Profile | Operator |
| `load map propose` / `POST /admin/load/property-map/{drmName}/confirm` | Property mapping | Operator / `SYSTEM_ADMIN` (confirm) |
| `load prepare --kind baseline_version --version …` | Create a load run and its change requests (status draft→submitted) | Operator (prepared_by) |
| `GET /admin/load-runs/{id}` | Manifest, counts, profile findings, dry-run reconciliation | `SYSTEM_ADMIN`, approvers |
| `POST /admin/load-runs/{id}/approve` `{manifestSha256}` | The human approves the run; the API decides every request in the manifest as that human (OD-29 option A) | Human with `APPROVER` on all affected hierarchies, ≠ preparer |
| `load apply --run …` | Apply all decided requests; resumable | Operator |
| `GET /admin/load-runs/{id}/reconciliation` | Post-apply report | as above |
| `golden run [--capability HIE-02]` | Run golden cases | CI / developer |
| `generate --spec perf-large.yaml --seed 42` | Synthetic data | Developer (refuses outside local/test/perf) |
| `perf run --scenario all --rate …` | Baseline | Developer |

Golden case file:
```yaml
id: HIE-01-hierarchy-list-LE
capabilities: [HIE-01]
input: { dataset: masked-2027-01, version: FY26_Oct }
actual: { kind: hierarchy_list }
expected: { file: expected/hierarchy_list.csv }
comparator: { kind: row, key: [hierarchy_code], columns: [top_node_name, hierarchy_group, node_count] }
```

## 6. Behaviour

### 6.1 Load-run lifecycle
```mermaid
stateDiagram-v2
  [*] --> prepared: load prepare (requests created and submitted; dry-run reconciliation)
  prepared --> approved: human ≠ preparer approves manifest hash
  prepared --> cancelled
  approved --> applying: load apply
  applying --> applied: all requests applied + reconciliation clean
  applying --> failed: a request apply_failed or reconciliation mismatch
  failed --> [*]
  applied --> [*]
```

### 6.2 Baseline load
```mermaid
sequenceDiagram
  autonumber
  actor O as Operator
  actor A as Approver
  participant L as load commands
  participant DB as PostgreSQL
  participant API as mdm-api
  O->>L: intake (files) → mdm_stage, batch hashes
  O->>L: profile → findings
  O->>L: map propose; A confirms mappings in the API
  O->>L: prepare definitions run → A approves → DefinitionLoader
  O->>L: prepare baseline_version run
  L->>DB: converter streams staged rows → change requests (system actor requester) → submitted
  L->>DB: dry-run: validate each request (trial apply), aggregate findings
  A->>API: GET run (manifest, counts, findings) → POST approve {manifestSha256}
  API->>DB: decide every request in the manifest as A (human_review), one transaction per request
  O->>L: apply → mdm.apply_change_request per request (ordered, resumable)
  L->>DB: reconcile → report
```

### 6.3 Failure and recovery
| Failure | Recovery |
|---|---|
| Intake: same file twice | Refused by `UNIQUE (file_sha256, stage_table)` |
| Profile finding (duplicate names, orphans) | Run cannot be prepared until findings are fixed at source or explicitly accepted by the approver (recorded in the run) |
| A request fails to apply | Run → `failed`; applied requests stay (each is atomic); operator fixes the cause, prepares a delta run for the remainder |
| Reconciliation mismatch | Run → `failed` with the report; no automatic correction |
| Golden mismatch | Test fails with the first differences; never auto-accepted |

## 7. Algorithms

### 7.1 Converter ordering
```text
for each hierarchy h in the staged version:
   emit add_hierarchy (baseline only)
   BFS from the top node over staged relationships (primary first, then shared)
   emit add_node / insert_node per edge in BFS order, sort_order from staging
   emit set_property per (node, property) where is_defined_here (E-1), value = transform(raw)
   flush a change request every MAX_ITEMS_PER_CHANGE_REQUEST items, never splitting a node's add from its properties
global properties are emitted once per node, in the first hierarchy that contains it
```
O(nodes + edges + values) time; memory O(BFS frontier) with streaming reads.

### 7.2 Version delta
```text
prev := identity-mapped facts of version N−1 ; next := of version N           (both from staging)
nodes:   in next not in prev → add_node (or insert_node if identity exists); in prev not in next → remove_node, or delete_node if gone from every hierarchy
edges:   primary parent changed → move_node; shared added/removed → insert_node / remove_node
attrs:   name/description/flags changed → update_node
values:  defined-here value added/changed → set_property; removed → clear_property
order:   adds (top-down), moves, attribute and value changes, removes (bottom-up), deletes
```
O(n log n) with sorted merges on the identity key.

### 7.3 Inherited values when E-1 fails (option b)
Load the top-down resolved values; for each node and inheritable property, store the value only if it differs from what
`node_properties_resolved` would return from its ancestors at that point in the load. Deterministic, O(nodes × properties).

### 7.4 Comparators
- **Byte:** compare SHA-256; on mismatch, stream both files and report the first 20 differing lines with line numbers.
- **Row:** sort both by key; merge; report missing, extra and per-column differences.
- **Tree:** compare sets of (parent key, child key, primary, sort order) per hierarchy.
- **Value:** for every (node key, property code, hierarchy), compare resolved JSON; numeric values compared as decimals (no tolerance).

## 8. Patterns applied
| Pattern | Why |
|---|---|
| P-09 Atomic apply | Migration uses the same change requests and apply function as users |
| P-20 Chunked streaming with backpressure | Intake, conversion and apply at 10⁷ rows |
| P-22 Golden-master testing | The framework itself |
| P-23 Strangler and parallel run | Staged versions → Nexus master per consumer later (Phase 8) |
| P-01 Bitemporal facts | History reconstructed from DRM snapshots with honest recorded time |
| P-03 Maker-checker | Load runs: preparer ≠ approver; mapping confirmations by a human |

## 9. Security and controls
| Control | Phase 4 enforcement | Test |
|---|---|---|
| Maker-checker | Load run approval by a human ≠ preparer; every request decided as that human (OD-29) | pgTAP: preparer cannot approve; JUnit: approval with a stale manifest hash refused |
| Bitemporal history | All facts through `apply_change_request` | Reconciliation + pgTAP: no fact row without `change_request_id` after a load |
| Human-only decisions | Requests decided by the human approver; system actor is only the requester | pgTAP |
| Commit-policy limits | Load requests never auto-commit (system-feed requests with structural actions are on the hard-limit list) | pgTAP |
| Deterministic calculations | Value transforms and the converter are code; no AI | Unit tests per transform |
| No real data | Repository holds only synthetic data and the masking *specification*; masked datasets stored per OD-32; generator refuses outside local/test/perf | Review; generator guard test |
| Layer separation | `nexus_loader` writes `mdm_stage` and calls `mdm` functions only | pgTAP SET ROLE |

## 10. Performance and scale (the baseline this phase records)
| Measure | Target or assumption | Method |
|---|---|---|
| Intake rate | ≥ 100 000 rows/s | `COPY` timing |
| Baseline load of one 500 000-node hierarchy | record (no target yet) | converter + apply wall time; per-request apply time |
| Children page, node detail, worklist, submit, apply | Phase 1–3 targets | `PerfHarness` at `CONCURRENT_STEWARDS` |
| Export of a 500 000-node hierarchy (`export_drm`) | record; decides whether Phase 8 needs a set-based rewrite | SQL timing |
| `items_in_scope`, `can_act` | record | SQL timing on generated workflow data |
Results in `docs/phases/phase-4/PERF_BASELINE.md` with hardware, data spec and seed.

## 11. Observability
Load runs log per request (id, items, duration, outcome); metrics `nexus.load.rows{stage}`, `nexus.load.apply.duration`,
`nexus.golden.cases{capability,result}`; a load run's report is stored in `mdm.load_run.report`.

## 12. UI design
Not applicable in Phase 4: load runs are approved through the API (`/admin/load-runs`); a UI screen can follow in Phase 5.

## 13. Test design
| Item | Criterion | Cases | Type |
|---|---|---|---|
| Loader | Same file → same structure; counts match | P: synthetic extract (generator output exported in DRM-like format) loads and reconciles exactly; N: duplicate file refused; N: orphan relationship reported; B: node with 50 000 children; P: version delta (rename, move, value change, removal) reproduces the second snapshot | JUnit (Testcontainers) |
| Loader | Inherited values preserved (E-1) | P: only defined-here values stored; resolved values equal the source's | JUnit |
| Load run | Maker-checker | N: preparer approves; N: approval with a changed manifest; P: approver ≠ preparer | pgTAP + JUnit |
| Transforms | Deterministic | P/N per transform, including locale decimals and invalid dates | Unit |
| Generator | Deterministic and safe | P: same seed → same hash of generated data; N: refuses in an environment marked `shared` | JUnit |
| Golden framework | Comparators find every difference | P/N for each comparator with synthetic expected files (self-tests committed in `tests/golden/self-test/`) | Unit |
| SLICE-01 AC 1 | Inherited and derived values match DRM | Golden cases on the masked dataset once available (OD-31, OD-32) | Golden |
| HIE-01, HIE-02, PRP-01, GOV-02, GOV-13 | "Same as DRM" criteria | Golden cases written against the masked dataset | Golden |
| Performance | Baseline recorded | `PerfHarness` runs; report present | Perf |

## 14. Rollout and compatibility
- Migration edits: V1 (`add_hierarchy`, `update_node` handler), V3 (staging), new V11 (load runs), role `nexus_loader` in V7. Allowed while no shared environment exists.
- Golden datasets are never in git unless OD-32 decides otherwise; CI fetches them from the agreed store, or skips those cases with an explicit "dataset unavailable" result (never a silent pass).
- Generator and perf profiles are excluded from the production artefact's default profile.

## 15. Risks, open questions and alternatives
| # | Item | Handling |
|---|---|---|
| R-1 | Extract format unknown (E-1, E-2) | `tools/drm-analysis/strip_structure` (planned) reveals the format without data; the converter's input adapters are the only part that changes |
| R-2 | Approving ~700 requests with one human action may not satisfy Audit (OD-29) | Options in ADR-026 |
| R-3 | Masked data in CI may still be sensitive (OD-32) | Default: not in git |
| R-4 | Per-row guards slow the baseline load | Measured; if needed, a governed bulk path is a separate ADR (guards stay on) |
| Alt-1 | Load facts directly with `COPY` into `mdm` | Rejected: bypasses change requests, audit and guards for the most important data set |
| Alt-2 | Use the DRM transaction log to rebuild history | Possible later for audit history; snapshots give valid-time history more simply |

**Outline only, pending decision:** IMP-01 (user imports reuse `StageIntake` + converter into a draft request), IMP-02
(DRM action-script parser → items), GOV-10 (file → items of a draft request under a model), ADM-04 (inventory of
downstream feeds from `mdm_stage.drm_export_definition.target_system`; cutover in Phase 8).

## 16. Work breakdown
| # | Increment | Size | Items | Tests |
|---|---|---|---|---|
| 4-1 | Phase 1 amendment: `add_hierarchy`, `update_node` handler (ADR-026) | S | PROG, HIE-01 | pgTAP + JUnit |
| 4-2 | Synthetic generator + `NameFactory` + environment guard | M | PROG | JUnit |
| 4-3 | Staging additions, `StageIntake`, `Profiler` | M | PROG | JUnit |
| 4-4 | `PropertyMapper`, `ValueTransforms`, `DefinitionLoader` | M | PROG | unit + JUnit |
| 4-5 | Load runs (V11), approval endpoint, guard | M | PROG | pgTAP + JUnit |
| 4-6 | `ChangeRequestConverter` baseline + apply orchestration + `LoadReconciler` | L | PROG | JUnit |
| 4-7 | Version delta converter | M | PROG | JUnit |
| 4-8 | Golden framework, comparators, self-tests, runner, report | M | PROG, NEW-09 | unit |
| 4-9 | `PerfHarness` + baseline run at `PERF_SCALE_FACTOR` | M | PROG | perf |
| 4-10 | Records: PERF_BASELINE, data model, changelog, test report, summary | S | PROG | review |

New dependencies: **none required** (PostgreSQL JDBC `CopyManager`, JDK `HttpClient`). Case files are YAML only if the plan
approves `jackson-dataformat-yaml` (version-managed by Spring Boot, not yet a project dependency); otherwise they are JSON.

---

## 17. Hackathon CSV format (ADR-046) — approved 2026-11-20 (C-1 to C-7, OD-51)

The hackathon team's data set is 12 CSV files with fixed formats. They are listed in §17.1, and the sample is in
`data/`, which is git-ignored and synthetic. This section adds an input adapter for that format and the model
changes the owner decided (ADR-046 D1 to D7). The loader's core is unchanged: staging, profiling, load runs approved
by a second person, change requests, and reconciliation. Everything not listed here follows §1 to §16.

### 17.1 Files and mapping
| File | Columns (fixed by the hackathon team) | Goes to |
|---|---|---|
| `hierarchies.csv` | hierarchy_code, hierarchy_name, top_node_code, description | `add_hierarchy` items; `hierarchy.description` (D8, C-5) |
| `nodes.csv` | node_code, node_name, description, node_type (LEAF/LIMB), status (active/inactive) | `add_node`: code → `node_name`, name → `display_name` (D1), LIMB → `allows_children`, inactive → `inactivate_node`; `node_kind` = `structural` |
| `relationships.csv` | hierarchy_code, parent_code, child_code, sort_order | Blank parent = the hierarchy's top node (must equal `top_node_code`); others → `insert_node` with `sort_order`, parents first (§7.1) |
| `attribute_definitions.csv` | attribute_code, label, category, data_type, scope, hierarchies, node_filter, required, reference_list, inherited, default_value, derivation, max_length, description | `property_category` (distinct categories); `property_definition`; `property_hierarchy` and `node_filter` (D2); types and scopes lower-cased; inherited Y → `inherit_from_ancestor`. A row with a `derivation` is skipped and reported (D6) |
| `reference_lists.csv` | list_code, value, label | `property_list_value` for every property naming the list (D3); not loaded for BOOLEAN properties |
| `attribute_values.csv` | node_code, hierarchy_code, attribute_code, value | `set_property`; blank hierarchy = global; BOOLEAN Y/N → true/false (`ValueTransforms`) |
| `ledgers.csv` | ledger_id, ledger_name, currency, finance_country | `mdm.ledger` (D4) |
| `validation_rules.csv` | rule_code, rule_name, description, level, mode, severity, applies_to, core_path | Rule catalogue (D5, §17.5) |
| `versions.csv` | version_code, version_name, status, description | `create_version` and then `transition_version` (D7, §17.6) |
| `users.csv` | user_id, display_name, role, groups, notes | `mdm.provision_user` (§17.7); a `svc_` prefix or the CONSUMER role → kind `service` |
| `groups.csv` | group_code, role, hierarchies | `create_group`, then `add_group_scope` per hierarchy (governed access changes, ADR-042) |
| `roles.csv` | role, permissions | Not loaded. Checked against `mdm.role`; an unknown role stops the load |

Each file is staged with `COPY` into `mdm_stage.hx_<file>` (all `text` columns, plus `batch_id`) by `nexus_loader`, and
`intake_batch` records it (§4.2). The profiler adds these findings:
- duplicate codes;
- references that don't resolve (node, hierarchy, attribute, list, ledger, group, role);
- values outside their list;
- a top node that differs from the relationship row with a blank parent;
- an unknown level, mode, type or scope.

Any finding of severity `error` blocks `load prepare`.

### 17.2 Display name (D1) — V16
```sql
ALTER TABLE mdm.node_attr ADD COLUMN display_name text;      -- NULL = show node_name; not unique; bitemporal with the row
CREATE INDEX node_attr_display_trgm ON mdm.node_attr USING gin (display_name gin_trgm_ops) WHERE upper_inf(recorded_period);
```
- **Change actions.** The `add_node` and `update_node` payloads gain `displayName` (optional). Apply copies it from D,
  like `description`.
- **Readers.** The node DTOs (`NodeRepository`, `HierarchyRepository` children, sandbox overlay, history, compare, query
  rows, search) gain `displayName`. Each reader is listed in the plan.
- **UI.** Shows "display name · code", falling back to the code alone.
- **Search.** Matches `display_name` too (the trigram index above).
- **Unchanged.** DRM export and golden comparisons keep `node_name`.

**Built in H-1 (2026-11-20).**
- **Migrations.** The columns, index and handler changes were made in place: V1 (`node_attr.display_name`,
  `hierarchy.description`, `apply_add_node`, `apply_update_node`, `apply_add_hierarchy`), V10 (trigram index), V12
  (sandbox delta column, capture, overlay reads) and V13 (the full-text index also covers `display_name`). This follows
  the project's "edit Vn" convention (CR-07; rule 6 allows it, because no shared environment exists, OD-44), instead of
  copying five sandbox functions and their grants into V16. V16 starts with H-2.
- **Sandbox reads.** `sandbox_children` and `sandbox_node` return `display_name` as their last column, so readers that
  use column positions keep working.
- **What reads the display name.** The display name is part of the stale-base check (`expected.displayName`). It is
  read back by:
  - node detail;
  - the children page;
  - the hierarchy summary (`topNodeDisplayName`, `description`);
  - in-tree search and paths;
  - search across hierarchies (`matched = displayName`);
  - the sandbox overlay and its diff.

  History, compare and query rows still show `node_name`; they follow in H-7.
- **Defect fixed.** A request whose only item is `add_hierarchy` was visible to its requester alone, so nobody could
  decide it. `ChangeRequestService.canSee` now applies the rule that Home, search and audit already use: an item with
  no hierarchy is visible to people who can read every hierarchy. Nothing else became visible to anyone.

### 17.3 Property applicability (D2) — V16
```sql
CREATE TABLE mdm.property_hierarchy (                        -- no rows for a property = it applies to every hierarchy
  property_id  uuid NOT NULL REFERENCES mdm.property_definition,
  hierarchy_id uuid NOT NULL REFERENCES mdm.hierarchy,
  PRIMARY KEY (property_id, hierarchy_id));
ALTER TABLE mdm.property_definition
  ADD COLUMN node_filter text NOT NULL DEFAULT 'any' CHECK (node_filter IN ('any', 'leaf', 'limb'));
```
**Guard (C-2).** The `property_value` trigger that already enforces scope, type and list (N2020 to N2023) gains
N2025 `property.not_applicable`. It refuses a value in three cases:
- the node's `allows_children` contradicts `node_filter`;
- a local value names a hierarchy that is not listed for the property;
- a global value is set on a node that, on the value's start date, is not placed in any listed hierarchy (only checked
  when hierarchies are listed).

Existing values are untouched, because the check runs on write only. A validation rule (§17.5) reports values that
later stop applying, for example after a move. The property grid and the definitions API return `appliesTo` and
`nodeFilter`, and the grid offers only applicable properties.

### 17.4 Ledgers (D4) — V16
```sql
CREATE TABLE mdm.ledger (
  ledger_id       text PRIMARY KEY CHECK (ledger_id ~ '^\S{1,20}$'),
  ledger_name     text NOT NULL,
  currency_code   char(3) NOT NULL CHECK (currency_code ~ '^[A-Z]{3}$'),
  finance_country text NOT NULL,
  is_active       boolean NOT NULL DEFAULT true);
```
`mdm.ledger` is configuration, like `property_definition`:
- **Who writes it:** the loader under an approved load run, and ADMIN through `PUT /admin/ledgers/{id}`.
- **Audit:** the existing audit trigger, the same way definitions are audited.
- **Reads:** `GET /ledgers`, for every role.
- **Integrity:** the profiler checks that the values of the property that uses the LEDGER list are ledger ids.

### 17.5 One rule catalogue (D5) — V16
```sql
ALTER TABLE mdm.validation_rule
  ADD COLUMN rule_name     text,
  ADD COLUMN external_code text UNIQUE,                       -- the customer's id, e.g. 'VR07'
  ADD COLUMN mode          text NOT NULL DEFAULT 'both' CHECK (mode IN ('real_time', 'import', 'both')),
  ADD COLUMN enforcement   text NOT NULL DEFAULT 'rule' CHECK (enforcement IN ('rule', 'guard')),
  ADD COLUMN guard_code    text,                              -- SQLSTATE (N2001) or constraint name, for guard rows
  ADD CHECK ((enforcement = 'guard') = (guard_code IS NOT NULL));
```
- **Guard rows (seeded in V16).** One row per data guard: N2001 cycle, N2002 top node, N2003 shared not allowed,
  N2004 parent is leaf, N2005 remove with children, N2006 node referenced, N2007 parent missing (new code, below),
  N2020 to N2025 property scope, derived, type, list, node reference and applicability, N3001 stale base, and the
  `node_attr` name-uniqueness exclusion constraint. Each row has `level` `node` or `hierarchy`, `mode` `real_time`,
  severity `error`, engine `sql`, and the never-matching expression that `NEXUS.TRIAL_APPLY` already uses.
- **Governance controls are not in the catalogue.** Maker-checker, human-only decisions and the rest of N1xxx are
  controls on decisions, not data rules. They stay documented in the specs.
- **`trg_validation_rule_guard` (new).**
  - A guard row cannot be deleted, deactivated, or have its `severity`, `level`, `engine`, `expression`, `mode` or
    `guard_code` changed. Only `rule_name`, `description` and `external_code` can be edited.
  - No one can insert a row with `enforcement = 'guard'` except the database owner (the migration).
  - This is a new guard; no existing one is weakened.
- **N2007.** `apply_require_parent` raises N2007 `hierarchy.parent_missing` instead of the shared N2105. The check is
  unchanged. The Java error mapping and the tests that expect N2105 for this case are updated.
- **`validate_change_request` changes.** Through CREATE OR REPLACE, keeping its owner and grants:
  - the rule loop skips `enforcement = 'guard'`;
  - it skips `mode = 'import'` unless the request's requester kind is `system_feed`, meaning a load (C-4);
  - a trial-apply failure is reported under the guard row whose `guard_code` equals the SQLSTATE, or the constraint
    name for 23P01 and 23505, and falls back to `NEXUS.TRIAL_APPLY`. Nothing else changes.
- **Loading `validation_rules.csv`.**
  - Level `FEED` is skipped and reported.
  - `core_path` = Y rows, and rows in the fixed mapping, label an existing guard row: they set its `external_code`,
    `rule_name` and `description`. The mapping (in code, reviewed) is VR02 → name uniqueness, VR05 → N2007,
    VR06 → N2004, VR07 → N2001, VR08 → N2023. A `core_path` = Y row with no mapping stops the load.
  - Other rows become `enforcement = 'rule'`:
    - `rule_code` and `external_code` are the CSV code;
    - level, mode and severity are lower-cased;
    - `applies_to` ALL → `hierarchy_id` NULL; otherwise the named hierarchy;
    - the expression comes from the rule library `services/mdm-api/src/main/resources/load/rules/<rule_code>.sql`;
    - with no library file, the rule loads inactive with the never-matching expression and is reported.
- **The rule library** follows the existing positional contract `(node_id, hierarchy_id, message)` with `$1` as the
  business date. The plan lists the hackathon rules it covers: VR01, VR03, VR04 and VR09 to VR17. VR16 and VR17 join
  `mdm.ledger` and the resolved property values. Rules stay SQL until OD-19 decides CEL.
- **API and screen.**
  - `GET /admin/validation-rules` lists every row with its enforcement, for ADMIN and APPROVER.
  - `PATCH /admin/validation-rules/{code}` lets ADMIN edit: `is_active`, `severity`, `mode`, `expression`,
    `hierarchy_id` and the labels on rule rows; labels only on guard rows (C-3).
  - The screen is "Admin › Validation rules", read-only for APPROVER, following UI_STANDARD.
  - Every edit is audited, and `rule_version` is bumped when the expression changes.

### 17.6 Versions (D7)
1. Every row in `versions.csv` is created with `create_version(name = version_name, business_as_of = business_today(),
   base = NULL, description)`. `version_code` is kept as the external key in the load report.
2. **Target version:** the one named by `load prepare --version`. Otherwise the CSV's single working version, if it
   names exactly one; otherwise the latest working version. With no working version, the load stops (N2809
   `load.no_working_version`). The target is shown on the run preview and in the report.
3. Data requests run with `effective_from` = the target's business date.
4. After the data requests apply, the run moves each non-working version through `transition_version`. The preparer
   submits; the run approver finalizes and then expires. The version guard already requires two different ADMINs, so
   nothing changes there. Finalized and expired versions created this way are pictures of the store at their pin.
5. **Unknown status:** a status other than working, finalized or expired is a profiling error.

### 17.7 Users, groups and roles
- `mdm.provision_user(p_login, p_display_name, p_kind, p_actor)` is new. It is ADMIN only, SECURITY DEFINER and
  audited, and it is the only way to create an `app_user` row outside migrations.
- Groups, scopes, memberships and direct roles go through the governed access changes (ADR-042 D3) in one access
  request per run. The approver must differ from the preparer, and nobody grants themselves anything (existing guards).
- A user whose `groups` is `ALL` gets a direct grant of their role on every hierarchy.

### 17.8 Load run for this format
The load-run table and lifecycle are §4.3 and §6.1, in migration V16 instead of V11. `kind` gains `'csv_dataset'`. One
`load prepare --format hackathon --dir data/` produces, in order:
1. definitions: categories, properties and lists, ledgers, rules;
2. versions;
3. one hierarchy request per hierarchy (`add_hierarchy`, then nodes and relationships parents first, then values);
4. the access request.

The approver approves the manifest once (OD-29 option A). `load apply` applies them in that order, then runs the
version transitions. The report lists:
- counts per file and per hierarchy;
- skipped rows: FEED rules, derived attributes, inactive rules with no expression;
- profiling findings;
- the target version.

### 17.8.1 Scripts (owner, 2026-11-20: "Screen and scripts")
`scripts/load-data.sh` and `scripts/load-data.ps1` match the existing `db-test` and demo scripts, and call the same
engine as the screen (§17.8.2). Usage: `load-data [--dir data/] [--version <name>] [--approve-as <login>] [--reset]`.

1. Check that the database and the API are up.
2. Run `load intake` and `load prepare` on the folder.
3. Print the preview: the target version, counts per file, skipped rows, and errors. Stop on errors.
4. Wait for the approval on the screen, or, with `--approve-as`, approve as that second ADMIN (C-7).
5. Run `load apply` and print the reconciliation report.

`--reset` first rebuilds an empty local database, for rehearsing the demo. `--approve-as` and `--reset` refuse to run
unless `mdm.system_setting('environment_kind')` is `local` or `test`, the same check the generator uses (§3.2). The
approver must still be a different ADMIN from the preparer, so the two-person rule holds.

### 17.8.2 Screen: Admin › Data loads (UI_STANDARD)
| Step | Screen | API |
|---|---|---|
| Upload | Drop the CSV files or one zip, and pick the target version (default: the latest working one). Unknown file names are listed and ignored | `POST /admin/load-runs` (multipart) → a run in status `staging` |
| Check | Profile per file: row counts, errors that block the load, warnings, and skipped rows (FEED rules, derived attributes, rules with no expression) | `GET /admin/load-runs/{id}/profile` |
| Prepare | The run: target version, the requests it will create in order, and counts per hierarchy. Cancel is available until approval | `POST /admin/load-runs/{id}/prepare`; `POST …/cancel` |
| Approve | A second ADMIN opens the run and approves the manifest hash. The preparer sees the button disabled, with the reason | `POST /admin/load-runs/{id}/approve` (§5) |
| Apply | Progress per request (polled), then the reconciliation report. Every request links to its request page | `POST /admin/load-runs/{id}/apply`; `GET …/reconciliation` |
| History | Past runs: status, who prepared, approved and applied, when, and the target version | `GET /admin/load-runs` (paged) |

- **Access.** ADMIN can prepare, approve and apply. APPROVER can only read runs. The navigation entry sits under the
  Admin menu.
- **Staging without a second database credential.** The API runs as `nexus_api`, and `mdm_stage` is written only by
  the loader (CLAUDE.md rule 3). Upload therefore calls `mdm_stage.stage_rows(p_batch, p_file, p_rows jsonb)`, a new
  SECURITY DEFINER function owned by `nexus_loader` and executable by `nexus_api`. It inserts only into the
  `mdm_stage.hx_*` tables, in chunks of `STAGE_CHUNK_SIZE`. The scripts keep `COPY` for large files.
- **Upload limits.** `LOAD_UPLOAD_MAX_BYTES` defaults to 20 MB, and the multipart limit in `application.yml` is set to
  match. Files are parsed in memory and never written to disk. The parsing uses the JDK only (`java.util.zip`, a CSV
  reader in code that handles quotes), so no new dependency.
- **Apply is long-running.** It runs on a virtual thread. The screen polls `GET /admin/load-runs/{id}`, and a second
  apply on the same run is refused (N2810 `load.already_running`).
- **Run status.** `load_run.status` gains `staging`, before `prepared`.
- **Tests.**
  - Vitest for the store.
  - Storybook stories for each step, including the error and skipped states (axe).
  - Playwright `18-data-load`: upload the sample, then prepare as `e2e_admin`; the button is disabled for the
    preparer; approve and apply as a second admin; check the counts in the report.

### 17.9 Tests
- **pgTAP `32_hackathon_model`:**
  - display name history;
  - N2025 for each of its three cases;
  - the ledger checks;
  - each `trg_validation_rule_guard` refusal;
  - the guard seeds;
  - N2007;
  - import-mode rules run only for `system_feed` requests;
  - findings reported under the guard row.
- **JUnit:**
  - intake and profiling of the 12 files, including one broken file per finding kind;
  - the converter's order and counts;
  - the full load of the sample into a fresh database, with reconciliation equal to the files;
  - the rules API, with ADMIN able to edit and APPROVER only to read;
  - each rule-library rule on the sample (VR17 reports exactly 21230).
- **Playwright:** the rules screen with axe, and display names in the tree.
- **Data:** a fixture copy of the `data/` sample under `services/mdm-api/src/test/resources/load/hackathon/` (synthetic,
  allowed by CLAUDE.md rule 5), because `data/` is git-ignored.

### 17.10 Choices for the reviewer
| # | Choice | Recommendation |
|---|---|---|
| C-1 | Hierarchy list for a property: a join table, or a `uuid[]` column | Join table: real foreign keys, and hierarchies can be checked |
| C-2 | Applicability enforced at write as a guard (N2025), or reported only as a warning rule | Guard. The owner asked for it to be part of the model |
| C-3 | Rule edits by ADMIN directly (audited), or through change requests | Directly, audited, for now. Governed rule changes belong with the formula work (5-10, 5-11) |
| C-4 | Import-mode rules run for requests raised by a load (`system_feed`) | Yes |
| C-5 | Add `hierarchy.description` | Yes; small, and the CSV has it |
| C-6 | Order: build H-1 to H-8 now, ahead of 5-5 and the rest of Phase 5 | Yes, for the hackathon; Phase 5 resumes after H-8 |
| C-7 | The scripts' `--approve-as` (a second ADMIN approves from the command line), local and test only | Yes, for rehearsals; shared environments use the screen |

### 17.11 Work breakdown
| # | Increment | Size | Items | Tests |
|---|---|---|---|---|
| H-1 | Display name: V16 column and index, `add_node`/`update_node`, node readers, UI, search | M | HIE-01, HIE-02 | pgTAP, JUnit, Vitest, Playwright |
| H-2 | Property applicability: table, column, N2025, definitions API, grid | M | PRP-01, PRP-02 | pgTAP, JUnit, Vitest |
| H-3 | Ledgers: table, read and admin API | S | PROG | pgTAP, JUnit |
| H-4 | Rule catalogue: columns, guard seeds, guard trigger, N2007, `validate_change_request`, API, Admin screen | L | VAL-01, VAL-03 | pgTAP, JUnit, Playwright |
| H-5 | Staging `hx_*` tables, intake, profiler for the 12 files | M | PROG, IMP-01 | JUnit |
| H-6 | Load run (V16), converter, `provision_user`, version handling, rule library, apply, reconciliation | L | PROG, IMP-01, VER-01, VER-02, SEC-01 | pgTAP, JUnit |
| H-7 | Scripts `load-data.sh` and `load-data.ps1` (§17.8.1); full load of the sample end to end | S | PROG, IMP-01 | JUnit, script run |
| H-8 | Admin › Data loads screen and its API (§17.8.2): upload, `stage_rows`, profile, prepare, approve, apply, history; records (data model, BUILD_STATE, test report) | M | IMP-01, PROG | JUnit, Vitest, stories, Playwright |

No new dependencies.
