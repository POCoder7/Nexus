package com.mdm.api.query;

import com.fasterxml.jackson.databind.JsonNode;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

/** Request and response bodies for property queries (QRY-01; Phase 5 LLD §17.5). */
public final class QueryDtos {

    private QueryDtos() {
    }

    /**
     * A query: the hierarchy (and optionally a sub-tree) to search, which nodes, the conditions and the result columns.
     * {@code where} uses the filter language of export profiles (§17.5.1); {@code include} is {@code all}, {@code leaves}
     * or {@code limbs}.
     */
    public record QueryDefinition(String hierarchyCode, UUID rootNodeId, String include, Boolean includeInactive,
                                  JsonNode where, List<String> columns) {
    }

    public record RunQuery(QueryDefinition definition) {
    }

    /** One requested column of a result row, with where its value comes from (stored, inherited, derived, default, none). */
    public record QueryCell(String code, JsonNode value, String provenance, UUID sourceNodeId) {
    }

    public record QueryRow(UUID nodeId, String name, String parentName, boolean leaf, List<QueryCell> columns) {
    }

    /**
     * One page of results. {@code partial} is true when the scan budget ran out before the page filled: there may be
     * more matches, and {@code nextCursor} continues the scan. {@code scanned} is how many candidates this page examined.
     */
    public record QueryPage(List<QueryRow> items, String nextCursor, long scanned, boolean partial) {
    }

    public record SaveQuery(String name, String description, QueryDefinition definition, String visibility) {
    }

    public record SavedQueryView(UUID id, String name, String description, String hierarchyCode, QueryDefinition definition,
                                 String visibility, UUID ownerId, boolean mine, Instant createdAt, Instant updatedAt,
                                 int rowVersion) {
    }
}
