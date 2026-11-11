# Phase records

One folder per phase (`phase-0`, `phase-1`, …), created during the build by `docs/BUILD_PROTOCOL.md`:

- `PLAN.md` — scope, work breakdown, tests, risks (written before building, approved by a human)
- `TEST_REPORT.md` — commands run, results, traceability, failures and gaps
- `SUMMARY.md` — what was built, decisions, patterns, deviations, gaps, what the next phase needs

The low-level design for each phase lives in `docs/design/phase-N-<name>/LLD.md`.
