package com.mdm.api.node;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
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

    public Optional<NodeDetail> find(UUID nodeId, String hierarchyCode, LocalDate asOf) {
        return jdbc.sql("""
                SELECT n.node_id, n.node_kind::text AS node_kind, a.node_name, a.description,
                       coalesce(a.is_active, false) AS is_active,
                       coalesce(a.allows_children, false) AS allows_children
                FROM mdm.node n
                LEFT JOIN mdm.node_attr a
                       ON a.node_id = n.node_id
                      AND a.valid_period @> CAST(:asOf AS date)
                      AND upper_inf(a.recorded_period)
                WHERE n.node_id = :id
                """)
                .param("id", nodeId)
                .param("asOf", asOf)
                .query((rs, i) -> new NodeDetail(
                        rs.getObject("node_id", UUID.class),
                        rs.getString("node_kind"),
                        rs.getString("node_name"),
                        rs.getString("description"),
                        rs.getBoolean("is_active"),
                        rs.getBoolean("allows_children"),
                        properties(nodeId, hierarchyCode, asOf)))
                .optional();
    }

    /** Resolves every property through mdm.property_value_asof (stored -> inherited -> default). */
    private List<PropertyValue> properties(UUID nodeId, String hierarchyCode, LocalDate asOf) {
        return jdbc.sql("""
                SELECT pd.property_code, pd.label, pd.data_type::text AS data_type, pd.scope::text AS scope,
                       mdm.property_value_asof(CAST(:id AS uuid), pd.property_id, h.hierarchy_id,
                                               CAST(:asOf AS date), now())::text AS value
                FROM mdm.property_definition pd
                LEFT JOIN mdm.hierarchy h ON h.hierarchy_code = CAST(:code AS text)
                WHERE pd.scope = 'global' OR h.hierarchy_id IS NOT NULL
                ORDER BY pd.category_code NULLS LAST, pd.label
                """)
                .param("id", nodeId)
                .param("code", hierarchyCode)
                .param("asOf", asOf)
                .query((rs, i) -> new PropertyValue(
                        rs.getString("property_code"),
                        rs.getString("label"),
                        rs.getString("data_type"),
                        rs.getString("scope"),
                        parse(rs.getString("value"))))
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
