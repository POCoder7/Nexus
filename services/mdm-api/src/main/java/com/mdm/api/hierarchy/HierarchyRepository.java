package com.mdm.api.hierarchy;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

@Repository
public class HierarchyRepository {

    private final JdbcClient jdbc;

    public HierarchyRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    public List<HierarchySummary> findActive(LocalDate asOf) {
        return jdbc.sql("""
                SELECT h.hierarchy_id, h.hierarchy_code, h.hierarchy_name, h.purpose, h.hierarchy_group,
                       h.top_node_id, a.node_name AS top_node_name
                FROM mdm.hierarchy h
                LEFT JOIN mdm.node_attr a
                       ON a.node_id = h.top_node_id
                      AND a.valid_period @> CAST(:asOf AS date)
                      AND upper_inf(a.recorded_period)
                WHERE h.is_active
                ORDER BY h.sort_seq NULLS LAST, h.hierarchy_code
                """)
                .param("asOf", asOf)
                .query((rs, i) -> new HierarchySummary(
                        rs.getString("hierarchy_code"),
                        rs.getString("hierarchy_name"),
                        rs.getString("purpose"),
                        rs.getString("hierarchy_group"),
                        rs.getObject("top_node_id", UUID.class),
                        rs.getString("top_node_name"),
                        rs.getObject("hierarchy_id", UUID.class)))
                .list();
    }

    public Optional<HierarchySummary> findByCode(String code, LocalDate asOf) {
        return findActive(asOf).stream().filter(h -> h.code().equals(code)).findFirst();
    }

    public Optional<UUID> findIdByCode(String code) {
        return jdbc.sql("SELECT hierarchy_id FROM mdm.hierarchy WHERE hierarchy_code = :code AND is_active")
                .param("code", code)
                .query(UUID.class)
                .optional();
    }

    /**
     * Children of one parent as of a business date, paged. Uses current recorded time.
     * Paging matters: some account hierarchies have thousands of leaves under one parent.
     */
    public List<ChildNode> findChildren(String hierarchyCode, UUID parentId, LocalDate asOf, int limit, int offset) {
        return jdbc.sql("""
                SELECT r.child_node_id, a.node_name, a.description,
                       coalesce(a.is_active, false) AS is_active,
                       r.is_primary, r.sort_order,
                       EXISTS (SELECT 1 FROM mdm.hierarchy_relationship c
                               WHERE c.hierarchy_id = r.hierarchy_id
                                 AND c.parent_node_id = r.child_node_id
                                 AND c.valid_period @> CAST(:asOf AS date)
                                 AND upper_inf(c.recorded_period)) AS has_children
                FROM mdm.hierarchy_relationship r
                JOIN mdm.hierarchy h ON h.hierarchy_id = r.hierarchy_id
                LEFT JOIN mdm.node_attr a
                       ON a.node_id = r.child_node_id
                      AND a.valid_period @> CAST(:asOf AS date)
                      AND upper_inf(a.recorded_period)
                WHERE h.hierarchy_code = :code
                  AND r.parent_node_id = :parentId
                  AND r.valid_period @> CAST(:asOf AS date)
                  AND upper_inf(r.recorded_period)
                ORDER BY r.sort_order, a.node_name
                LIMIT :limit OFFSET :offset
                """)
                .param("code", hierarchyCode)
                .param("parentId", parentId)
                .param("asOf", asOf)
                .param("limit", limit)
                .param("offset", offset)
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
