package com.mdm.api.compare;

import com.fasterxml.jackson.databind.JsonNode;

import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Request and response bodies for compares (QRY-02, VER-04; Phase 5 LLD §17.4, §17.11). */
public final class CompareDtos {

    private CompareDtos() {
    }

    /**
     * One side: a hierarchy and either a version (its business date and, once frozen, its recorded time) or a business
     * date and an optional recorded time. Neither means today, as recorded now.
     */
    public record CompareSide(String hierarchyCode, String version, LocalDate asOf, Instant recordedAsOf) {
    }

    /**
     * {@code kinds}: structure, property, rename (default all). {@code propertyCodes}: the properties a property compare
     * looks at (default every one). {@code subtreeRootId}: compare only below this node, on both sides.
     */
    public record CompareRequest(CompareSide left, CompareSide right, List<String> kinds, List<String> propertyCodes,
                                 UUID subtreeRootId, Boolean includeInactive, Boolean includeOrder) {
    }

    /** A side as resolved for the run: what was asked, and the slice it means. */
    public record ResolvedSide(String hierarchyCode, String hierarchyName, String version, LocalDate asOf, Instant recordedAsOf) {
    }

    /**
     * A run. {@code status}: running, done or failed (a run past its time limit reads as failed). {@code counts}: rows per
     * kind. {@code reused}: an earlier run of the same frozen slices answered this request.
     */
    public record CompareRunView(UUID id, String status, JsonNode counts, String error, ResolvedSide left, ResolvedSide right,
                                 List<String> kinds, Instant startedAt, Instant finishedAt, Instant expiresAt, boolean frozen,
                                 boolean reused) {
    }

    /**
     * One difference. {@code detail} by kind: structure {change: added | removed | moved | reordered | shared_added |
     * shared_removed, left and right parent id and name, sort orders}; property {property code, label, category, left and
     * right value and provenance}; rename {left and right name and description}.
     */
    public record CompareRow(String kind, UUID nodeId, String nodeName, JsonNode detail) {
    }
}
