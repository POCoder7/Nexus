# ADR-027: Golden datasets — masking approach and storage (decisions open)

- **Status:** Proposed. Masking (OD-31) and storage (OD-32) belong to Security and Audit-Risk; **not decided here**
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** all capabilities with golden test sources; NEW-09

## Context
ADR-009 (Proposed) makes golden tests the parity standard. `tests/golden/README.md` requires consistent masking before
use; CLAUDE.md rule 5 forbids production or client data in code and tests. Masked data derived from production is still
derived from it. Export parity is byte-level, so masking must preserve the properties that drive output: uniqueness,
relative sort order, lengths where fixed-width, and values that formulas depend on.

## Options: masking (OD-31)
| | Rank-preserving pseudonyms | Keyed hash (HMAC) pseudonyms | Format-preserving encryption |
|---|---|---|---|
| Uniqueness | Yes | Yes | Yes |
| Sort order | Preserved (names assigned in sorted order) | Not preserved: export order may differ | Not preserved |
| Consistency across files | Yes (one mapping table, kept inside the network) | Yes (one secret) | Yes |
| Re-identification risk | Mapping table must never leave the network | Secret must never leave | Key must never leave |
Numbers and dates that feed derived properties stay unmasked unless they identify someone; free text is replaced.
**Recommendation:** rank-preserving pseudonyms for names and codes, applied by one tool to extracts and DRM outputs alike.

## Options: storage (OD-32)
| | In git (`tests/golden/`) | Internal artefact store, fetched by CI | Only inside the network, tests run there |
|---|---|---|---|
| Fits CLAUDE.md rule 5 | Debatable (derived from production) | Yes (not in code or the repo) | Yes |
| CI on GitHub | Yes | Yes, with credentials (CLAUDE.md rule 8) | No: a separate pipeline |
**Recommendation:** internal artefact store; only synthetic self-test cases in git.

## Consequences
- Until decided, golden cases that need masked data report "dataset unavailable" (never a silent pass).
- ADR-009 should be accepted together with these decisions.
