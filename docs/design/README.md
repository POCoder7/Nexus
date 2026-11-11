# Design documents

Produced by following `docs/DESIGN_PROTOCOL.md`, before implementation.

| Document | Purpose | Status |
|---|---|---|
| `UI_STANDARD.md` | Binding UI standard: Angular on the organisation's design system | Written |
| `DESIGN_STATE.md` | Progress memory for design sessions; what exists and where code and documents differ (D-nn) | Orient done; awaiting review |
| `OPEN_DECISIONS.md` | Decisions (OD-nn), named assumptions and Proposed ADRs needing a human | Extended; awaiting review |
| `TRACEABILITY.md` | Capability → phase → design section → planned tests (all 91 capabilities) | First version; awaiting review |
| `phase-1-core-write-path/LLD.md` | Phase 1: change requests, apply, validation infrastructure, roles and scopes, control fixes | Approved |
| `phase-2-governance/LLD.md` | Phase 2: Camunda 8 orchestration over `wf`, worklist, commit policy in shadow mode, workflow control fixes | Approved |
| `phase-3-steward-ui/LLD.md` | Phase 3: Angular steward UI (shell, Home, workspace, add leaf, worklist, request detail); prototype in `phase-3-steward-ui/prototypes/` | Approved |
| `phase-4-data-loading-and-parity/LLD.md` | Phase 4: governed DRM loader, synthetic generator, golden framework, performance baseline | Approved |
| `phase-5-remaining-parity/LLD.md` | Phase 5: sandboxes (NEW-08), governed role grants and read scopes (SEC-01/02 full), outlines for 35 pending capabilities | Approved |
| `phase-6-ownership-and-ubo/LLD.md` | Phase 6: governed ownership edges, evidence, exact UBO calculation, determinations, ownership views | Approved |
| `phase-7-ai-assistance/LLD.md` | Phase 7: AI service boundary, extraction, drafting, anomaly suggestions, NL questions as read-only plans, model governance, evaluation harness | Approved; build deferred (OD-38) |
| `phase-8-exports-and-reconciliation/LLD.md` | Phase 8: governed export profiles, streaming runs, bundles and schedules, daily DRM reconciliation, change-event feed | Draft; awaiting review |
| `phase-N-<name>/LLD.md` | Low-level design for Phase 9 (Phase 0 was built directly; see `docs/phases/phase-0/`) | Not started |
| `CONSISTENCY_REVIEW.md` | Cross-phase review after all LLDs: findings CR-01 to CR-13, error-code registry, role catalogue | Done; awaiting review |

Read in this order: `../architecture/overview.md`, `../architecture/patterns.md`, then the LLD for the phase
you are working on, with `UI_STANDARD.md` alongside for any screen work. `DESIGN_STATE.md` lists the differences
(D-nn) between the repository and its documents that every LLD must take into account.
