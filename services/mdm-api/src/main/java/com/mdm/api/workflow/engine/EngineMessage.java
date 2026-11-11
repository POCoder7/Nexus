package com.mdm.api.workflow.engine;

import java.util.UUID;

/**
 * A message to the generic process (ADR-024): identifiers only, never names or values (B-6).
 *
 * @param type           {@link Type#STAGE_DECIDED} or {@link Type#REQUEST_WITHDRAWN}
 * @param correlationKey the instance stage (stage decided) or the instance (withdrawn)
 * @param messageId      the outbox event id, so a repeated delivery is recognised
 * @param outcome        the stage outcome ({@code approved} or {@code rejected}) for stage decided; otherwise null
 */
public record EngineMessage(Type type, UUID correlationKey, long messageId, String outcome) {

    public enum Type { STAGE_DECIDED, REQUEST_WITHDRAWN }

    public static EngineMessage stageDecided(UUID instanceStageId, String outcome, long eventId) {
        return new EngineMessage(Type.STAGE_DECIDED, instanceStageId, eventId, outcome);
    }

    public static EngineMessage withdrawn(UUID instanceId, long eventId) {
        return new EngineMessage(Type.REQUEST_WITHDRAWN, instanceId, eventId, null);
    }
}
