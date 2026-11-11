# ADR-018: Time handling — business dates in a configured business time zone, UTC recorded time

- **Status:** Accepted (repository owner, 2026-11-11). The zone value is still open (OD-22a)
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** VER-03, NEW-01, GOV-07, GOV-12

## Context
The model has two clocks: business dates (`valid_period daterange`, `version.business_as_of date`) and recorded time
(`recorded_period tstzrange`). SQL defaults use `current_date`, `now()` and `date_trunc('day', now())`, which depend on
the session time zone; the API uses `LocalDate.now()` in the JVM default zone (D-16). Daily commit caps, freeze
windows, SLA due dates and "as of today" must agree across services and environments.

## Decision
- Recorded time is `timestamptz`, handled in UTC everywhere; database sessions set `TimeZone = 'UTC'`.
- "Today" for business dates is computed by the API in `BUSINESS_TIME_ZONE` (open: OD-22) and passed to SQL explicitly.
  Application code never relies on `current_date` defaults.
- Day-based limits (daily auto-commit cap, sampling by day) use the business day in `BUSINESS_TIME_ZONE`; the Phase 2
  LLD proposes passing the day boundary into `wf.evaluate_commit_policy` instead of `date_trunc('day', now())`
  (a change to a guard's inputs, not its rule; OD-18).
- APIs accept `asOf` (ISO date) and `recordedAsOf` (ISO instant); responses return instants with `Z`.
- The UI shows dates as `dd MMM yyyy` and times in 24-hour format with the zone (UI_STANDARD §7).

## Alternatives considered
- **Everything in UTC dates:** simple, but the business day would roll over at the wrong local hour for period-end freezes and caps.
- **Per-user time zones for business dates:** a fact would be "true" on different days for different users; rejected.

## Consequences
- One setting (`BUSINESS_TIME_ZONE`) to agree with Product; changing it later shifts day boundaries for caps and SLAs, not stored data.
- Tests pin the clock (`java.time.Clock` bean; SQL receives explicit dates) so time-dependent rules are deterministic.
