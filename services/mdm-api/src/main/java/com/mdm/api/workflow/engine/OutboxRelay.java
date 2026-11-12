package com.mdm.api.workflow.engine;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.UUID;

/**
 * Relays committed workflow events to the engine (ADR-016, ADR-024; engine-neutral per ADR-035). Reads
 * {@code wf.event_outbox} after its consumer offset (D-32), maps each relevant event to one engine call, and moves the
 * offset after each success, so a failure is retried on the next poll from the event that failed.
 *
 * <p>Events younger than the safety lag are left for the next poll: an event id is assigned before its transaction
 * commits, so a later id can become visible first; waiting avoids skipping the earlier one. Engine calls are idempotent
 * (business key, message id), so a repeated delivery does no harm.
 */
@Component
public class OutboxRelay {

    private static final Logger log = LoggerFactory.getLogger(OutboxRelay.class);
    public static final String CONSUMER = "engine_relay";

    record Event(long id, String type, UUID instanceId, String changeRequestId, String stageId, String outcome) {
    }

    private final JdbcClient jdbc;
    private final WorkflowEngine engine;
    private final long safetyLagMs;
    private final int batchSize;

    public OutboxRelay(WorkerDatabase worker, WorkflowEngine engine,
                       @Value("${mdm.workflow.outbox-safety-lag-ms:2000}") long safetyLagMs,
                       @Value("${mdm.workflow.outbox-batch-size:100}") int batchSize) {
        this.jdbc = worker.jdbc();
        this.engine = engine;
        this.safetyLagMs = safetyLagMs;
        this.batchSize = batchSize;
    }

    /** One pass; returns the number of events read (relevant or not). */
    public int poll() {
        long offset = jdbc.sql("SELECT last_event_id FROM wf.outbox_consumer WHERE consumer_code = :c").param("c", CONSUMER)
                .query(Long.class).single();
        List<Event> events = jdbc.sql("""
                SELECT event_id, event_type, instance_id, payload ->> 'change_request_id', payload ->> 'instance_stage_id',
                       payload ->> 'outcome'
                FROM wf.event_outbox
                WHERE event_id > :offset AND created_at <= clock_timestamp() - make_interval(secs => :lag / 1000.0)
                ORDER BY event_id LIMIT :n
                """).param("offset", offset).param("lag", safetyLagMs).param("n", batchSize)
                .query((rs, i) -> new Event(rs.getLong(1), rs.getString(2), rs.getObject(3, UUID.class), rs.getString(4),
                        rs.getString(5), rs.getString(6)))
                .list();
        for (Event e : events) {
            try {
                deliver(e);
            } catch (RuntimeException ex) {
                log.error("workflow.relay_failed eventId={} type={} instanceId={} alert=true", e.id(), e.type(), e.instanceId(), ex);
                return events.indexOf(e);   // offset stays before the failed event; retried next poll
            }
            jdbc.sql("UPDATE wf.outbox_consumer SET last_event_id = :id, updated_at = now() WHERE consumer_code = :c AND last_event_id < :id")
                    .param("id", e.id()).param("c", CONSUMER).update();
        }
        return events.size();
    }

    private void deliver(Event e) {
        switch (e.type()) {
            case "instance_started" -> engine.startProcess(e.instanceId(), UUID.fromString(e.changeRequestId()));
            case "stage_decision_recorded" -> {
                if ("approved".equals(e.outcome()) || "rejected".equals(e.outcome())) {   // 'pending': more groups to decide
                    engine.publish(EngineMessage.stageDecided(UUID.fromString(e.stageId()), e.outcome(), e.id()));
                }
            }
            case "instance_closed" -> {
                if ("withdrawn".equals(e.outcome())) {
                    engine.publish(EngineMessage.withdrawn(e.instanceId(), e.id()));
                }
            }
            default -> { }   // stage_status_changed, policy_evaluated, …: for other consumers (notifications, GOV-08)
        }
    }
}
