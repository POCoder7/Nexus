package com.mdm.api.sandbox;

import com.fasterxml.jackson.databind.JsonNode;
import com.mdm.api.changerequest.ChangeRequestDtos.ItemView;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Request and response bodies for the sandbox API (NEW-08; Phase 5 LLD §5). */
public final class SandboxDtos {

    private SandboxDtos() {
    }

    /** {@code hierarchyCode}, when given, must be a hierarchy the owner may propose changes in; it is not stored. */
    public record CreateSandbox(String name, String versionName, String hierarchyCode, LocalDate effectiveFrom) {
    }

    /**
     * A sandbox, or the request it became ({@code kind} {@code request} after submit). {@code conflictCount} is computed
     * on read for an open sandbox (status draft, kind sandbox) and is null otherwise.
     */
    public record SandboxView(UUID id, String name, String versionName, String kind, String status, UUID ownerId,
                              LocalDate effectiveFrom, Instant baseRecordedAt, Instant createdAt, int itemCount,
                              Integer conflictCount, int rowVersion) {
    }

    /** An item the overlay leaves out because it fails (a rule failure in its trial apply). */
    public record ItemFailure(int seq, UUID itemId, String errorCode, String message, JsonNode detail) {
    }

    /** The outcome of an overlay refresh: the sandbox's new ETag and the items that failed. */
    public record RefreshResult(int rowVersion, List<ItemFailure> failures) {
    }

    public record SandboxItemAdded(ItemView item, int rowVersion, List<ItemFailure> failures) {
    }

    /** An item whose expected base no longer holds, and the request that changed it (null when unknown). */
    public record Conflict(int seq, UUID itemId, String action, String field, JsonNode expected, JsonNode actual,
                           UUID changedByRequest, Instant changedAt) {
    }

    /** A child row of the overlay tree; {@code changed} marks what differs from the sandbox's base on that date. */
    public record SandboxChild(UUID nodeId, String name, String description, boolean active, boolean primary,
                               BigDecimal sortOrder, boolean hasChildren, boolean changed) {
    }

    public record SandboxPlacement(UUID parentId, boolean primary, BigDecimal sortOrder, boolean changed) {
    }

    public record SandboxProperty(String code, String label, String dataType, String scope, JsonNode value,
                                  String provenance, UUID sourceNodeId, String category, boolean changed) {
    }

    /** Node detail in the overlay. {@code placements} are listed when a hierarchy is given. */
    public record SandboxNode(UUID nodeId, String kind, String name, String description, boolean active,
                              boolean allowsChildren, boolean changed, List<SandboxPlacement> placements,
                              List<SandboxProperty> properties) {
    }

    /**
     * One overlay row: a fact as it was in the base and is replaced ({@code side = before}), or as the sandbox writes it
     * ({@code after}). {@code fact} is {@code placement}, {@code attributes} or {@code value}.
     */
    public record DiffRow(String fact, String side, UUID nodeId, String hierarchyCode, UUID parentId, String propertyCode,
                          LocalDate validFrom, LocalDate validTo, JsonNode values) {
    }

    public record SubmitSandbox(String workflowModelCode) {
    }
}
