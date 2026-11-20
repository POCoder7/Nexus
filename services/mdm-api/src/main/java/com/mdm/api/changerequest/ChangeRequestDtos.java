package com.mdm.api.changerequest;

import com.fasterxml.jackson.databind.JsonNode;

import java.time.Instant;
import java.time.LocalDate;
import java.util.UUID;

/** Request and response bodies for the change-request API (Phase 1 LLD §5.2). */
public final class ChangeRequestDtos {

    private ChangeRequestDtos() {
    }

    public record CreateRequest(String versionName, String title, String rationale, String riskTier, LocalDate effectiveFrom,
                                String workflowModelCode, Boolean isUrgent) {
    }

    /** Partial update of a draft: a null field keeps the stored value. {@code versionName} moves the draft to another working version (ADR-037). */
    public record UpdateRequest(String title, String rationale, String riskTier, LocalDate effectiveFrom,
                                String workflowModelCode, Boolean isUrgent, String versionName) {
    }

    public record ItemCommand(String action, String hierarchyCode, UUID nodeId, UUID targetParentId, String propertyCode,
                              JsonNode payload) {
    }

    public record ChangeRequestView(UUID id, String versionName, String title, String rationale, String status,
                                    UUID requesterId, String requesterKind, String riskTier, LocalDate effectiveFrom,
                                    String origin, Instant createdAt, Instant submittedAt, UUID decidedBy,
                                    Instant decidedAt, String decisionNote, String decisionBasis, Instant appliedAt,
                                    String applyError, int itemCount, int rowVersion, String workflowModelCode,
                                    boolean isUrgent, boolean governedByWorkflow,
                                    /* root workflow instance, null in core mode (Phase 3 LLD §5.1) */ UUID workflowInstanceId) {
    }

    /** {@code before} is {@code payload.expected}: the state the item assumes, shown as "before → after" (Phase 3 LLD §5.1). */
    public record ItemView(UUID id, int seq, String action, String hierarchyCode, UUID nodeId, UUID targetParentId,
                           String propertyCode, JsonNode payload, JsonNode before, Instant createdAt) {
    }

    /** Core-mode decision: {@code approve} or {@code reject}, with an optional note. */
    public record DecisionRequest(String decision, String note) {
    }

    /**
     * A change to check before adding it: into the caller's open draft or sandbox ({@code requestId}), or else as the first
     * change of a request in {@code versionName} taking effect on {@code effectiveFrom} (default business today).
     * {@code properties} (optional) are set on the item's node as set_property items in the same check, so a new leaf is
     * checked with the values the user is about to give it.
     */
    public record CheckItem(UUID requestId, String versionName, LocalDate effectiveFrom, ItemCommand item,
                            java.util.List<CheckProperty> properties) {
    }

    /** A property value for the checked item's node. */
    public record CheckProperty(String code, JsonNode value) {
    }

    /** An item together with the request's new ETag after adding it. */
    public record AddedItem(ItemView item, int rowVersion) {
    }
}
