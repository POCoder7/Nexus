# ADR-030: Ownership calculation — exact rational solve, methodology per regime, recorded determinations

- **Status:** Accepted (repository owner, 2026-11-11). The methodology per regime (OD-35) and personal-data handling (OD-34) remain open
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** NEW-02

## Context
`mdm.effective_ownership` (V2) multiplies percentages along each acyclic path and excludes cross-holdings, noting that the
exact treatment ("(I − A)⁻¹ on the ownership matrix") belongs in an ownership service. The Phase 6 exit criterion asks for
an exact cross-holding calculation. Results near a threshold (for example 25 %) must not depend on floating-point rounding,
and CLAUDE.md rule 4 requires deterministic calculation in code or SQL.

## Decision
- Solve `x (I − A) = D` over the target's upstream component with exact rational arithmetic (`BigInteger` fractions),
  once per measure (economic, voting). Singular systems (closed loops) are reported, not approximated.
- The component is bounded (`OWNERSHIP_MAX_COMPONENT`, `OWNERSHIP_MAX_DEPTH`); above the bound the request is refused.
- Methodology is data: each `ubo_threshold` row names its `method` (`multiplicative` default, `control_chain` if Compliance requires it) and `measure`.
- Paths for evidence still come from the existing SQL; the solver adds the totals. Both must agree on acyclic graphs.
- A determination stores the slice, threshold, method, solver version, input hash and result, recorded by a human; append-only.
- Thresholds become bitemporal and change only through change requests decided by a `COMPLIANCE_OFFICER`.
- New roles `OWNERSHIP_ANALYST`, `COMPLIANCE_OFFICER` in the ADR-022 model.

## Options for OD-35 (methodology per regime)
| | Multiplicative with exact cross-holdings | Control chain (> 50 % control attributes 100 %) | Both, per regime |
|---|---|---|---|
| Fit | Common "effective ownership" reading | Some regimes' "ownership through control" reading | Each regime as its rules say |
**Recommendation:** both available, Compliance sets `method` per regime and signs off each threshold row.

## Alternatives considered
- **Floating-point matrix inverse:** fast, not exact.
- **Path enumeration with a cycle cap:** approximates an infinite series.
- **SQL-only solve:** no exact rational type; harder to test.

## Consequences
- O(n³) per component, bounded and measured; exact answers.
- Determinations are reproducible evidence for reviews and audits.
