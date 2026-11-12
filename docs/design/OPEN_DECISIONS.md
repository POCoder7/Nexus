# Open decisions

Decisions, assumptions and unknowns that need a human. Owner types: Architecture · Product · Audit-Risk ·
Security · Platform · UX. Add to this list as design proceeds; do not resolve a row by choosing for them.

On 2026-11-11 the repository owner adopted the recommendations made so far ("go with your recommendations").
Those rows moved to **Decided** below. Rows that need another team's sign-off, or a value nobody has given yet, stay open.

## Open

| # | Decision / unknown | Owner | Options | Recommendation | Blocks |
|---|---|---|---|---|---|
| OD-01c | Will the platform team run Camunda 8 self-managed? (decides self-managed vs SaaS under OD-01b) | Platform / Procurement | Yes · No (use SaaS) | — (a fact to confirm; licence terms with the vendor) | Phase 2 build deployment; not the design |
| OD-02 | Design-system package names, registry, supported Angular version | UX / Platform | — | — | Phase 3 UI build |
| OD-03 | Design-system token list, for the mapping table in `UI_STANDARD.md` section 3 | UX | — | — | Phase 3 UI design |
| OD-04 | Does the design system provide a tree and a virtual-scrolling data grid? | UX | — | Use them if they exist; otherwise build on Angular CDK | Phase 3 scope |
| OD-05 | Approved graph-visualisation library for the ownership view | Architecture / Security | — | — | Phase 6 |
| OD-06 | Authentication provider and Angular library (ADR-033 options) | Security | OIDC · SAML (with an OIDC bridge) · gateway headers | OIDC resource server in the API (ADR-033 option A) | Phase 9; any shared environment (the API refuses to start outside `local`/`test` without it) |
| OD-07 | (Deferred with Phase 7, OD-38) AI model and provider, and where inference runs; whether data naming real people may be sent to it | Architecture / Security / Audit-Risk | External provider API · provider hosted in the organisation's cloud tenancy · self-hosted model inside the network | One that runs inside the organisation's network or tenancy, so ownership documents never leave it; the design works with any (provider adapter) | Phase 7 build beyond the stub provider |
| OD-08 | Audit/Risk sign-off on policy-governed straight-through commit (ADR-005) | Audit-Risk | Keep STP under approved policies · require human approval for all | Keep STP, shadow mode first | Activating any commit policy |
| OD-09 | Remaining capabilities marked "—" (75 after OD-13) | Product | Parity · Improve · Retire | Decide from discovery usage evidence; next: the rest of Phases 1–2 (HIE-06, PRP-02, PRP-03, VAL-01–03, AUD-01, AUD-02, GOV-03–09) | Detailed design of those capabilities (outline only until decided) |
| OD-10 | Production volumes and performance targets (NFRs) | Product / Platform | — | Parameterise (full list in "Assumptions" below) | Phases 3–5 performance design |
| OD-12 | Scenario / restructure versions: used today? (BLD-03) | Product | Build sandboxes · retire | Confirm in discovery | Phase 5 scope |
| OD-15a | Platform confirmation of the hosting direction (decided direction: container platform with managed PostgreSQL 16 and point-in-time recovery) | Platform | — | — | Phase 9 deployment design; first shared environment |
| OD-16a | Platform/Security confirmation of evidence and export storage (decided direction: object storage, server-side encryption, retention lock) | Platform / Security | — | — | Phase 6, Phase 8 |
| OD-17a | Security and Audit-Risk confirmation of ADR-014 (accepted by the repository owner) | Security / Audit-Risk | Confirm · request changes | Confirm before the first shared environment | First shared environment |
| OD-18a | Audit-Risk review of the control fixes as they are designed (Phase 1 LLD §9, Phase 2 LLD) | Audit-Risk | — | Review each fix ADR before its migration is merged | Merging the fix migrations |
| OD-25 | Audit retention period and archival (AUD-04) | Audit-Risk | — | Parameterise `AUDIT_RETENTION_YEARS`; no deletion in any phase until decided | Phase 5, Phase 9 |
| OD-29a | Audit-Risk confirmation of the load-run approval model (owner adopted option A, ADR-026) | Audit-Risk | Confirm · request changes | Confirm, and review the first real run | Phase 4 build: first load of real (masked) data |
| OD-31a | Security / Audit-Risk confirmation of rank-preserving pseudonyms (owner adopted, ADR-027) | Security / Audit-Risk | Confirm · request changes | Confirm | Golden tests on masked data |
| OD-32a | Security confirmation that masked golden datasets live in an internal artefact store, not git (owner adopted, ADR-027) | Security | Confirm · request changes | Confirm, and name the store | Golden tests in CI |
| OD-34 | Personal data in the ownership graph: who may see natural-person nodes, UBO results and evidence; retention of evidence and determinations | Privacy / Security / Audit-Risk | — | Ownership roles only; downloads audited; `retention_until` per document type; no deletion until decided | Phase 6 build (access matrix, retention fields) |
| OD-35 | UBO calculation methodology per regime (ADR-030) | Compliance / Audit-Risk | Multiplicative with exact cross-holdings · control chain · both per regime | Both available; Compliance sets `method` on each threshold row | Phase 6 build of `ControlChainStrategy`; any determination |
| OD-36 | Retention of AI prompts and responses (default: hashes and template ids only) | Security / Audit-Risk / Privacy | Hashes only · full content for `AI_CONTENT_RETENTION_DAYS` · full content permanently | Hashes only by default; full content for a limited period only if investigations need it | Phase 7 build (`ai_invocation` content columns) |
| OD-37 | Accuracy thresholds per AI capability (catalogue: "agreed threshold / rate / recall") | Product / Audit-Risk | — | Set before any model version is approved: `AI_EXTRACTION_MIN_F1`, `AI_DRAFT_MIN_ACCEPT_RATE`, `AI_ANOMALY_MIN_RECALL`, `AI_NLQ_MIN_EQUIVALENCE` | Approving any model version |
| OD-39 | How Nexus reads DRM's daily export files for reconciliation (location, access, retention) | Platform / Security | Shared folder inside the network · object-storage drop · DRM job pushes to Nexus | A read-only drop location inside the network written by the existing DRM export jobs | Phase 8 build (`DrmFileSource`) |
| OD-40 | Who may accept a reconciliation difference as a permanent parity exception | Audit-Risk / Product | Any reviewer · a second reviewer · the consumer's owner | A second reviewer, plus sign-off by the consumer's owner team for its feeds | Phase 8 build; cutover readiness |
| OD-41 | Recovery objectives (assumed `RPO_MIN` 15, `RTO_H` 4) and the availability SLO (assumed 99.5 % monthly) | Platform / Product / Audit-Risk | — | Confirm or set; they size backups, replicas and on-call | Phase 9 DR design and tests |
| OD-42 | Security tooling and the CI jobs for it: dependency scanning, SAST, secret scanning, container scanning, licence report | Security / Platform | GitHub-native (Dependabot, CodeQL, secret scanning) · organisation's tools | Whatever the organisation already licenses; otherwise GitHub-native | Phase 9 build (CI changes need approval) |
| OD-43 | Penetration test: scope, provider, timing | Security | — | External test of UI, API and evidence storage in pre-production before the first production release | Phase 9 gate |
| OD-28 | `docs/capabilities.md` says it is regenerated from a working copy outside the repository. The OD-13 decisions must be entered there, or the next regeneration will reset them to "—" | Product (catalogue owner) | Update the external working copy · let the repository copy become the master | Update the working copy, then regenerate | Keeping decisions consistent |

## Decided

| # | Decision | Decided by | Date | Effect |
|---|---|---|---|---|
| OD-01 | Workflow engine: **Camunda** (supersedes the earlier in-house-worker recommendation). Camunda orchestrates through `WorkflowGateway`; all state changes go through guarded `wf` functions; one generic BPMN process over the `wf` models (ADR-017) | Repository owner | 2026-11-11 | Phase 2 LLD; edition OD-01b (Camunda 8), hosting fact OD-01c |
| OD-22a | `BUSINESS_TIME_ZONE` = **`America/New_York`** (EST in winter, EDT in summer; OD-22b confirmed with daylight saving) | Repository owner | 2026-11-11 | Phase 1 and 2 |
| OD-01b | Camunda **8**: self-managed if the platform team runs it, otherwise SaaS with process variables limited to identifiers; not Camunda 7 | Repository owner (adopted recommendation) | 2026-11-11 | Phase 2; hosting fact OD-01c |
| OD-29 | Load-run approval: **option A** (one human approval of the manifest, recorded on every request; small runs request by request) | Repository owner (adopted recommendation) | 2026-11-11 | Audit-Risk confirmation pending (OD-29a) |
| OD-30 | DRM versions to migrate: **current + the versions needed for the parallel run and golden comparisons** | Repository owner (adopted recommendation) | 2026-11-11 | Phase 4 load plan |
| OD-31 | Masking: **rank-preserving pseudonyms** for names and codes, one tool for extracts and DRM outputs | Repository owner (adopted recommendation) | 2026-11-11 | Confirmation pending (OD-31a) |
| OD-32 | Golden datasets in an **internal artefact store**; only synthetic self-tests in git | Repository owner (adopted recommendation) | 2026-11-11 | Confirmation pending (OD-32a) |
| OD-33 | **ADR-009 accepted** (golden testing as the parity standard) | Repository owner (adopted recommendation) | 2026-11-11 | Phase 4, 5, 8 |
| OD-44 | **Shared environment** (CLAUDE.md rule 6) = any environment that keeps data between deployments or is used by more than one person; disposable CI and performance databases rebuilt per run do not count | Repository owner (adopted recommendation) | 2026-11-11 | Phase 4 performance runs use databases rebuilt per run, so "edit Vn" stays allowed until the first persistent or multi-user environment |
| — | **Wiring approved**; CLAUDE.md rule 3 extended for `mdm_stage` | Repository owner | 2026-11-11 | Design track closed; build sequence C starts with Phase 1 |
| — | **Consistency review approved** (CR-01 to CR-13); OD-44 stays open | Repository owner | 2026-11-11 | Design step 5 (wiring) |
| — | **Phase 9 LLD approved**; ADR-033 Accepted (IdP OD-06 open), ADR-034 Accepted | Repository owner | 2026-11-11 | Design step 4 (consistency review) |
| — | **Phase 8 LLD approved**; ADR-032 Accepted (OD-39, OD-40 open) | Repository owner | 2026-11-11 | Design track continues with Phase 9 |
| OD-38 | **Phase 7 (AI assistance): design approved, implementation deferred.** The build sequence skips Phase 7 (Phase 6 → Phase 8); AI features stay hidden; ADR-031 stands for when it is resumed | Repository owner | 2026-11-11 | Build phases; `BUILD_PROTOCOL.md` phase table updated in design step 5; OD-07, OD-36, OD-37 no longer block anything until resumed |
| — | **Phase 7 LLD approved** (build deferred, OD-38); ADR-031 Accepted | Repository owner | 2026-11-11 | Design track continues with Phase 8 |
| — | **Phase 6 LLD approved**; ADR-030 Accepted (methodology OD-35 and personal data OD-34 open) | Repository owner | 2026-11-11 | Design track continues with Phase 7 |
| — | **Phase 5 LLD approved**; ADR-028, ADR-029 Accepted | Repository owner | 2026-11-11 | Design track continues with Phase 6 |
| — | **Phase 4 LLD approved**; ADR-026 Accepted including the Phase 1 amendment (`add_hierarchy`, `update_node`); its approval model stays open (OD-29); ADR-027 stays Proposed (OD-31, OD-32) | Repository owner | 2026-11-11 | Design track continues with Phase 5 |
| — | **Phase 3 LLD approved**; ADR-025 Accepted (its dependencies and the UI CI job are approved in the Phase 3 build plan) | Repository owner | 2026-11-11 | Design track continues with Phase 4 |
| — | **Phase 2 LLD approved**; ADR-023 Accepted subject to Audit-Risk review (OD-18a); ADR-024 Accepted | Repository owner | 2026-11-11 | Design track continues with Phase 3 |
| — | **Phase 1 LLD approved**; ADR-019, ADR-020, ADR-022 Accepted; ADR-021 Accepted subject to Audit-Risk review before its migrations are merged (OD-18a) | Repository owner (adopted recommendation) | 2026-11-11 | Design track continues with Phase 2 |
| OD-11 | Repository: **`github.com/POCoder7/Nexus`, public** (replaces the private enterprise organisation chosen on 2026-11-11). Commit history rewritten to the account's GitHub noreply email before the first push | Repository owner | 2026-11-12 | Everything pushed is publicly readable: keep data synthetic and nothing from `.knowledge/` (CLAUDE.md rules 5 and 9) |
| OD-13 | **Parity:** HIE-01, HIE-02, HIE-12, PRP-01, GOV-02, GOV-13 (the SLICE-01 set). **Improve:** SEC-01, SEC-02 (a simpler role-and-scope model than DRM, mapped from DRM access groups at migration), brought forward to Phase 1 | Repository owner (adopted recommendation) | 2026-11-11 | Phase 1 and 2 LLDs design these in full. Recorded here and in `TRACEABILITY.md` until the catalogue is regenerated (OD-28) |
| OD-14 | Accept the phase placement proposed in `TRACEABILITY.md` (marked `*`), plus SEC-01/SEC-02 moved to Phase 1 | Repository owner (adopted recommendation) | 2026-11-11 | `BUILD_PROTOCOL.md` phase table updated in design step 5 (wiring) |
| OD-15 | Hosting direction: container platform with managed PostgreSQL 16 supporting point-in-time recovery | Repository owner (adopted recommendation) | 2026-11-11 | Platform to confirm (OD-15a) |
| OD-16 | Evidence and export storage direction: object storage with server-side encryption and retention lock | Repository owner (adopted recommendation) | 2026-11-11 | Platform/Security to confirm (OD-16a) |
| OD-17 | ADR-014 least-privilege database roles: **adopt** before the first shared environment | Repository owner (adopted recommendation) | 2026-11-11 | Phase 1; Security/Audit-Risk to confirm (OD-17a) |
| OD-18 | Control gaps: **fix before the first shared environment**, editing V1–V6 where the object is defined (rule 6 allows it now) and adding new files for new objects; one ADR per group of fixes; pgTAP tests for every fix; D-21 error codes at the same time. `mdm`-side gaps (D-04, D-05, D-07, D-29, D-36) in Phase 1; `wf`-side gaps (D-06, D-12, D-13, D-14, D-15, D-33) in Phase 2 | Repository owner (adopted recommendation) | 2026-11-11 | Phase 1 and 2 LLDs; Audit-Risk review per fix (OD-18a) |
| OD-19 | Rule and derivation engines beyond `sql`: **CEL evaluated in Java**; `python` stays unused unless a DRM formula cannot be expressed otherwise | Repository owner (adopted recommendation) | 2026-11-11 | Phase 5 (a CEL library is a dependency to approve then) |
| OD-20 | Events: **outbox polling first** (ADR-016); add a broker relay when a consumer needs it | Repository owner (adopted recommendation) | 2026-11-11 | Phase 2, Phase 8 |
| OD-21 | Search (QRY-03): **PostgreSQL full-text and `pg_trgm` first**, benchmark at `MAX_NODES_PER_HIERARCHY` | Repository owner (adopted recommendation) | 2026-11-11 | Phase 5 (QRY-03 itself still undecided) |
| OD-22 | Time: **one configured business time zone** (ADR-018) | Repository owner (adopted recommendation) | 2026-11-11 | Value still needed (OD-22a) |
| OD-23 | Testcontainers vs Docker Engine 29: **option A**, restore the `testcontainers.version` 1.21.4 pin in `services/mdm-api/pom.xml` | Repository owner | 2026-11-11 | Phase 0 increment P0-2 |
| OD-24 | Duplicates: **delete both** `docs/adr/ADR-012-web-ui-stack.md` and `knowledge/capabilities.md` | Repository owner | 2026-11-11 | Done in Phase 0 P0-1 |
| — | CI change approved: the `api` job uses `./mvnw -B verify` (Phase 0 P0-5); optional P0-6 included | Repository owner | 2026-11-11 | Phase 0 |
| OD-26 | Identity: users provisioned from IdP groups; the system actor and AI agent accounts are created only by migration or by an admin request under maker-checker | Repository owner (adopted recommendation) | 2026-11-11 | Phase 1 (interim actor), Phase 7, Phase 9 |
| OD-27 | Landing page: **combination** of the three prototype options. Home is the default start page; Hierarchies opens the workspace on the last hierarchy used; Worklist opens the GOV-13 queue; each user may choose their start page. Prototype: `docs/design/phase-3-steward-ui/prototypes/landing.html` | Product owner (repository owner) | 2026-11-11 | Phase 3 LLD §12. Needs a server-side user preference and a bounded Home summary API |
| — | Architecture overview and pattern catalogue (first version) **approved**; ADR-013, ADR-015, ADR-016, ADR-018 **Accepted**; ADR-014, ADR-017 **Accepted** with the confirmations above; `CLAUDE.md` commands switch to the Maven wrapper; basic RBAC in Phase 1 | Repository owner (adopted recommendation) | 2026-11-11 | Design track continues with the Phase 1 LLD |

## Assumptions (named parameters)

Each is configurable (an `mdm.*` property or a table value) and must be confirmed by the owner in OD-10 unless noted.

| Parameter | Assumed value | Used for | Owner |
|---|---|---|---|
| `MAX_NODES_PER_HIERARCHY` | 500 000 | Tree, export and scope benchmarks | Product / Platform |
| `MAX_HIERARCHY_DEPTH` | 50 (one setting for inheritance, ownership paths and tree walks; today 100 / 25 / none, D-09) | Recursion bounds | Product |
| `MAX_SIBLINGS` | 50 000 | Keyset paging benchmark | Product |
| `MAX_HIERARCHIES` | 500 | Hierarchy list paging | Product |
| `DEFAULT_PAGE_SIZE` / `mdm.api.max-page-size` | 200 / 1000 (exist in code) | All lists | Architecture |
| `MAX_ITEMS_PER_CHANGE_REQUEST` | 5 000 | Apply transaction size | Architecture |
| `CONCURRENT_STEWARDS` | 200 | Load tests | Product |
| `CHANGE_REQUESTS_PER_DAY` | 2 000 | Load tests, commit-policy caps | Product |
| `P95_CHILDREN_PAGE_MS` / `P95_NODE_DETAIL_MS` / `P95_WORKLIST_MS` | 300 / 500 / 500 | Performance targets | Product / Platform |
| `P95_SUBMIT_MS` / `P95_APPLY_MS` (requests of ≤ 50 items) | 2 000 / 2 000 | Phase 1 command latency | Product / Platform |
| `BUSINESS_TIME_ZONE` | `America/New_York` (OD-22a) in every profile; tests pin the clock | As-of defaults, day boundaries | Product |
| `OUTBOX_POLL_INTERVAL` | 1 s | Relay polling (Phase 2) | Architecture |
| `UI_INITIAL_JS_KB` / `UI_ROUTE_JS_KB` | 350 / 150 (compressed) | Angular build budgets (Phase 3) | Architecture / UX |
| `UI_TREE_EXPAND_MS` / `UI_INP_MS` | 100 / 200 | UI interaction targets (Phase 3) | Product / UX |
| `UI_TELEMETRY_SAMPLE` | 10 % | Client timing sampling (Phase 3) | Architecture |
| `LOAD_PARALLELISM` / `LOAD_SMALL_RUN_ITEMS` | 4 hierarchies / 500 items | Migration apply (Phase 4) | Architecture / Audit-Risk |
| `STAGE_RETENTION_DAYS` | 30 | Staging data after reconciliation | Security |
| `SANDBOX_MAX_ITEMS` / `SANDBOX_MAX_ACTIVE_PER_USER` / `SANDBOX_INCREMENTAL_THRESHOLD` | 20 000 / 5 / 1 000 | Sandboxes (Phase 5) | Product / Architecture |
| `OWNERSHIP_MAX_COMPONENT` / `OWNERSHIP_MAX_DEPTH` / `OWNERSHIP_GRAPH_MAX_NODES` | 2 000 / 25 / 300 | Ownership solver and view (Phase 6) | Compliance / Architecture |
| `UBO_MAX_PATHS` / `P95_UBO_MS` / `UBO_TIMEOUT_S` | 50 / 1 000 / 30 | UBO responses (Phase 6) | Compliance / Product |
| `EVIDENCE_MAX_MB` | 50 | Evidence uploads (Phase 6) | Security |
| `AI_TIMEOUT_S` / `AI_SCAN_BATCH` / `AI_SCAN_MAX_SUGGESTIONS` / `AI_INVALID_ALERT_PCT` | 60 / 1 000 / 500 / 5 % | AI calls (Phase 7) | Architecture |
| `AI_EXTRACT_P95_S` / `AI_DRAFT_P95_S` / `AI_NLQ_P95_S` | 60 / 15 / 5 | AI latency (Phase 7) | Product |
| `EXPORT_PARALLELISM` / `EXPORT_MAX_MIN` / `EXPORT_WINDOW_H` / `EXPORT_RETRY_DELAY_MIN` | 4 / 10 / 3 / 15 | Exports (Phase 8) | Platform |
| `RECON_DRM_WAIT_H` / `EVENT_LATENCY_P95_S` | 6 / 5 | Reconciliation, event feed (Phase 8) | Product / Platform |
| `RPO_MIN` / `RTO_H` / `SLO_AVAILABILITY` | 15 / 4 / 99.5 % | DR and SLOs (Phase 9, OD-41) | Platform / Product |
| `JWT_CLOCK_SKEW_S` / `JWKS_REFRESH_MIN` / `UI_IDLE_TIMEOUT_MIN` / `STEP_UP_MAX_AGE_MIN` | 60 / 5 / 30 / 15 | Authentication (Phase 9) | Security |
| `API_RATE_PER_MIN` / `API_WRITE_RATE_PER_MIN` / `API_MAX_BODY_KB` | 600 / 120 / 512 | API protection (Phase 9) | Security / Platform |
| `SECRET_ROTATION_DAYS` / `LEADER_TAKEOVER_S` / `SOAK_H` | 90 / 30 / 8 | Operations (Phase 9) | Platform |
| `TX_RETRY_MAX` | 3 | Serialization-failure retries | Architecture |
| `IDEMPOTENCY_KEY_TTL` | 24 h | Idempotent POSTs | Architecture |
| `OUTBOX_SAFETY_LAG` / `OUTBOX_BATCH_SIZE` / `OUTBOX_RETENTION_DAYS` / `OUTBOX_LAG_ALERT` | 2 s / 500 / 30 / 5 min | Event consumers (ADR-016) | Architecture / Platform |
| `BATCH_FETCH_SIZE` / `STAGE_CHUNK_SIZE` / `BATCH_QUEUE_CAPACITY` | 1 000 / 5 000 / 10 000 | Batch loads and exports | Architecture |
| `READ_CACHE_MAX_ENTRIES` | 10 000 | Immutable-slice cache (P-21) | Architecture |
| `PERF_SCALE_FACTOR` | 1.5 × production volumes | Synthetic data generator | Platform |
| `PARALLEL_RUN_DAYS` | 30 consecutive exact matches per consumer | Cutover (P-23) | Product / Audit-Risk |
| `API_DEPRECATION_MONTHS` | 6 | API versioning | Architecture |
| `AUDIT_RETENTION_YEARS` | none assumed (OD-25) | Retention | Audit-Risk |

## ADR status

| ADR | Title | Status | Note |
|---|---|---|---|
| ADR-013 | mdm-api as a modular monolith with ports and adapters | Accepted 2026-11-11 | |
| ADR-014 | Least-privilege database roles per layer | Accepted 2026-11-11 (repository owner) | Security/Audit-Risk confirmation pending (OD-17a); amended by ADR-019 |
| ADR-015 | API conventions | Accepted 2026-11-11 | |
| ADR-016 | Transactional outboxes with per-consumer offsets | Accepted 2026-11-11 | |
| ADR-017 | Workflow orchestration engine | Accepted 2026-11-11: Camunda 8 | Hosting OD-01c |
| ADR-018 | Time handling | Accepted 2026-11-11: `America/New_York` | |
| ADR-019 | Apply and decide as security-definer SQL functions; bridge-written clearance | Accepted 2026-11-11 | Refines P-09 and ADR-014; amended by ADR-023 |
| ADR-020 | Database error codes for guards | Accepted 2026-11-11 | D-21 |
| ADR-021 | Phase 1 control fixes in `mdm` | Accepted 2026-11-11 (Audit-Risk review pending, OD-18a) | Amended by ADR-023 (enrichment items) |
| ADR-022 | Role-and-scope entitlements, Phase 1 model | Accepted 2026-11-11 | |
| ADR-023 | Phase 2 control fixes in `wf` and the bridge | Accepted 2026-11-11 (Audit-Risk review pending, OD-18a) | Amends ADR-021 |
| ADR-024 | Camunda 8 integration: generic process, outbox-driven start, message-correlated decisions | Accepted 2026-11-11 | Dependencies approved in the Phase 2 plan |
| ADR-025 | UI toolchain | Accepted 2026-11-11 | Dependencies approved in the Phase 3 plan |
| ADR-026 | Governed migration load runs; `add_hierarchy` and `update_node` | Accepted 2026-11-11 (approval model open, OD-29) | Amends the Phase 1 LLD |
| ADR-028 | Sandboxes as draft requests with a trial-apply overlay | Accepted 2026-11-11 | NEW-08 |
| ADR-029 | Role grants as governed change actions | Accepted 2026-11-11 | SEC-01, SEC-02 |
| ADR-030 | Ownership calculation: exact rational solve, methodology per regime, recorded determinations | Accepted 2026-11-11 | Methodology OD-35 open |
| ADR-031 | AI service boundary, model governance, prompted-by maker-checker | Accepted 2026-11-11 (implementation deferred, OD-38) | OD-07, OD-36, OD-37 open |
| ADR-032 | Governed export profile versions, streaming runs, reconciliation review | Accepted 2026-11-11 | OD-39, OD-40 open |
| ADR-033 | Authentication: OIDC resource server; identities mapped, roles in Nexus | Accepted 2026-11-11 | IdP OD-06 open |
| ADR-034 | Observability: structured logs, Micrometer, OpenTelemetry | Accepted 2026-11-11 | Dependencies approved in the Phase 9 plan |
| ADR-027 | Golden datasets: masking and storage | Accepted 2026-11-11 (owner); Security/Audit-Risk confirmation pending | OD-31a, OD-32a |
| ADR-009 | Golden testing as the parity standard | Accepted 2026-11-11 (OD-33) | |
| ADR-005 to ADR-008 | (existing) | Proposed | Unchanged by this design |
