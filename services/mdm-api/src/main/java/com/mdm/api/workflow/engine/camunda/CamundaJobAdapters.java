package com.mdm.api.workflow.engine.camunda;

import com.mdm.api.workflow.engine.WorkflowSteps;
import com.mdm.api.workflow.engine.WorkflowSteps.StepResult;
import io.camunda.zeebe.spring.client.annotation.JobWorker;
import io.camunda.zeebe.spring.client.annotation.Variable;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

/**
 * Binds the generic process's jobs to {@link WorkflowSteps} (ADR-035): one line each, nothing decided here. A failing
 * step fails the job; Camunda retries it and raises an incident after the retries (LLD §6.5).
 */
@Component
@ConditionalOnProperty(name = "mdm.workflow.engine", havingValue = "camunda")
public class CamundaJobAdapters {

    private final WorkflowSteps steps;

    public CamundaJobAdapters(WorkflowSteps steps) {
        this.steps = steps;
    }

    @JobWorker(type = "nexus.next-stage")
    public Map<String, Object> nextStage(@Variable String instanceId) {
        StepResult r = steps.nextStage(UUID.fromString(instanceId));
        Map<String, Object> out = new HashMap<>();
        out.put("action", r.action());
        out.put("instanceStageId", r.instanceStageId() == null ? "" : r.instanceStageId().toString());
        out.put("stageType", r.stageType() == null ? "" : r.stageType());
        return out;
    }

    @JobWorker(type = "nexus.complete-stage")
    public void completeStage(@Variable String instanceStageId) {
        steps.completeStage(UUID.fromString(instanceStageId));
    }

    @JobWorker(type = "nexus.evaluate-policy")
    public Map<String, Object> evaluatePolicy(@Variable String instanceId) {
        return Map.of("policyOutcome", steps.evaluatePolicy(UUID.fromString(instanceId)));
    }

    @JobWorker(type = "nexus.close-committed")
    public Map<String, Object> closeCommitted(@Variable String instanceId) {
        return Map.of("closed", steps.closeCommitted(UUID.fromString(instanceId)));
    }

    @JobWorker(type = "nexus.close-rejected")
    public void closeRejected(@Variable String instanceStageId) {
        steps.closeRejected(UUID.fromString(instanceStageId));
    }

    @JobWorker(type = "nexus.apply")
    public void apply(@Variable String instanceId) {
        steps.apply(UUID.fromString(instanceId));
    }
}
