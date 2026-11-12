package com.mdm.api.workflow;

import com.fasterxml.jackson.databind.JsonNode;
import com.mdm.api.security.Actor;

import java.util.Optional;
import java.util.UUID;

/**
 * The API's port to the workflow layer (Phase 2 LLD §3.1, ADR-017). Every call is one guarded {@code wf} or
 * {@code wf_bridge} function; the API never writes {@code wf} tables and never talks to the engine (ADR-024, ADR-035).
 */
public interface WorkflowGateway {

    UUID startInstance(UUID changeRequestId, String modelCode, Actor submitter);

    /** Records a person's decision on a stage; returns the stage outcome (pending, approved or rejected). */
    String recordDecision(UUID instanceStageId, Actor actor, String decision, String comment);

    void claim(UUID instanceStageId, Actor actor);

    void unclaim(UUID instanceStageId, Actor actor);

    UUID addEnrichmentItem(UUID instanceStageId, Actor actor, String action, UUID hierarchyId, UUID nodeId,
                           UUID targetParentId, UUID propertyId, JsonNode payload);

    void withdraw(UUID instanceId, Actor actor);

    /** The open root instance of a governed request. */
    Optional<UUID> openRootInstance(UUID changeRequestId);

    /** Why the actor cannot act on the stage (code and sentence), or empty if they can. Explains refusals only. */
    Optional<Refusal> whyCannotAct(UUID instanceStageId, Actor actor);

    record Refusal(String code, String message) {
    }
}
