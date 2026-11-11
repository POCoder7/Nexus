package com.mdm.api.changerequest;

import com.fasterxml.jackson.databind.JsonNode;

import java.time.Instant;
import java.time.LocalDate;
import java.util.UUID;

/** Request and response bodies for the change-request API (Phase 1 LLD §5.2). */
public final class ChangeRequestDtos {

    private ChangeRequestDtos() {
    }

    public record CreateRequest(String versionName, String title, String rationale, String riskTier, LocalDate effectiveFrom) {
    }

    public record UpdateRequest(String title, String rationale, String riskTier, LocalDate effectiveFrom) {
    }

    public record ItemCommand(String action, String hierarchyCode, UUID nodeId, UUID targetParentId, String propertyCode,
                              JsonNode payload) {
    }

    public record ChangeRequestView(UUID id, String versionName, String title, String rationale, String status,
                                    UUID requesterId, String requesterKind, String riskTier, LocalDate effectiveFrom,
                                    String origin, Instant createdAt, Instant submittedAt, UUID decidedBy,
                                    Instant decidedAt, String decisionNote, String decisionBasis, Instant appliedAt,
                                    String applyError, int itemCount, int rowVersion) {
    }

    public record ItemView(UUID id, int seq, String action, String hierarchyCode, UUID nodeId, UUID targetParentId,
                           String propertyCode, JsonNode payload, Instant createdAt) {
    }

    /** An item together with the request's new ETag after adding it. */
    public record AddedItem(ItemView item, int rowVersion) {
    }
}
