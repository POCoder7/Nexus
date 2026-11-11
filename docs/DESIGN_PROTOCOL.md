# Nexus design protocol: low-level technical design before implementation

You are producing the complete low-level technical design (LLD) for Nexus, phase by phase, **before any
implementation starts**. This is a documentation task. The output must be specific enough that an engineer,
or a later Claude Code session following `docs/BUILD_PROTOCOL.md`, can implement each phase without making
further design decisions.

`docs/design/DESIGN_STATE.md` is your memory between sessions: read it first in every session and update it
before you stop.

## 1. Rules for this task

- **Design only.** Do not write or change production code, migrations, tests, build files or CI. Do not add
  dependencies. You may read anything in the repository and run read-only commands (`git log`, `git status`,
  listing files). Write only under `docs/design/`, `docs/architecture/` and `docs/adr/`.
- **Follow `CLAUDE.md`.** No design may weaken a guard, break the `mdm` / `wf` / `wf_bridge` separation, move a
  calculation into an AI model, or rely on real data.
- **Ground everything in the repository.** Before describing existing behaviour, read the file. Reference real
  tables, functions, classes and paths. Never describe something as existing unless you have seen it.
- **Be specific.** No placeholder sections, no generic textbook text. If a section genuinely does not apply to
  a phase, write one line saying why.
- **Do not invent facts about the organisation.** Where a volume, performance target, team standard or
  external system is unknown, state an explicit assumption with a parameter name (for example
  `MAX_NODES_PER_HIERARCHY`), design so the value can change, and add it to the open decisions.
- **Decisions that belong to humans** are presented as options with a recommendation, never chosen: workflow
  engine, UI framework, authentication provider, AI model and provider, hosting platform, anything touching
  Audit or Risk controls, anything changing scope. Design the surrounding components so either option fits,
  and say what changes under each.

### UI standards
- The UI is Angular on the organisation's design system (ADR-012). `docs/design/UI_STANDARD.md` is binding
  for every phase with a user interface; the Phase 3 LLD must show how each screen and custom component
  complies with it.
- Do not copy styles, fonts, logos or other assets from any public website. Until the design-system packages
  are available, design against the Nexus token layer with neutral placeholder values and no brand marks.
- Record anything still needed from the UX / design-system team (section 12 of the standard) in
  `OPEN_DECISIONS.md`.

## 2. Inputs

`CLAUDE.md`, `docs/BUILD_PROTOCOL.md` (phase list, goals, capabilities and exit criteria), `docs/capabilities.md`,
`docs/data-model.md`, the migrations V1–V6, the existing Java service, `docs/adr/`, `docs/specs/`, `docs/design/UI_STANDARD.md`.

Capabilities with decision `Retire` are out of scope. Capabilities with no decision (`—`) get an outline design
only, clearly marked "pending decision", and an entry in the open decisions.

## 3. Deliverables

### 3.1 `docs/architecture/overview.md`
- System context, containers and components as Mermaid diagrams (C4 levels 1–3).
- Deployment view and environments, with assumptions.
- The end-to-end flow of a change: request, validation, workflow, commit policy, apply, audit, events.
- Cross-cutting design, each as its own section: transactions and consistency, concurrency control,
  error model, security and authorisation, audit and provenance, configuration, observability,
  time handling (business date vs recorded time, time zones), pagination, API versioning.
- Technology table: choice, status (Decided / Proposed / Open), ADR link.

### 3.2 `docs/architecture/patterns.md`: pattern catalogue for all phases
One entry per pattern, covering every phase, written before the phase designs and extended as they are written.
For each pattern:
- **Name and intent.**
- **Problem in Nexus:** the concrete force that makes it necessary here.
- **Solution:** structure (diagram or short code or SQL sketch), key rules, and the invariants it protects.
- **Where applied:** phases, components, and actual or planned file paths.
- **Trade-offs and failure modes.**
- **Alternatives considered** and why they were rejected.
- **When not to use it.**
- **Related ADR.**

Evaluate at least these candidates. Adopt, adapt or reject each one with reasons; do not include a pattern
just because it is listed:
bitemporal append-only facts · named version slices · maker-checker · policy as data with shadow mode ·
layered schemas with a single bridge (anti-corruption layer) · transactional outbox · ports and adapters ·
command path separated from read path · change items as commands with atomic apply (unit of work) ·
optimistic concurrency and idempotency keys · keyset pagination and lazy tree loading · tree storage and
traversal strategy (recursive queries vs closure table vs materialised path) · specification / rules engine for
validations · strategy for derived-property engines · state machine and process manager for workflow ·
event-driven notifications · role- and scope-based entitlements · evidence-linked provenance ·
human-in-the-loop AI with provider adapter · chunked and streaming batch processing with backpressure ·
caching strategy and invalidation · golden-master testing · strangler migration and parallel run.

### 3.3 One LLD per phase: `docs/design/phase-N-<name>/LLD.md`
Use exactly this structure for every phase (0–9):

1. **Purpose and scope.** Goal, capability IDs in and out, dependencies on earlier phases.
2. **Confidence and assumptions.** Confidence level (High / Medium / Low) with reasons, every assumption, and
   the human decisions this phase is waiting on.
3. **Component design.** Modules and package structure; each class or interface with its responsibility,
   key method signatures, collaborators, and what it must not do. Component diagram.
4. **Data design.** Tables, columns, constraints and indexes added or changed, as proposed DDL sketches
   (clearly marked as proposals, not migrations); bitemporal behaviour of each change; expected volumes;
   indexing and query strategy for the heaviest queries.
5. **Interface design.** Each endpoint or event: purpose, request and response schema, error cases,
   pagination, idempotency, authorisation rule. Include an OpenAPI fragment for APIs.
6. **Behaviour.** Mermaid sequence diagrams for each main flow; state machines; transaction boundaries;
   locking and concurrency; failure modes and recovery for each step.
7. **Algorithms.** Pseudocode for all non-trivial logic, with complexity and edge cases.
8. **Patterns applied.** Links to catalogue entries and why each fits this phase.
9. **Security and controls.** Authorisation, audit, data classification, abuse cases, and exactly how each
   control from `CLAUDE.md` is enforced and tested in this phase.
10. **Performance and scale.** Targets (or named assumptions), the design choices that meet them, and the
    benchmarks that will prove it.
11. **Observability.** Logs, metrics, traces and alerts.
12. **UI design** (phases with a user interface). Screens, component tree, state management, API calls per
    interaction, loading and error states, accessibility.
13. **Test design.** Traceability table: capability ID → acceptance criterion → test cases (positive,
    negative, control and boundary) → test type → synthetic data needed. Include performance and golden tests.
14. **Rollout and compatibility.** Migration ordering, backward compatibility, feature flags, rollback.
15. **Risks, open questions and alternatives.** Each significant alternative becomes an ADR.
16. **Work breakdown.** Increments in build order with relative size (S / M / L), each mapped to capability
    IDs and to the tests in section 13, ready to become the phase plan in `docs/BUILD_PROTOCOL.md`.

### 3.4 ADRs
Write an ADR (status `Proposed`) from `docs/adr/ADR_TEMPLATE.md` for every significant design decision, with
real alternatives and consequences. For human-owned decisions, the ADR lists options and a recommendation and
leaves the decision open.

### 3.5 Index and control documents under `docs/design/`
- `README.md`: index of all design documents and how to read them.
- `TRACEABILITY.md`: capability ID → phase → LLD section → planned tests. Every capability in
  `docs/capabilities.md` appears exactly once, or is listed as Retired or pending decision.
- `OPEN_DECISIONS.md`: every decision, assumption and unknown that needs a human, with owner type
  (Architecture / Product / Audit-Risk / Security / Platform), the options, your recommendation, and which
  phases are blocked by it.
- `DESIGN_STATE.md`: progress memory (see section 6).

## 4. Order of work and stop points

1. **Orient.** Read the inputs. Record in `DESIGN_STATE.md` what exists, including anything in the code or
   schema that differs from the documents.
2. **Architecture overview and pattern catalogue (first version).** Then **stop for review.**
3. **Phase LLDs in order, 0 to 9.** After each one, update the pattern catalogue, the traceability matrix
   and the open decisions, run the self-review in section 5, then **stop for review**, unless the human has
   said to continue through a named phase.
4. **Cross-phase consistency review** after Phase 9: interfaces match across phases, no contradictions between
   LLDs, ADRs, `CLAUDE.md` and the data model, every pattern entry lists where it is applied, every capability
   is traced. Write the findings to `docs/design/CONSISTENCY_REVIEW.md` and fix what you find.
5. **Wire the design into the build.** Add `docs/design/` and `docs/architecture/` to the sources of truth in
   `docs/BUILD_PROTOCOL.md` and to "Read first" in `CLAUDE.md`, with this rule: each phase plan must follow its
   LLD, and any deviation requires updating the LLD and an ADR first. Then stop and report.

## 5. Self-review before each stop

- Could someone implement this phase from the document alone, without asking a design question?
- Is every statement about existing code or schema verified against the file?
- Does anything weaken a control, cross the layer boundary, or contradict an Accepted ADR?
- Are all assumptions named and listed in `OPEN_DECISIONS.md`?
- Does every acceptance criterion in scope have test cases?
- Is the confidence level honest? Later phases depend on undecided capabilities and open decisions: say so
  plainly rather than writing confident detail on a guess.

## 6. Template for `docs/design/DESIGN_STATE.md`

```markdown
# Design state

- **Current item:** Overview | Patterns | Phase N LLD | Consistency review | Wiring into build
- **Status:** In progress | Awaiting review | Approved

## Documents
| Document | Status | Confidence | Last updated |
|---|---|---|---|

## Differences found between code/schema and documents

## Decisions blocking design (see OPEN_DECISIONS.md)

## Next action
```
