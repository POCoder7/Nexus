package com.mdm.api.workflow.engine;

import java.time.Instant;
import java.util.UUID;

/**
 * Engine → Nexus (ADR-035): everything the generic process does, each step one guarded, idempotent database call
 * (the ADR-024 job list). Steps take identifiers only; who acts is read from the database, never passed in by an
 * engine. An engine adapter binds its jobs or activities to these methods and adds nothing else.
 */
public interface WorkflowSteps {

    /** {@code wf.advance_instance}: activate the next stage, wait, ask for the policy evaluation, or report nothing left. */
    StepResult nextStage(UUID instanceId);

    /** {@code wf.complete_stage}: completes an approved stage (refused otherwise). */
    String completeStage(UUID instanceStageId);

    /** Validates the request and applies the commit policy (shadow mode records only); returns the policy outcome. */
    String evaluatePolicy(UUID instanceId);

    /** Closes the instance as committed when its Commit stage is approved, with the committing person as actor. */
    boolean closeCommitted(UUID instanceId);

    /** Closes the instance as rejected, with the person who rejected the stage as actor. */
    boolean closeRejected(UUID instanceStageId);

    /** Applies the approved change request (Phase 1 apply, as its decider); returns the request status afterwards. */
    String apply(UUID instanceId);

    /** The instance a stage belongs to. */
    UUID instanceOfStage(UUID instanceStageId);

    record StepResult(String action, UUID instanceStageId, String stageType, Instant dueAt) {
        public static final String ACTIVATED = "activated";
        public static final String WAIT = "wait";
        public static final String EVALUATE_POLICY = "evaluate_policy";
        public static final String NONE = "none";
    }
}
