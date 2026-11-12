# ADR-016: Transactional outboxes with per-consumer offsets

- **Status:** Accepted (repository owner, 2026-11-11)
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** GOV-08, GOV-16, NEW-07, PROG

## Context
`wf.event_outbox` (V4) is written in the same transaction as workflow changes, with a single `processed_at` column.
The V4 header and `docs/data-model.md` expect several consumers: the orchestration engine, a notifier and the bridge
(D-32). Applied data changes need events too (NEW-07), but `mdm` must never reference `wf`.

## Decision
- Keep `wf.event_outbox` for workflow events; add `mdm.change_event` for applied changes, written by the apply path in the apply transaction.
- Each consumer records its position in a consumer table (`wf.outbox_consumer`, `mdm.change_event_consumer`:
  `consumer_code`, `last_event_id`, `updated_at`). `processed_at` is left unused, then dropped once no reader depends on it.
- Consumers poll `event_id > last_event_id` for events older than `OUTBOX_SAFETY_LAG` (2 s), in batches of
  `OUTBOX_BATCH_SIZE` (500), process idempotently (deduplicate on `event_id`), then advance their offset in the same transaction as their own writes.
- Events are pruned after every registered consumer has passed them and `OUTBOX_RETENTION_DAYS` (30) have elapsed.
- A message broker is optional and open (OD-20); if adopted, a relay is one more consumer.

## Alternatives considered
- **Single `processed_at`:** works for one consumer only.
- **Logical decoding / CDC (e.g. Debezium):** no polling, but a platform dependency and harder local testing.
- **Publishing directly to a broker from the application:** dual write; events can be lost or invented on failure.

## Consequences
- Late-committing identity values can be skipped without the safety lag; the lag adds up to 2 s latency (acceptable for notifications; NEW-07 latency target is open, OD-10).
- One schema change per outbox (consumer table), proposed in the Phase 2 LLD.
