package com.mdm.api.hierarchy;

import com.mdm.api.common.Slice;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

@Repository
public class HierarchyRepository {

    /** Hierarchies without a sort sequence sort last, as in the UI and exports. */
    private static final int NO_SORT_SEQ = Integer.MAX_VALUE;

    private static final RowMapper<HierarchySummary> SUMMARY = (rs, i) -> new HierarchySummary(
            rs.getString("hierarchy_code"),
            rs.getString("hierarchy_name"),
            rs.getString("purpose"),
            rs.getString("hierarchy_group"),
            rs.getObject("top_node_id", UUID.class),
            rs.getString("top_node_name"),
            rs.getObject("hierarchy_id", UUID.class),
            rs.getInt("sort_key"));

    private final JdbcClient jdbc;

    public HierarchyRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    private static String select(Slice slice) {
        return """
                SELECT h.hierarchy_id, h.hierarchy_code, h.hierarchy_name, h.purpose, h.hierarchy_group,
                       h.top_node_id, a.node_name AS top_node_name, coalesce(h.sort_seq, %d) AS sort_key
                FROM mdm.hierarchy h
                LEFT JOIN mdm.node_attr a
                       ON a.node_id = h.top_node_id
                      AND a.valid_period @> CAST(:asOf AS date)
                      AND %s
                """.formatted(NO_SORT_SEQ, slice.recorded("a"));
    }

    /**
     * One keyset page of active hierarchies the caller may read ({@code readable} empty = all), ordered by
     * (sort sequence, code). Fetches {@code limit + 1} rows so the caller can tell whether another page exists.
     */
    public List<HierarchySummary> findPage(Slice slice, Optional<Set<UUID>> readable, List<String> after, int limit) {
        String[] ids = readable.map(s -> s.stream().map(UUID::toString).toArray(String[]::new)).orElse(null);
        return jdbc.sql(select(slice) + """
                WHERE h.is_active
                  AND (CAST(:ids AS text[]) IS NULL OR h.hierarchy_id::text = ANY (CAST(:ids AS text[])))
                  AND (CAST(:afterSort AS int) IS NULL
                       OR (coalesce(h.sort_seq, %d), h.hierarchy_code) > (CAST(:afterSort AS int), CAST(:afterCode AS text)))
                ORDER BY sort_key, h.hierarchy_code
                LIMIT :limit
                """.formatted(NO_SORT_SEQ))
                .param("asOf", slice.asOf())
                .param("rec", slice.recBind())
                .param("ids", ids)
                .param("afterSort", after == null ? null : Integer.valueOf(after.get(0)))
                .param("afterCode", after == null ? null : after.get(1))
                .param("limit", limit + 1)
                .query(SUMMARY)
                .list();
    }


    public Optional<HierarchySummary> findByCode(String code, Slice slice) {
        return jdbc.sql(select(slice) + " WHERE h.is_active AND h.hierarchy_code = :code")
                .param("asOf", slice.asOf())
                .param("rec", slice.recBind())
                .param("code", code)
                .query(SUMMARY)
                .optional();
    }

    public Optional<UUID> findIdByCode(String code) {
        return jdbc.sql("SELECT hierarchy_id FROM mdm.hierarchy WHERE hierarchy_code = :code AND is_active")
                .param("code", code)
                .query(UUID.class)
                .optional();
    }

    /** A node with its name, as one step of a path or a search hit. */
    public record NodeRef(UUID nodeId, String name) {
    }

    /**
     * HIE-12 in-tree search (Phase 3 LLD §5.1): nodes in the hierarchy at the slice whose name or description contains
     * {@code text} (case-insensitive; trigram indexes from V10), ordered by (name, id), keyset-paged. A node is "in" the
     * hierarchy if it is the top node or placed in it (primary or shared). Fetches {@code limit + 1} rows.
     */
    public List<NodeRef> search(UUID hierarchyId, String text, Slice slice, List<String> after, int limit) {
        return jdbc.sql("""
                SELECT a.node_id, a.node_name
                FROM mdm.node_attr a
                WHERE (a.node_name ILIKE :pattern ESCAPE '\\' OR a.description ILIKE :pattern ESCAPE '\\')
                  AND a.valid_period @> CAST(:asOf AS date)
                  AND %s
                  AND (a.node_id = (SELECT top_node_id FROM mdm.hierarchy WHERE hierarchy_id = :h)
                       OR EXISTS (SELECT 1 FROM mdm.hierarchy_relationship r
                                  WHERE r.hierarchy_id = :h AND r.child_node_id = a.node_id
                                    AND r.valid_period @> CAST(:asOf AS date) AND %s))
                  AND (CAST(:afterName AS text) IS NULL
                       OR (a.node_name, a.node_id) > (CAST(:afterName AS text), CAST(:afterId AS uuid)))
                ORDER BY a.node_name, a.node_id
                LIMIT :limit
                """.formatted(slice.recorded("a"), slice.recorded("r")))
                .param("pattern", "%" + likeEscape(text) + "%")
                .param("asOf", slice.asOf())
                .param("rec", slice.recBind())
                .param("h", hierarchyId)
                .param("afterName", after == null ? null : after.get(0))
                .param("afterId", after == null ? null : after.get(1))
                .param("limit", limit + 1)
                .query((rs, i) -> new NodeRef(rs.getObject("node_id", UUID.class), rs.getString("node_name")))
                .list();
    }

    /**
     * The primary-placement path from the top node down to {@code nodeId} at the slice (both included), used to reveal a
     * node in the tree (Phase 3 LLD §7.2). Empty when the node is not reachable from the top node on that date.
     * Depth is bounded as a safety net; the hierarchy guard already prevents cycles.
     */
    public List<NodeRef> primaryPath(UUID hierarchyId, UUID nodeId, Slice slice) {
        List<NodeRef> path = jdbc.sql("""
                WITH RECURSIVE up(node_id, depth) AS (
                  SELECT CAST(:node AS uuid), 0
                  UNION ALL
                  SELECT r.parent_node_id, up.depth + 1
                  FROM up
                  JOIN mdm.hierarchy_relationship r
                    ON r.child_node_id = up.node_id AND r.hierarchy_id = :h AND r.is_primary
                   AND r.valid_period @> CAST(:asOf AS date) AND %s
                  WHERE up.depth < 1000
                )
                SELECT up.node_id, a.node_name
                FROM up
                LEFT JOIN mdm.node_attr a ON a.node_id = up.node_id AND a.valid_period @> CAST(:asOf AS date) AND %s
                ORDER BY up.depth DESC
                """.formatted(slice.recorded("r"), slice.recorded("a")))
                .param("node", nodeId)
                .param("h", hierarchyId)
                .param("asOf", slice.asOf())
                .param("rec", slice.recBind())
                .query((rs, i) -> new NodeRef(rs.getObject("node_id", UUID.class), rs.getString("node_name")))
                .list();
        UUID top = jdbc.sql("SELECT top_node_id FROM mdm.hierarchy WHERE hierarchy_id = :h").param("h", hierarchyId)
                .query(UUID.class).single();
        return !path.isEmpty() && path.get(0).nodeId().equals(top) ? path : List.of();
    }

    /** Escapes LIKE wildcards so user text matches literally. */
    static String likeEscape(String text) {
        return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_");
    }

    /**
     * One keyset page of a parent's children at a slice, ordered by (sort order, name, node id) — the export
     * order plus the id as a tie-breaker (ADR-015). Fetches {@code limit + 1} rows.
     * Paging matters: some account hierarchies have thousands of leaves under one parent.
     */
    public List<ChildNode> findChildren(String hierarchyCode, UUID parentId, Slice slice, List<String> after, int limit) {
        return jdbc.sql("""
                SELECT r.child_node_id, a.node_name, a.description,
                       coalesce(a.is_active, false) AS is_active,
                       r.is_primary, r.sort_order,
                       EXISTS (SELECT 1 FROM mdm.hierarchy_relationship c
                               WHERE c.hierarchy_id = r.hierarchy_id
                                 AND c.parent_node_id = r.child_node_id
                                 AND c.valid_period @> CAST(:asOf AS date)
                                 AND %s) AS has_children
                FROM mdm.hierarchy_relationship r
                JOIN mdm.hierarchy h ON h.hierarchy_id = r.hierarchy_id
                LEFT JOIN mdm.node_attr a
                       ON a.node_id = r.child_node_id
                      AND a.valid_period @> CAST(:asOf AS date)
                      AND %s
                WHERE h.hierarchy_code = :code
                  AND r.parent_node_id = :parentId
                  AND r.valid_period @> CAST(:asOf AS date)
                  AND %s
                  AND (CAST(:afterSort AS numeric) IS NULL
                       OR (r.sort_order, coalesce(a.node_name, ''), r.child_node_id)
                          > (CAST(:afterSort AS numeric), CAST(:afterName AS text), CAST(:afterId AS uuid)))
                ORDER BY r.sort_order, coalesce(a.node_name, ''), r.child_node_id
                LIMIT :limit
                """.formatted(slice.recorded("c"), slice.recorded("a"), slice.recorded("r")))
                .param("code", hierarchyCode)
                .param("parentId", parentId)
                .param("asOf", slice.asOf())
                .param("rec", slice.recBind())
                .param("afterSort", after == null ? null : new java.math.BigDecimal(after.get(0)))
                .param("afterName", after == null ? null : after.get(1))
                .param("afterId", after == null ? null : after.get(2))
                .param("limit", limit + 1)
                .query((rs, i) -> new ChildNode(
                        rs.getObject("child_node_id", UUID.class),
                        rs.getString("node_name"),
                        rs.getString("description"),
                        rs.getBoolean("is_active"),
                        rs.getBoolean("is_primary"),
                        rs.getBigDecimal("sort_order"),
                        rs.getBoolean("has_children")))
                .list();
    }
}
