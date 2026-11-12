# ADR-036: Property edit rights by category (PRP-09, edit side of SEC-03)

- **Status:** Accepted (repository owner, 2026-11-12: "implement everything else, go with your recommendation"); Security confirmation pending with ADR-022
- **Date:** 2026-11-12
- **Deciders:** Repository owner
- **Capabilities:** PRP-09, SEC-03 (edit side), SEC-02

## Context
ADR-022 grants roles for all hierarchies, one hierarchy or one sub-tree. Phase 3 now lets stewards edit property values from
the property grid, so anyone with `PROPOSE` on a node could change any of its stored properties. DRM limits property edits by
property category. The Phase 5 design outlined "entitlements by category" (SEC-03) as a category scope on `mdm.user_role`;
the owner moved the editing screens into Phase 3 and asked for the rest of the UI too.

## Decision
- `mdm.user_role.category_codes text[]` (V10): NULL = every property category (all existing grants keep their meaning);
  otherwise the grant covers only properties in those categories. The value may not be an empty array.
- A `set_property` or `clear_property` item needs a `PROPOSE` grant that covers the node (as before) **and** the property's
  category. A property without a category is covered only by grants without a category limit. Other actions are unchanged.
- Enforced in the API (`EntitlementService`, the same place as the hierarchy and sub-tree scopes, ADR-022). The database
  guards are unchanged. `/me` returns each grant's categories so the UI hides Edit where the user has no right; the server
  refuses anyway (`entitlement.missing`).
- Read filtering by category (the read side of SEC-03) is not built; it stays in Phase 5.

## Alternatives considered
- **A separate grant table per category:** more rows and joins for the common case (no limit); rejected.
- **Enforce in the database:** entitlements are an API concern in ADR-022; mixing the two would split one rule across layers.
- **Task properties only (GOV-03):** a workflow model can already make properties read-only per task, but that is per model,
  not per person, and does not cover who may propose.

## Consequences
- Grants can be narrowed without new roles. Granting tools (Phase 5 administration) must offer the category list.
- Strengthens a control: no existing grant loses or gains rights.
