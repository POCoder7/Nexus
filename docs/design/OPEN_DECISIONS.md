# Open decisions

Decisions, assumptions and unknowns that need a human. Owner types: Architecture · Product · Audit-Risk ·
Security · Platform · UX. Add to this list as design proceeds; do not resolve a row by choosing for them.

| # | Decision / unknown | Owner | Options | Recommendation | Blocks |
|---|---|---|---|---|---|
| OD-01 | Workflow orchestration engine (options and what changes under each: ADR-017) | Architecture / Platform | Temporal · Camunda · in-house scheduler | Temporal or Camunda, whichever the platform team already supports. Design note (ADR-017): an in-house worker behind `WorkflowGateway` is enough for Phase 2 if neither is already supported | Phase 2 |
| OD-02 | Design-system package names, registry, supported Angular version | UX / Platform | — | — | Phase 3 UI build |
| OD-03 | Design-system token list, for the mapping table in `UI_STANDARD.md` section 3 | UX | — | — | Phase 3 UI design |
| OD-04 | Does the design system provide a tree and a virtual-scrolling data grid? | UX | — | Use them if they exist; otherwise build on Angular CDK | Phase 3 scope |
| OD-05 | Approved graph-visualisation library for the ownership view | Architecture / Security | — | — | Phase 6 |
| OD-06 | Authentication and authorisation provider and Angular library | Security | — | Organisation SSO (OIDC/SAML) | Phase 9 |
| OD-07 | AI model and provider, and where inference runs | Architecture / Security / Audit-Risk | — | — | Phase 7 |
| OD-08 | Audit/Risk sign-off on policy-governed straight-through commit (ADR-005) | Audit-Risk | Keep STP under approved policies · require human approval for all | Keep STP, shadow mode first | Activating any commit policy |
| OD-09 | Capabilities still marked "—" in `docs/capabilities.md` | Product | Parity · Improve · Retire | Decide from discovery usage evidence | Phase 5 scope |
| OD-10 | Production volumes and performance targets (NFRs) | Product / Platform | — | Parameterise: `MAX_NODES_PER_HIERARCHY`, `MAX_HIERARCHY_DEPTH`, `MAX_SIBLINGS` (full list in "Assumptions" below) | Phases 3–5 performance design |
| OD-11 | Repository location and visibility | Architecture / Security | Enterprise GitHub org · private personal repo | Enterprise GitHub organisation | Pushing any code |
| OD-12 | Scenario / restructure versions: used today? (BLD-03) | Product | Build sandboxes · retire | Confirm in discovery | Phase 5 scope |
| OD-13 | Decisions for the capabilities in Phases 1–3. All of HIE-01, HIE-02, HIE-06, HIE-12, PRP-01–03, VAL-01–03, AUD-01, GOV-02–07, GOV-09, GOV-13 are `—`, so the design protocol allows only outline designs and the build protocol builds nothing for them | Product | Decide these first (Parity / Improve / Retire) · authorise detailed design ahead of the formal decision, marked provisional | Decide the SLICE-01 set first (HIE-01, HIE-02, HIE-12, PRP-01, GOV-02, GOV-13), then the rest of Phases 1–2 | Phase 1 and 2 LLDs (detailed), Phase 3 |
| OD-14 | Phase placement: 14 capabilities are in no phase of `BUILD_PROTOCOL.md`; 5 are in two (D-34). Proposed placement in `TRACEABILITY.md` (marked `*`) | Product / Architecture | Accept the proposed placement · amend `BUILD_PROTOCOL.md` differently | Accept, then update the phase table in `BUILD_PROTOCOL.md` | Traceability sign-off; phase plans |
| OD-15 | Hosting platform and shared environments (dev, test, pre-production, production) | Platform | Organisation container platform · cloud managed services · VMs | Container platform with managed PostgreSQL 16 supporting point-in-time recovery | Deployment design (Phase 9), VER-06, first shared environment (rule 6) |
| OD-16 | Storage for evidence documents and export files (`storage_uri`) | Platform / Security | Object storage · file share · database large objects | Object storage with server-side encryption and retention lock | Phase 6, Phase 8 |
| OD-17 | Least-privilege database roles (ADR-014) | Security / Audit-Risk | Adopt ADR-014 · keep one application login | Adopt before the first shared environment | Phase 1 data design; closes D-04 |
| OD-18 | Control gaps found in the existing schema: D-04 forgeable policy approval, D-05 self-declared requester kind, D-06 decider attribution after splits, D-07 mutable items and unguarded status transitions, D-12 unguarded claims, D-13 unauthorised reject/withdraw, D-14 cap race, D-15 kill-switch membership date, D-29 untraced changes, D-33 untracked group membership. Each fix strengthens a guard but still changes a trigger or migration | Audit-Risk / Architecture | Fix in V1–V6 now (allowed until a shared environment exists, rule 6) · fix later in V7+ · accept a gap with a recorded reason | Fix in V1–V6 before the first shared environment, one ADR per group of fixes, each with pgTAP tests (positive, negative); D-21 error codes at the same time | Phase 1 and 2 data design |
| OD-19 | Engines for rules and derived properties beyond `sql` (`cel`, `python` in the schema CHECKs). Accepted ADR-011 limits Python to AI and analysis (D-37) | Architecture | CEL evaluated in Java · Python rules service (needs an ADR-011 amendment) · SQL only | CEL in Java; keep `python` unused unless a DRM formula cannot be expressed otherwise | Phase 1 (validation runner shape), Phase 5 (PRP-06, VAL-04) |
| OD-20 | Event transport beyond the database (NEW-07, downstream, notifications e-mail) | Architecture / Platform | Outbox polling only · organisation message broker · CDC (logical decoding) | Outbox polling first (ADR-016); add a broker relay when a consumer needs it | Phase 2 (notifier), Phase 8 (NEW-07) |
| OD-21 | Search for QRY-03 | Architecture | PostgreSQL full-text + `pg_trgm` · dedicated search engine | PostgreSQL first; benchmark at `MAX_NODES_PER_HIERARCHY` | Phase 5 |
| OD-22 | Business time zone and business-day convention (ADR-018) | Product / Architecture | One organisation zone · UTC | One configured zone, `BUSINESS_TIME_ZONE` | Phase 1 (as-of defaults), Phase 2 (caps, SLAs, freeze windows) |
| OD-25 | Audit retention period and archival (AUD-04) | Audit-Risk | — | Parameterise `AUDIT_RETENTION_YEARS`; no deletion in any phase until decided | Phase 5, Phase 9 |
| OD-26 | Identity mapping: IdP subject ↔ `mdm.app_user`; provisioning of the system actor and AI agent accounts; who may create them | Security | — | Users provisioned from IdP groups; system and AI accounts created only by migration or an admin request under maker-checker | Phase 1 (interim actor), Phase 7, Phase 9 |

## Decided

| # | Decision | Decided by | Date | Effect |
|---|---|---|---|---|
| OD-23 | Testcontainers vs Docker Engine 29: **option A**, restore the `testcontainers.version` 1.21.4 pin in `services/mdm-api/pom.xml` | Repository owner | 2026-11-11 | Phase 0 increment P0-2 |
| OD-24 | Duplicates: **delete both** `docs/adr/ADR-012-web-ui-stack.md` and `knowledge/capabilities.md` | Repository owner | 2026-11-11 | Done in Phase 0 P0-1; `docs/capabilities.md` and Accepted ADR-012 are the only copies |
| — | CI change approved: the `api` job uses `./mvnw -B verify` from `services/mdm-api` (Phase 0 P0-5); optional P0-6 (Git Bash path fix in `db-test.sh`) included | Repository owner | 2026-11-11 | Phase 0 |
| OD-27 | Landing page: **combination** of the three prototype options. Home (search and overview) is the default start page; Hierarchies opens the workspace (tree + node panel) on the last hierarchy used; Worklist opens the GOV-13 queue; each user may choose their start page. Prototype: `docs/design/phase-3-steward-ui/prototypes/landing.html` | Product owner (repository owner) | 2026-11-11 | Phase 3 LLD §12 builds on it. Needs: a server-side user preference for the start page and last hierarchy used (the prototype uses browser storage only); a Home summary API (worklist top 5, own requests, hierarchies, AI suggestions, governance figures), all paged or bounded |

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
| `BUSINESS_TIME_ZONE` | none assumed (OD-22) | As-of defaults, day boundaries | Product |
| `TX_RETRY_MAX` | 3 | Serialization-failure retries | Architecture |
| `IDEMPOTENCY_KEY_TTL` | 24 h | Idempotent POSTs | Architecture |
| `OUTBOX_SAFETY_LAG` / `OUTBOX_BATCH_SIZE` / `OUTBOX_RETENTION_DAYS` / `OUTBOX_LAG_ALERT` | 2 s / 500 / 30 / 5 min | Event consumers (ADR-016) | Architecture / Platform |
| `BATCH_FETCH_SIZE` / `STAGE_CHUNK_SIZE` / `BATCH_QUEUE_CAPACITY` | 1 000 / 5 000 / 10 000 | Batch loads and exports | Architecture |
| `READ_CACHE_MAX_ENTRIES` | 10 000 | Immutable-slice cache (P-21) | Architecture |
| `PERF_SCALE_FACTOR` | 1.5 × production volumes | Synthetic data generator | Platform |
| `PARALLEL_RUN_DAYS` | 30 consecutive exact matches per consumer | Cutover (P-23) | Product / Audit-Risk |
| `API_DEPRECATION_MONTHS` | 6 | API versioning | Architecture |
| `AUDIT_RETENTION_YEARS` | none assumed (OD-25) | Retention | Audit-Risk |

## Proposed ADRs awaiting review

| ADR | Title | Owner | Note |
|---|---|---|---|
| ADR-013 | mdm-api as a modular monolith with ports and adapters | Architecture | |
| ADR-014 | Least-privilege database roles per layer | Security / Audit-Risk | = OD-17 |
| ADR-015 | API conventions | Architecture | Changes the response shape of the existing read endpoints within v1 |
| ADR-016 | Transactional outboxes with per-consumer offsets | Architecture | |
| ADR-017 | Workflow orchestration engine | Architecture / Platform | Decision open = OD-01 |
| ADR-018 | Time handling | Product / Architecture | Needs OD-22 |
| ADR-005 to ADR-009 | (existing, Proposed) | as listed in `docs/adr/README.md` | Unchanged by this design |
