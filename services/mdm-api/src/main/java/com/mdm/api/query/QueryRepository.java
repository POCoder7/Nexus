package com.mdm.api.query;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.query.QueryDtos.QueryDefinition;
import com.mdm.api.query.QueryDtos.SavedQueryView;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * SQL for property queries (QRY-01; Phase 5 LLD §17.5). The filter language and its evaluation live in the database
 * ({@code filter_compile}, {@code filter_holds}, {@code resolve_properties_batch}, V3 and V13), so exports and queries
 * give the same answer for the same filter.
 */
@Repository
public class QueryRepository {

    private final JdbcClient jdbc;
    private final ObjectMapper mapper;

    public QueryRepository(JdbcClient jdbc, ObjectMapper mapper) {
        this.jdbc = jdbc;
        this.mapper = mapper;
    }

    /** Checks a filter and returns it compiled: {@code {tree, attrs, props}} (N2604, N2605, N2807 from the database). */
    public JsonNode compile(JsonNode where) {
        return json(jdbc.sql("SELECT mdm.filter_compile(CAST(:f AS jsonb))::text").param("f", write(where))
                .query(String.class).single());
    }

    /** What decides each named property's query class (§17.5.2). */
    public Map<String, QueryPlanner.PropertyInfo> properties(Set<String> codes) {
        if (codes.isEmpty()) {
            return Map.of();
        }
        return jdbc.sql("""
                SELECT property_id, property_code, scope::text AS scope,
                       origin = 'stored' AND inheritance = 'none' AND default_value IS NULL AS stored_only,
                       origin = 'derived' AND derivation_engine = 'cel' AS cel
                FROM mdm.property_definition WHERE property_code = ANY (CAST(:codes AS text[]))
                """).param("codes", codes.toArray(String[]::new))
                .query((rs, i) -> new QueryPlanner.PropertyInfo(rs.getObject("property_id", UUID.class),
                        rs.getString("property_code"), rs.getString("scope"), rs.getBoolean("stored_only"), rs.getBoolean("cel")))
                .list().stream().collect(java.util.stream.Collectors.toMap(QueryPlanner.PropertyInfo::code, p -> p));
    }

    public int setting(String key, int fallback) {
        return jdbc.sql("SELECT setting_value FROM mdm.system_setting WHERE setting_key = :k").param("k", key)
                .query(String.class).optional().map(Integer::parseInt).orElse(fallback);
    }

    /** A version's slice: its business date, and its frozen recorded time (null while working = now). */
    public Optional<Object[]> versionSlice(String name) {
        return jdbc.sql("SELECT business_as_of, recorded_as_of FROM mdm.version WHERE version_name = :n").param("n", name)
                .query((rs, i) -> new Object[] {rs.getObject("business_as_of", LocalDate.class), ts(rs.getTimestamp("recorded_as_of"))})
                .optional();
    }

    /** One evaluated candidate: its keyset position, whether it matches, and its resolved values for the columns. */
    public record Candidate(UUID nodeId, String name, String parentName, boolean leaf, boolean hit, JsonNode values) {
    }

    /**
     * The next chunk of candidates after (afterName, afterId) in (name, id) order, each checked against the whole filter.
     * Candidates are the nodes placed in the hierarchy at the slice (or in the sub-tree under {@code root}), with
     * their attributes at the slice, narrowed by the planner's predicates and by {@code include} and inactivity.
     */
    public List<Candidate> chunk(UUID hierarchyId, UUID root, String include, boolean includeInactive, LocalDate asOf,
                                 Instant rec, JsonNode compiled, QueryPlanner.Plan plan, List<UUID> filterProps,
                                 List<UUID> allProps, String afterName, UUID afterId, int chunk) {
        String predicates = plan.predicates().isEmpty() ? "" : " AND " + String.join(" AND ", plan.predicates());
        var spec = jdbc.sql("""
                WITH RECURSIVE
                sub(node_id) AS (
                  SELECT CAST(:root AS uuid) WHERE CAST(:root AS uuid) IS NOT NULL
                  UNION
                  SELECT r.child_node_id FROM sub JOIN mdm.hierarchy_relationship r ON r.parent_node_id = sub.node_id
                  WHERE r.hierarchy_id = CAST(:hierarchyId AS uuid) AND r.valid_period @> CAST(:asOf AS date)
                    AND r.recorded_period @> CAST(:rec AS timestamptz)
                ),
                members(node_id) AS (
                  SELECT h.top_node_id FROM mdm.hierarchy h
                  WHERE h.hierarchy_id = CAST(:hierarchyId AS uuid) AND CAST(:root AS uuid) IS NULL
                  UNION
                  SELECT r.child_node_id FROM mdm.hierarchy_relationship r
                  WHERE CAST(:root AS uuid) IS NULL AND r.hierarchy_id = CAST(:hierarchyId AS uuid)
                    AND r.valid_period @> CAST(:asOf AS date) AND r.recorded_period @> CAST(:rec AS timestamptz)
                  UNION
                  SELECT node_id FROM sub
                ),
                cand AS (
                  SELECT m.node_id, a.node_name,
                         NOT EXISTS (SELECT 1 FROM mdm.hierarchy_relationship k
                                     WHERE k.hierarchy_id = CAST(:hierarchyId AS uuid) AND k.parent_node_id = m.node_id
                                       AND k.valid_period @> CAST(:asOf AS date)
                                       AND k.recorded_period @> CAST(:rec AS timestamptz)) AS is_leaf
                  FROM members m
                  JOIN mdm.node_attr a ON a.node_id = m.node_id AND a.valid_period @> CAST(:asOf AS date)
                   AND a.recorded_period @> CAST(:rec AS timestamptz)
                  WHERE (CAST(:inactive AS boolean) OR a.is_active)
                    AND (CAST(:afterName AS text) IS NULL
                         OR (a.node_name COLLATE "C", m.node_id) > (CAST(:afterName AS text) COLLATE "C", CAST(:afterId AS uuid)))
                    %s
                  ORDER BY a.node_name COLLATE "C", m.node_id
                  LIMIT :chunk
                ),
                kept AS (
                  SELECT * FROM cand
                  WHERE CAST(:include AS text) = 'all' OR (CAST(:include AS text) = 'leaves') = is_leaf
                ),
                props AS (
                  SELECT b.*, d.property_code
                  FROM mdm.resolve_properties_batch(ARRAY(SELECT node_id FROM kept), CAST(:hierarchyId AS uuid),
                                                    CAST(:asOf AS date), CAST(:rec AS timestamptz), CAST(:allProps AS uuid[])) b
                  JOIN mdm.property_definition d ON d.property_id = b.property_id
                )
                SELECT c.node_id, c.node_name, c.is_leaf,
                       k.node_id IS NOT NULL AND mdm.filter_holds(CAST(:tree AS jsonb), jsonb_build_object(
                         'attrs', mdm.filter_node_attrs(c.node_id, CAST(:hierarchyId AS uuid), CAST(:attrs AS text[]),
                                                        CAST(:asOf AS date), CAST(:rec AS timestamptz)),
                         'props', coalesce((SELECT jsonb_object_agg(p.property_code, p.value) FROM props p
                                            WHERE p.node_id = c.node_id AND p.property_id = ANY (CAST(:filterProps AS uuid[]))),
                                           '{}'::jsonb))) AS hit,
                       (SELECT pa.node_name FROM mdm.hierarchy_relationship pr
                        JOIN mdm.node_attr pa ON pa.node_id = pr.parent_node_id AND pa.valid_period @> CAST(:asOf AS date)
                         AND pa.recorded_period @> CAST(:rec AS timestamptz)
                        WHERE pr.hierarchy_id = CAST(:hierarchyId AS uuid) AND pr.child_node_id = c.node_id AND pr.is_primary
                          AND pr.valid_period @> CAST(:asOf AS date) AND pr.recorded_period @> CAST(:rec AS timestamptz)
                        LIMIT 1) AS parent_name,
                       (SELECT jsonb_object_agg(p.property_code, jsonb_build_object('value', p.value, 'provenance', p.provenance,
                                                                                    'source', p.source_node_id))::text
                        FROM props p WHERE p.node_id = c.node_id) AS vals
                FROM cand c LEFT JOIN kept k ON k.node_id = c.node_id
                ORDER BY c.node_name COLLATE "C", c.node_id
                """.formatted(predicates))
                .param("root", root).param("hierarchyId", hierarchyId).param("asOf", asOf).param("rec", Timestamp.from(rec))
                .param("inactive", includeInactive).param("include", include)
                .param("afterName", afterName).param("afterId", afterId).param("chunk", chunk)
                .param("tree", write(compiled.get("tree")))
                .param("attrs", mapper.convertValue(compiled.get("attrs"), String[].class))
                .param("filterProps", filterProps.toArray(UUID[]::new))
                .param("allProps", allProps.toArray(UUID[]::new));
        for (Map.Entry<String, Object> e : plan.params().entrySet()) {
            spec = spec.param(e.getKey(), e.getValue());
        }
        return spec.query((rs, i) -> new Candidate(rs.getObject("node_id", UUID.class), rs.getString("node_name"),
                        rs.getString("parent_name"), rs.getBoolean("is_leaf"), rs.getBoolean("hit"), json(rs.getString("vals"))))
                .list();
    }

    // ------------------------------------------------------------------ saved queries

    private static final String SELECT_SAVED = """
            SELECT q.saved_query_id, q.owner_id, q.name, q.description, h.hierarchy_code, q.definition::text AS definition,
                   q.visibility, q.created_at, q.updated_at, q.row_version
            FROM mdm.saved_query q LEFT JOIN mdm.hierarchy h ON h.hierarchy_id = q.hierarchy_id
            """;

    private SavedQueryView savedRow(java.sql.ResultSet rs, UUID me) throws java.sql.SQLException {
        UUID owner = rs.getObject("owner_id", UUID.class);
        try {
            return new SavedQueryView(rs.getObject("saved_query_id", UUID.class), rs.getString("name"), rs.getString("description"),
                    rs.getString("hierarchy_code"), mapper.readValue(rs.getString("definition"), QueryDefinition.class),
                    rs.getString("visibility"), owner, owner.equals(me), ts(rs.getTimestamp("created_at")),
                    ts(rs.getTimestamp("updated_at")), rs.getInt("row_version"));
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Invalid saved query definition", e);
        }
    }

    public Optional<SavedQueryView> saved(UUID id, UUID me) {
        return jdbc.sql(SELECT_SAVED + " WHERE q.saved_query_id = :id").param("id", id).query((rs, i) -> savedRow(rs, me)).optional();
    }

    public Optional<SavedQueryView> lockSaved(UUID id, UUID me) {
        return jdbc.sql(SELECT_SAVED + " WHERE q.saved_query_id = :id FOR UPDATE OF q").param("id", id)
                .query((rs, i) -> savedRow(rs, me)).optional();
    }

    /**
     * The caller's own queries and the shared ones, by (name, id), {@code limit + 1} rows. Whether the caller may read
     * a shared query's hierarchy is checked by the service ({@code readable} null = every hierarchy).
     */
    public List<SavedQueryView> listSaved(UUID me, Set<UUID> readable, String afterName, UUID afterId, int limit) {
        return jdbc.sql(SELECT_SAVED + """
                WHERE (q.owner_id = :me OR (q.visibility = 'shared'
                       AND (q.hierarchy_id IS NULL OR CAST(:readable AS uuid[]) IS NULL OR q.hierarchy_id = ANY (CAST(:readable AS uuid[])))))
                  AND (CAST(:afterName AS text) IS NULL OR (q.name COLLATE "C", q.saved_query_id) > (CAST(:afterName AS text) COLLATE "C", CAST(:afterId AS uuid)))
                ORDER BY q.name COLLATE "C", q.saved_query_id
                LIMIT :limit
                """).param("me", me).param("readable", readable == null ? null : readable.toArray(UUID[]::new))
                .param("afterName", afterName).param("afterId", afterId).param("limit", limit + 1)
                .query((rs, i) -> savedRow(rs, me)).list();
    }

    public int ownedCount(UUID me) {
        return jdbc.sql("SELECT count(*) FROM mdm.saved_query WHERE owner_id = :me").param("me", me).query(Integer.class).single();
    }

    public UUID insertSaved(UUID owner, String name, String description, UUID hierarchyId, JsonNode definition, String visibility) {
        return jdbc.sql("""
                INSERT INTO mdm.saved_query (owner_id, name, description, hierarchy_id, definition, visibility)
                VALUES (:owner, :name, :description, :h, CAST(:d AS jsonb), :v) RETURNING saved_query_id
                """).param("owner", owner).param("name", name).param("description", description).param("h", hierarchyId)
                .param("d", write(definition)).param("v", visibility).query(UUID.class).single();
    }

    public void updateSaved(UUID id, String name, String description, UUID hierarchyId, JsonNode definition, String visibility) {
        jdbc.sql("""
                UPDATE mdm.saved_query SET name = :name, description = :description, hierarchy_id = :h,
                       definition = CAST(:d AS jsonb), visibility = :v
                WHERE saved_query_id = :id
                """).param("id", id).param("name", name).param("description", description).param("h", hierarchyId)
                .param("d", write(definition)).param("v", visibility).update();
    }

    public void deleteSaved(UUID id) {
        jdbc.sql("DELETE FROM mdm.saved_query WHERE saved_query_id = :id").param("id", id).update();
    }

    // ------------------------------------------------------------------ helpers

    private static Instant ts(Timestamp t) {
        return t == null ? null : t.toInstant();
    }

    private String write(Object o) {
        try {
            return mapper.writeValueAsString(o);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException(e);
        }
    }

    private JsonNode json(String s) {
        try {
            return s == null ? mapper.createObjectNode() : mapper.readTree(s);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Invalid JSON from the query functions", e);
        }
    }
}
