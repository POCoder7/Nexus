# ADR-031: AI service boundary, model governance and prompted-by maker-checker

- **Status:** Accepted (repository owner, 2026-11-11). **Implementation deferred** with Phase 7 (OD-38). The model and provider (OD-07) remain open
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** NEW-03, NEW-04, NEW-05, NEW-06

## Context
ADR-008 says AI proposes, humans approve, code calculates; ADR-011 puts AI services in Python behind internal APIs. The
schema already prevents AI decisions and policy commits of AI requests. Open points: where the AI code runs and what it
can reach, which model versions may be used, and whether a human can approve an AI draft they asked for.

## Decision
- **Boundary:** a stateless Python service (`services/ai-service`) with no database credentials; it receives minimal
  fields and returns JSON validated by `mdm-api` against shared JSON schemas. Outputs become draft requests by an `ai_agent`
  user or suggestions; nothing else.
- **Provider adapter:** one interface; a deterministic stub provider for tests and development; one real adapter after
  OD-07, which refuses to start until an owner-only setting records the provider approval.
- **Model governance:** `mdm.ai_model_version` per purpose; a version is callable only when approved by a human other
  than its proposer, with an evaluation report meeting the OD-37 thresholds; one approved version per purpose.
- **Prompted-by rule:** the human who asked an AI agent to draft a request cannot decide it (`prompted_by` checked by the
  maker-checker trigger). That human is the only one who may submit or withdraw the AI's draft (amends the Phase 1 submit rule); an AI agent never submits.
- **Rationale required** on every AI-originated request (CHECK), as the catalogue already states.
- **Natural-language questions** produce a structured read-only plan executed by Nexus with the user's permissions; the model never sees the results.
- Python framework and libraries are proposed in the Phase 7 build plan for approval (dependency rule).

## Alternatives considered
- **Agentic model with tool access to Nexus:** more flexible; harder to bound and audit. Rejected for v1.
- **AI inside the Java service:** contradicts ADR-011 and mixes credentials with model traffic.
- **Allow the prompter to approve:** an easy route around maker-checker. Rejected.

## Consequences
- Every AI call is logged (`ai_invocation`) with hashes; content retention follows OD-36.
- AI features stay hidden until an approved model version exists for the purpose.
