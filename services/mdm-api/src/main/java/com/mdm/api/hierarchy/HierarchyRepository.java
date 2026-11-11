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
