package com.mdm.api.workflow.engine.camunda;

import com.mdm.api.workflow.engine.EngineMessage;
import com.mdm.api.workflow.engine.WorkerDatabase;
import com.mdm.api.workflow.engine.WorkflowEngine;
import io.camunda.zeebe.client.ZeebeClient;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Lazy;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.Map;
import java.util.UUID;

/**
 * {@link WorkflowEngine} on Camunda 8 (ADR-024, ADR-035). Deploys the generic process, creates one process instance
 * per workflow instance (its key stored as {@code wf.workflow_instance.engine_ref}) and publishes the two messages with
 * the outbox event id as message id, so Camunda drops duplicates. Variables are identifiers only (B-6).
 */
@Component
@ConditionalOnProperty(name = "mdm.workflow.engine", havingValue = "camunda")
public class CamundaWorkflowEngine implements WorkflowEngine {

    private static final Logger log = LoggerFactory.getLogger(CamundaWorkflowEngine.class);
    static final String PROCESS = "nexus-request";
    private static final Duration MESSAGE_TTL = Duration.ofHours(1);   // a message waits this long for its catch event

    private final ZeebeClient client;
    private final JdbcClient jdbc;

    public CamundaWorkflowEngine(@Lazy ZeebeClient client, WorkerDatabase worker) {
        this.client = client;
        this.jdbc = worker.jdbc();
    }

    @Override
    public void deploy() {
        long key = client.newDeployResourceCommand().addResourceFromClasspath("bpmn/nexus-request.bpmn").send().join().getKey();
        log.info("workflow.engine_deployed process={} deploymentKey={}", PROCESS, key);
    }

    @Override
    public void startProcess(UUID instanceId, UUID changeRequestId) {
        if (isRunning(instanceId)) {
            return;   // a process exists already (repeated delivery of instance_started)
        }
        long key = client.newCreateInstanceCommand().bpmnProcessId(PROCESS).latestVersion()
                .variables(Map.of("instanceId", instanceId.toString(), "changeRequestId", changeRequestId.toString()))
                .send().join().getProcessInstanceKey();
        jdbc.sql("UPDATE wf.workflow_instance SET engine_ref = :ref WHERE instance_id = :i AND engine_ref IS NULL")
                .param("ref", String.valueOf(key)).param("i", instanceId).update();
        log.info("workflow.process_started instanceId={} engineRef={}", instanceId, key);
    }

    @Override
    public void publish(EngineMessage message) {
        String name = message.type() == EngineMessage.Type.STAGE_DECIDED ? "stage-decided" : "request-withdrawn";
        var command = client.newPublishMessageCommand().messageName(name).correlationKey(message.correlationKey().toString())
                .messageId(String.valueOf(message.messageId())).timeToLive(MESSAGE_TTL);
        (message.outcome() == null ? command : command.variables(Map.of("outcome", message.outcome()))).send().join();
    }

    /**
     * A process was created for the instance. Camunda 8.7's client cannot query process instances, so this reads the
     * stored key; the reconciler (2-11) uses it to recreate a process for instances that never got one.
     */
    @Override
    public boolean isRunning(UUID instanceId) {
        return jdbc.sql("SELECT engine_ref IS NOT NULL FROM wf.workflow_instance WHERE instance_id = :i").param("i", instanceId)
                .query(Boolean.class).optional().orElse(false);
    }
}
