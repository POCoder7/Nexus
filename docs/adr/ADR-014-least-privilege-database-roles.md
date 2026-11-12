# ADR-014: Least-privilege database roles per layer

- **Status:** Accepted by the repository owner (2026-11-11); Security and Audit-Risk confirmation pending (OD-17a). Amended by ADR-019
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** PROG, GOV-12, AUD-01, SEC-01

## Context
V1–V6 contain no roles, `GRANT`s or row-level security. `docs/data-model.md` relies on "restrict write access on
`change_request` to the bridge role so the policy reference can't be forged", which is not implemented (D-04). The
layer rule (`mdm` never references `wf`; only `wf_bridge` writes across) is enforced only by review. Admin-authored SQL
in `sql`-engine rules and derivations runs with the caller's privileges (D-39).

## Decision (proposed)
| Role | Login | Privileges |
|---|---|---|
| `nexus_owner` | Flyway only | Owns all schemas and objects |
| `nexus_api` | `mdm-api` | `SELECT` on `mdm`, `wf`, `wf_bridge` views; `INSERT`/`UPDATE` on draft-side `mdm` tables (`change_request` excluding decision columns, `change_item`); `EXECUTE` on the apply function(s) and `wf` user-facing operations |
| `nexus_wf` | workflow worker | `SELECT` on `mdm`; DML on `wf`; no DML on `mdm` |
| `nexus_bridge` | none (owner of `wf_bridge` functions) | `UPDATE (status, submitted_at, decided_by, decided_at, decision_basis, decision_policy_ref)` on `mdm.change_request`; bridge functions are `SECURITY DEFINER` with a fixed `search_path` |
| `nexus_apply` | none (owner of the apply function) | DML on `mdm` fact tables; `SECURITY DEFINER` |
| `nexus_rules_ro` | none | `SELECT` only; `sql`-engine rule and derivation execution runs as this role |
| `nexus_readonly` | reporting | `SELECT` on approved views |

The roles are created by a migration; application logins are granted roles per environment (platform, OD-15).

## Alternatives considered
- **Status quo (one login with full rights):** simplest; the documented control does not exist and any SQL client can forge a policy approval for a low-risk request.
- **Row-level security policies:** finer control, but awkward for recursive sub-tree scopes and pooled connections; revisit for SEC-02 in Phase 9.
- **Separate databases per layer:** strongest isolation, but breaks the single-transaction bridge.

## Consequences
- Closes D-04 and enforces the layer rule mechanically; pgTAP tests run `SET ROLE` to prove each denial.
- `SECURITY DEFINER` functions become high-value code: each needs a fixed `search_path` (CLAUDE.md SQL convention) and tests.
- Local development and Testcontainers must create the roles too, so tests exercise the same privileges.
- Needs a human decision because it changes how Audit-relevant controls are enforced (OPEN_DECISIONS OD-17).
