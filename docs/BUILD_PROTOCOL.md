# Nexus build protocol

You are building Nexus, an AI-enabled master data management platform, in this repository. Work through the
phases below one at a time. Every phase follows the same loop: orient, plan, build, test, document, stop for
human approval. Apply the same loop recursively to any work item that is too large to finish in one increment.

This file is the standing instruction. `docs/BUILD_STATE.md` is your memory between sessions: read it first
in every session and update it before you stop.

## 1. Sources of truth (read before planning anything)

1. `CLAUDE.md`: non-negotiable rules. They override anything here if the two ever conflict.
2. `docs/capabilities.md`: what must be built. Every piece of work maps to a capability ID (or `PROG`).
3. `docs/data-model.md` and the migrations in `services/mdm-api/src/main/resources/db/migration`.
4. `docs/adr/`: decisions already made. Do not contradict an Accepted ADR without stopping to ask.
5. `docs/specs/`: specs; `SLICE-01-add-leaf.md` defines the first vertical slice.
6. `docs/design/phase-N-*/LLD.md`: the approved low-level design for the phase, plus
   `docs/architecture/overview.md` and `docs/architecture/patterns.md`. Each phase plan must follow its LLD.
   Any deviation needs the LLD updated and an ADR written **before** the code changes.
7. `docs/design/UI_STANDARD.md`: binding for all UI work (Angular on the organisation's design system, ADR-012).

## 2. Phases

Build in this order. Do not start a phase until the previous one has passed its gate and a human has said to proceed.

| # | Phase | Goal | Main capabilities | Exit criteria |
|---|---|---|---|---|
| 0 | Foundation | Everything that exists runs | PROG | `scripts/db-test` and `mvn verify` green locally; Maven wrapper committed; CI workflow valid |
| 1 | Core write path | Changes flow through change requests into the bitemporal model | HIE-01, HIE-02, HIE-06, PRP-01–03, VAL-01–03, AUD-01 | API to create change requests and items; apply service writes bitemporal rows atomically; validation runner; as-of reads proven by tests |
| 2 | Governance | DRG-equivalent workflow end to end | GOV-01–07, GOV-09, GOV-12, GOV-13 | A request moves Submit → (Enrich/Approve) → Commit through the `wf` layer; worklist API; separation of duties and human-only decisions proven; commit policy runs in shadow mode |
| 3 | Steward UI | The first slice is usable by a person | HIE-12, GOV-13, SLICE-01 | Tree browsing with paging, node panel, worklist, add-leaf form; UI tests pass; SLICE-01 acceptance criteria met on synthetic data |
| 4 | Data loading and parity harness | Realistic volumes and objective parity checks | IMP-01, IMP-02, ADM-04, NEW-09 | Staging loader; synthetic data generator at production-like scale; golden-test framework; performance baseline recorded |
| 5 | Remaining parity | The rest of the in-scope legacy capabilities | VER-*, HIE-*, PRP-04–10, VAL-04, QRY-*, IMP-03, SEC-*, AUD-* | Each capability with decision Parity or Improve has passing acceptance tests, or is listed as an explicit gap |
| 6 | Ownership and UBO | Beneficial-ownership analysis | NEW-02 | Ownership API and graph view; exact cross-holding calculation; UBO results with paths and evidence; thresholds as data |
| 7 | AI assistance | AI proposes, humans approve | NEW-03–06 | AI services behind an interface with a deterministic stub for tests; every AI output enters as a change request or suggestion; accuracy evaluation harness on synthetic data |
| 8 | Exports and reconciliation | Downstream compatibility | EXP-*, NEW-09 | Export service with profiles and bundles; byte-level comparison harness; export run history |
| 9 | Hardening | Ready for a security and operations review | SEC-05, NFRs | Authentication and authorisation integrated; observability; performance targets tested; runbooks; threat model |

Skip any capability whose decision is `Retire`. If a capability has no decision yet (`—`), build nothing for it:
list it under "Needs decision" in the phase plan.

## 3. The loop (apply to every phase, and recursively to large work items)

### Step 1: Orient
- Read `docs/BUILD_STATE.md`. If it does not exist, create it from the template in section 7.
- Run `git status`, then the full test suites, and record the baseline. Never start work on a red baseline:
  fix it first or stop and report.

### Step 2: Plan (then stop)
Write `docs/phases/phase-N/PLAN.md` containing:
- Scope: capability IDs in and out, with reasons.
- Work breakdown: increments small enough to implement and test in one sitting. If an item is not, break it
  into sub-items and apply this same loop to each (plan, build, test, document). Go at most three levels deep.
- Tests you will write for each increment, written against the acceptance criteria in `docs/capabilities.md` and the spec.
- Decisions you expect to need (each becomes an ADR) and any new dependencies you propose, with justification.
- Risks, assumptions and open questions for the human.

**Stop and wait for approval of the plan.** Do not write production code before the plan is approved.

### Step 3: Build in increments
For each increment:
1. Write or extend the tests first (pgTAP for database rules, JUnit with Testcontainers for services, the chosen UI test tool for the front end).
2. Implement the smallest change that makes them pass.
3. Run the relevant suite, then the full suite before committing.
4. Commit locally with the capability ID in the message. Ask before committing, as the permission rules require. Never push.

### Step 4: Record decisions and patterns as you go
- **Decisions.** Before implementing any non-trivial choice (a library, a boundary between components, a
  concurrency or transaction strategy, an API style, a data-model change), write an ADR from
  `docs/adr/ADR_TEMPLATE.md` with context, the decision, the alternatives you considered and why you rejected
  them, and the consequences. Mark it `Proposed`. If the choice changes an Accepted ADR, weakens a control,
  or changes a migration's meaning, stop and ask before implementing.
- **Patterns.** Maintain `docs/architecture/patterns.md` as a catalogue. For each architectural pattern you
  introduce or rely on (for example bitemporal append-only facts, outbox events, the read-only layer with a
  single bridge, policy-as-data, maker-checker, repository per aggregate, paged lazy tree loading), record:
  name, the problem it solves here, how it is implemented and where (file paths), trade-offs, and when not to use it.
- **Architecture overview.** Keep `docs/architecture/overview.md` current: system context, containers and
  components as Mermaid diagrams, the main request flows, and the data-flow for a change request from
  submission to applied data.

### Step 5: Phase test gate
Run everything and write `docs/phases/phase-N/TEST_REPORT.md` with:
- Exact commands run, and totals passed, failed and skipped per suite.
- A traceability table: capability ID → acceptance criteria → test(s) → result.
- Performance figures where the phase has them, and how they were measured.
- Every failure or skipped test, with cause. Do not disable, delete or weaken a test to pass the gate.

The gate passes only if all suites are green and every in-scope acceptance criterion is covered by a passing
test or listed as an explicit, explained gap.

### Step 6: Document
- `docs/phases/phase-N/SUMMARY.md`: what was built, decisions taken (links to ADRs), patterns introduced,
  deviations from the plan and why, known gaps and technical debt, what the next phase needs.
- Update `docs/data-model.md` for any schema change, the API reference (generate OpenAPI once the API exists),
  `README.md` quick start if commands changed, and `CHANGELOG.md`.
- Update `docs/BUILD_STATE.md`.

### Step 7: Stop and report
Give the human a short report: gate result, what to review first (ADRs marked Proposed, any change to
migrations or guards), open questions, and the proposed scope of the next phase. **Wait for an explicit
instruction to proceed.**

## 4. Guardrails specific to this build

- Follow every rule in `CLAUDE.md`. In particular: never weaken a trigger, constraint or guard to make
  something pass; `mdm` never references `wf`; only `wf_bridge` writes across layers; calculations are deterministic.
- **Synthetic data only.** Generate test and performance data. Never ask for, read or invent "realistic"
  client, account or personal data.
- **No silent stubs.** If something is stubbed, faked or deferred, say so in the summary and the build state.
  Never describe a capability as done when its acceptance tests do not pass.
- **Dependencies.** Propose new libraries, frameworks or services in the plan and wait for approval. Prefer the
  standard library and what Spring Boot already manages.
- **Decisions that are the human's, not yours.** Workflow engine choice, UI framework, authentication provider,
  AI model and provider, anything touching Audit or Risk controls, and anything that changes scope. Write the
  ADR with options and a recommendation, then stop.
- **Security.** No secrets in code or tests. Validate input at API boundaries. Parameterise all SQL. Page every
  list endpoint.

## 5. When to stop and ask

Stop immediately and report if:
- A requirement is ambiguous in a way that affects the data model, a control, or an external interface.
- A fix would require weakening a guard or contradicting an Accepted ADR.
- The same failure survives three distinct fix attempts.
- You need network access, credentials, or anything outside this repository.
- The plan turns out to be wrong in a way that changes scope or exit criteria.

## 6. Working across sessions

Sessions end and context is limited. Before you stop for any reason, update `docs/BUILD_STATE.md` so a new
session can continue without this conversation. Prefer several short sessions per phase over one long one,
and compact context after each increment.

## 7. Template for docs/BUILD_STATE.md

```markdown
# Build state

- **Current phase:** N — <name>
- **Step in loop:** Orient | Plan (awaiting approval) | Build | Test gate | Document | Awaiting approval to proceed
- **Baseline:** db-test <pass/fail, counts> · mvn verify <pass/fail, counts> · UI tests <…> (as of <date>)
- **Last commit:** <hash> <message>

## Completed phases
| Phase | Gate result | Summary | Date |
|---|---|---|---|

## Current phase progress
| Increment | Capability | Status | Tests | Notes |
|---|---|---|---|---|

## Decisions awaiting human review
| ADR | Title | Why it needs review |
|---|---|---|

## Open questions for the human

## Known gaps, stubs and technical debt

## Next action
```
