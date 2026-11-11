# ADR-028: Sandboxes as long-lived draft requests with a trial-apply overlay

- **Status:** Accepted (repository owner, 2026-11-11)
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** NEW-08 (New), BLD-03 (pending, OD-12)

## Context
NEW-08 asks for sandboxes: build a restructure, see it, compare it, detect conflicts, apply it atomically or discard it.
DRM did this partly with versions and blending (BLD-01/02 retired). Nexus already has change requests, atomic apply and a
trial-apply technique for validation.

## Decision
- A sandbox is a change request of `kind = 'sandbox'`, kept in `draft`, owned by one user (F-1), up to `SANDBOX_MAX_ITEMS` items.
- Its view is base slice (at `sandbox_base_recorded_at`) plus a delta captured by trial-applying its items (P-28).
- Conflicts are items whose expected base no longer matches the current fact; rebase re-captures the clean ones.
- Submit turns it into a normal request (`kind = 'request'`, one-way) under Phase 1/2 governance.

## Alternatives considered
- **Physical copy of the hierarchy:** expensive and drifts from live data.
- **A separate overlay implementation per action:** a second copy of the change rules.
- **Branching versions (DRM-style scenarios):** more complex; BLD-03 is pending decision.

## Consequences
- The apply handlers gain a capture hook used only in trial mode.
- Sandbox exports are out of scope (F-3).
