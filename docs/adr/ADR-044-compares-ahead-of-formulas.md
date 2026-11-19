# ADR-044: Build compares and baselines (5-12) before the formula increments (5-10, 5-11)

- **Status:** Accepted (repository owner, 2026-11-19: "the compare feature of DRM.. which phase is it in ?", then "yes"
  to building it next)
- **Date:** 2026-11-19
- **Deciders:** Repository owner
- **Capabilities:** QRY-02, VER-04 (decided by ADR-038; designed in Phase 5 LLD §17.4, approved 2026-11-14)
- **Amends:** the Phase 5 order (Phase 5 LLD §17.14: 5-9, 5-10, 5-11, 5-12, …)

## Context
§17.14 orders the ADR-038 increments 5-9 to 5-16, so compares (5-12) come after the CEL engine (5-10) and the
`set_property_derivation` action (5-11). The only link is the property compare: the design says "the resolver fills CEL
values" for derived properties.

The repository owner asked for DRM's compare next. As ADR-041 recorded for queries, **no CEL-derived property can exist
before 5-11**: the engine is 5-10 and the governed action that defines a formula is 5-11. So a property compare built now
meets no CEL value, and every value it compares is resolved by `resolve_properties_batch` (built in 5-9).

## Decision
1. **Order.** Build 5-12 now, as designed in §17.4; then 5-5 and the rest of the order as before.
2. **CEL values.** The property compare reads `resolve_properties_batch` only. When 5-11 makes CEL properties possible,
   5-11 adds them to the compare, and its tests gain "a compare with a CEL-derived property" (moved from 5-12's list).
3. **Read scope.** Hierarchy-level until 5-5, as every read (ADR-041, ADR-043); 5-5 adds `/compares` to its matrix.

## Alternatives considered
- **Keep the order.** The owner wants compares now; the formula increments are large (5-10 is L) and unrelated.

## Consequences
- The 5-12 test "property change including … CEL values" loses its CEL part until 5-11.
- 5-5 grows by the compare endpoints. The Phase 5 gate is unchanged.
