# ADR-032: Governed export profile versions, streaming export runs, reconciliation review

- **Status:** Proposed (Phase 8 LLD)
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** NEW-09, NEW-07, EXP-01, EXP-02, EXP-07, EXP-08, AUD-03

## Context
`mdm.export_profile` (V3) is mutable and unaudited, yet a change to it alters a downstream file. `mdm.run_export` builds the
whole file in memory to hash it. `mdm.export_run` and `mdm.drm_reconciliation` are not append-only (D-30), and nothing says who may accept a parity difference.

## Decision
- Export profiles are versioned; a version is frozen when submitted and approved by a second person; runs record the version.
- Java streams `mdm.export_drm` output, applying encoding and line endings and hashing as it writes; the SQL generator stays the reference, and any faster generator must match it byte for byte.
- Runs, bundle runs and closed reconciliations are append-only.
- Reconciliation differences are explained, fixed or accepted by humans; acceptance (a permanent parity exception) needs a second reviewer (OD-40).
- Change events reach consumers through a pull feed with identifiers only; a broker relay is optional later (OD-20).
- Scheduling uses Spring scheduling with a PostgreSQL advisory-lock leader; no new dependency.

## Alternatives considered
- **Leave profiles mutable with an audit trail:** detects change after the fact; downstream files could change without review.
- **In-database file generation (`COPY TO`):** server-side files, harder delivery and hashing.
- **Webhooks now:** needs outbound access and retry infrastructure; deferred.

## Consequences
- Existing profiles become version 1, approved at first deployment by a named human.
- New roles: `EXPORT_ADMIN`, `EXPORT_RUNNER`, `RECON_REVIEWER`, `INTEGRATION_READER`.
