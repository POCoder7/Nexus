package com.mdm.api.workflow.engine.inprocess;

import com.mdm.api.workflow.engine.EngineMessage;
import com.mdm.api.workflow.engine.WorkflowEngine;
import com.mdm.api.workflow.engine.WorkflowSteps;
import com.mdm.api.workflow.engine.WorkflowSteps.StepResult;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Reference driver (ADR-035): the generic process of LLD §6.2 in plain Java, driven by the relay. It holds no state
 * that the database does not: "running" is only a cache of which instances it has started, rebuilt by the reconciler
 * after a restart. It proves the process does not depend on an engine, and runs every workflow scenario in the default
 * build. Timers and escalation (GOV-07) are not part of it.
 *
 * <pre>
 * start → next-stage ─ activated / wait → (wait for a message)
 *                    ├ evaluate_policy → evaluate ─ auto_committed → apply → end
 *                    │                            └ otherwise → next-stage
 *                    └ none → close committed (if Commit is approved) → apply → end
 * stage decided: approved → complete stage → next-stage;  rejected → close rejected → end
 * request withdrawn → end
 * </pre>
 */
@Component
@ConditionalOnProperty(name = "mdm.workflow.engine", havingValue = "inprocess", matchIfMissing = true)
public class InProcessWorkflowEngine implements WorkflowEngine {

    private static final Logger log = LoggerFactory.getLogger(InProcessWorkflowEngine.class);
    private static final int MAX_STEPS = 50;   // a generic process makes at most a few steps per message

    private final WorkflowSteps steps;
    private final Set<UUID> running = ConcurrentHashMap.newKeySet();
    private final Set<Long> delivered = ConcurrentHashMap.newKeySet();

    public InProcessWorkflowEngine(WorkflowSteps steps) {
        this.steps = steps;
    }

    @Override
    public void deploy() {
        // nothing to deploy: the process is this class
    }

    @Override
    public void startProcess(UUID instanceId, UUID changeRequestId) {
        running.add(instanceId);
        drive(instanceId);   // idempotent: an active stage just makes next-stage answer 'wait'
    }

    @Override
    public void publish(EngineMessage message) {
        if (!delivered.add(message.messageId())) {
            return;   // seen before
        }
        switch (message.type()) {
            case STAGE_DECIDED -> {
                UUID instance = steps.instanceOfStage(message.correlationKey());
                running.add(instance);
                if ("approved".equals(message.outcome())) {
                    steps.completeStage(message.correlationKey());
                    drive(instance);
                } else {
                    steps.closeRejected(message.correlationKey());
                    running.remove(instance);
                }
            }
            case REQUEST_WITHDRAWN -> running.remove(message.correlationKey());
        }
    }

    @Override
    public boolean isRunning(UUID instanceId) {
        return running.contains(instanceId);
    }

    private void drive(UUID instanceId) {
        for (int i = 0; i < MAX_STEPS; i++) {
            StepResult r = steps.nextStage(instanceId);
            switch (r.action()) {
                case StepResult.ACTIVATED, StepResult.WAIT -> {
                    return;
                }
                case StepResult.EVALUATE_POLICY -> {
                    if ("auto_committed".equals(steps.evaluatePolicy(instanceId))) {
                        steps.apply(instanceId);
                        running.remove(instanceId);
                        return;
                    }
                }
                default -> {   // none: Commit completed (close and apply), or the instance is no longer open
                    if (steps.closeCommitted(instanceId)) {
                        steps.apply(instanceId);
                    }
                    running.remove(instanceId);
                    return;
                }
            }
        }
        log.error("workflow.process_stuck instanceId={} steps={} alert=true", instanceId, MAX_STEPS);
    }
}
