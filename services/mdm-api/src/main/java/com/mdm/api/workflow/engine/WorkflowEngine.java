package com.mdm.api.workflow.engine;

import java.util.UUID;

/**
 * Nexus → engine (ADR-035). The engine drives time and order; it decides nothing. Every call is idempotent: a process
 * is identified by the workflow instance id (business key), a message by the outbox event id.
 */
public interface WorkflowEngine {

    /** Makes the generic process available (BPMN deployment for Camunda; nothing for the in-process driver). */
    void deploy();

    /** Starts the generic process for an instance; a second call for the same instance does nothing. */
    void startProcess(UUID instanceId, UUID changeRequestId);

    /** Delivers a message to the waiting process; a message id seen before is ignored. */
    void publish(EngineMessage message);

    /** Whether the engine has a live process for the instance (used by the reconciler, 2-11). */
    boolean isRunning(UUID instanceId);
}
