package com.mdm.api.workflow.engine;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Runs the relay in the workflow worker (LLD §3: profile 'worker'). Off unless {@code mdm.workflow.worker.enabled=true},
 * so the API process and the tests never poll by themselves. Poll interval: {@code OUTBOX_POLL_INTERVAL} (1 s); the
 * reconciler runs 30 s after start and then hourly.
 */
@Component
@EnableScheduling
@ConditionalOnProperty(name = "mdm.workflow.worker.enabled", havingValue = "true")
public class WorkerScheduler {

    private final OutboxRelay relay;
    private final WorkflowEngine engine;
    private final EngineReconciler reconciler;

    public WorkerScheduler(OutboxRelay relay, WorkflowEngine engine, EngineReconciler reconciler) {
        this.relay = relay;
        this.engine = engine;
        this.reconciler = reconciler;
    }

    @EventListener(ApplicationReadyEvent.class)
    public void deploy() {
        engine.deploy();
    }

    @Scheduled(fixedDelayString = "${mdm.workflow.outbox-poll-interval-ms:1000}")
    public void poll() {
        relay.poll();
    }

    /** Hourly, and once shortly after start (LLD §6.5): processes lost by the engine are recreated. */
    @Scheduled(initialDelayString = "${mdm.workflow.reconcile-initial-delay-ms:30000}",
               fixedDelayString = "${mdm.workflow.reconcile-interval-ms:3600000}")
    public void reconcile() {
        reconciler.reconcile();
    }
}
