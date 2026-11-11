package com.mdm.api.node;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.common.Slice;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

@Repository
public class NodeRepository {

    private final JdbcClient jdbc;
    private final ObjectMapper mapper;

    public NodeRepository(JdbcClient jdbc, ObjectMapper mapper) {
        this.jdbc = jdbc;
        this.mapper = mapper;
    }

    /** Hierarchies the node belongs to on {@code asOf} (as top node or through any placement), current belief. */
    public List<UUID> hierarchiesContaining(UUID nodeId, LocalDate asOf) {
        return jdbc.sql("""
                SELECT h.hierarchy_id FROM mdm.hierarchy h WHERE h.top_node_id = :node
                UNION
                SELECT r.hierarchy_id FROM mdm.hierarchy_relationship r
                WHERE r.child_node_id = :node AND r.valid_period @> CAST(:asOf AS date) AND upper_inf(r.recorded_period)
                """)
                .param("node", nodeId)
                .param("asOf", asOf)
                .query(UUID.class)
                .list();
    }

    public boolean isInHierarchy(UUID nodeId, UUID hierarchyId, LocalDate asOf) {
        return hierarchiesContaining(nodeId, asOf).contains(hierarchyId);
    }

    public Optional<NodeDetail> find(UUID nodeId, String hierarchyCode, Slice slice) {
        return jdbc.sql("""
                SELECT n.node_id, n.node_kind::text AS node_kind, a.node_name, a.description,
                       coalesce(a.is_active, false) AS is_active,
                       coalesce(a.allows_children, false) AS allows_children
                FROM mdm.node n
                LEFT JOIN mdm.node_attr a
                       ON a.node_id = n.node_id
                      AND a.valid_period @> CAST(:asOf AS date)
                      AND %s
                WHERE n.node_id = :id
                """.formatted(slice.recorded("a")))
                .param("id", nodeId)
                .param("asOf", slice.asOf())
                .param("rec", slice.recBind())
                .query((rs, i) -> new NodeDetail(
                        rs.getObject("node_id", UUID.class),
                        rs.getString("node_kind"),
                        rs.getString("node_name"),
                        rs.getString("description"),
                        rs.getBoolean("is_active"),
                        rs.getBoolean("allows_children"),
                        properties(nodeId, hierarchyCode, slice)))
                .optional();
    }

    /**
     * Every property of the node in one call to mdm.node_properties_resolved (D-40), with where each value comes from:
     * stored, inherited (and from which ancestor), derived, default or none (D-18, UI_STANDARD provenance markers).
     */
    private List<PropertyValue> properties(UUID nodeId, String hierarchyCode, Slice slice) {
        return jdbc.sql("""
                SELECT pd.property_code, pd.label, pd.data_type::text AS data_type, pd.scope::text AS scope,
                       pd.category_code, x.value::text AS value, x.provenance, x.source_node_id
                FROM mdm.node_properties_resolved(
                       CAST(:id AS uuid),
                       (SELECT h.hierarchy_id FROM mdm.hierarchy h WHERE h.hierarchy_code = CAST(:code AS text)),
                       CAST(:asOf AS date),
                       coalesce(CAST(:rec AS timestamptz), now())) x
                JOIN mdm.property_definition pd ON pd.property_id = x.property_id
                ORDER BY pd.category_code NULLS LAST, pd.label
                """)
                .param("id", nodeId)
                .param("code", hierarchyCode)
                .param("asOf", slice.asOf())
                .param("rec", slice.recBind())
                .query((rs, i) -> new PropertyValue(
                        rs.getString("property_code"),
                        rs.getString("label"),
                        rs.getString("data_type"),
                        rs.getString("scope"),
                        parse(rs.getString("value")),
                        rs.getString("provenance"),
                        rs.getObject("source_node_id", UUID.class),
                        rs.getString("category_code")))
                .list();
    }

    private JsonNode parse(String json) {
        if (json == null) {
            return null;
        }
        try {
            return mapper.readTree(json);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Invalid JSON property value", e);
        }
    }
}
