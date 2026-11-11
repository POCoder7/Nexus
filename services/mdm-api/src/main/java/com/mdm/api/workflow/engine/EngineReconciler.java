package com.mdm.api.workflow.engine;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.UUID;

/**
 * Recreates lost processes (Phase 2 LLD §6.5, ADR-024; engine-neutral per ADR-035). For every in-flight workflow
 * instance the engine is not running, it starts the generic process again; the process resumes from the database
 * (next stage reports an active stage, or one already decided). Runs at worker start and hourly; an alert follows any
 * recreation, because it means the engine lost work.
 */
@Component
public class EngineReconciler {

    private static final Logger log = LoggerFactory.getLogger(EngineReconciler.class);

    private final JdbcClient jdbc;
    private final WorkflowEngine engine;

    public EngineReconciler(WorkerDatabase worker, WorkflowEngine engine) {
        this.jdbc = worker.jdbc();
        this.engine = engine;
    }

    /** Returns the number of processes recreated. */
    public int reconcile() {
        record Open(UUID instance, UUID changeRequest) {
        }
        List<Open> open = jdbc.sql("SELECT instance_id, change_request_id FROM wf.workflow_instance WHERE status = 'in_flight' ORDER BY submitted_at")
                .query((rs, i) -> new Open(rs.getObject(1, UUID.class), rs.getObject(2, UUID.class))).list();
        int recreated = 0;
        for (Open o : open) {
            if (!engine.isRunning(o.instance())) {
                try {
                    engine.startProcess(o.instance(), o.changeRequest());
                    recreated++;
                    log.warn("workflow.reconciler_recreated instanceId={} alert=true", o.instance());
                } catch (RuntimeException e) {
                    log.error("workflow.reconciler_failed instanceId={} alert=true", o.instance(), e);
                }
            }
        }
        return recreated;
    }
}
