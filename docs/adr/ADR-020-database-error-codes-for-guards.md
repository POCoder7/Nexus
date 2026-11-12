# ADR-020: Database error codes for guards

- **Status:** Accepted (repository owner, 2026-11-11)
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** PROG

## Context
Guards raise `RAISE EXCEPTION '<text>'` with the default SQLSTATE `P0001`, so the API cannot tell a maker-checker
violation from a cycle or a type error and returns HTTP 500 (D-21). Mapping on message text is brittle, and pgTAP tests
assert on the text.

## Decision
- Every guard adds `USING ERRCODE = '<code>', HINT = '<machine_code>'` and keeps its current message text unchanged.
- Classes: `N1xxx` control violations (HTTP 403), `N2xxx` integrity rules (422), `N3xxx` concurrency conflicts (409),
  `N9999` reserved for the internal trial rollback in `validate_change_request`. Codes are listed in the Phase 1 LLD §5.3
  and kept in one table in `docs/data-model.md`.
- `DbErrorTranslator` maps by SQLSTATE class; `HINT` becomes the Problem Details `code`.

## Alternatives considered
- **Map on message text:** breaks when wording changes; rejected.
- **Standard SQLSTATEs only (`23514`, `42501`):** loses the difference between controls and integrity rules.

## Consequences
- A migration edit to every guard (messages unchanged), so existing pgTAP `throws_like` tests stay valid; new tests may assert codes with `throws_ok`.
- Changing a guard's error code is a guard change and follows CLAUDE.md rule 1.
