package com.mdm.api.audit;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * The transaction-history search (AUD-01; Phase 5 LLD §18.3 to §18.5): explicit SQL over {@code mdm.audit_log} and, for
 * ADMINs, {@code wf.config_audit}. A fact row inserted by apply is paired with the row the same request closed for the
 * same subject (hierarchy, node, property), so an entry reads before → after; the closed row ("superseded") and an
 * unchanged copy of the earlier period ("restated", apply_fact's history before the effective date) are hidden unless
 * asked for. Read-only: the log is append-only and written only by its trigger.
 */
@Component
public class AuditQuery {

    /** The tables of each category (§18.3). {@code configuration} is the workflow's own audit table. */
    public static final Map<String, Set<String>> CATEGORIES = Map.of(
            "data", Set.of("node", "node_attr", "hierarchy", "hierarchy_relationship", "property_value", "node_identifier",
                    "legal_entity_profile", "ownership_edge"),
            "requests", Set.of("change_request", "change_item"),
            "definitions", Set.of("property_definition", "version"),
            "access", Set.of("user_role", "user_group", "user_group_member", "user_group_scope"),
            "configuration", Set.of());

    /** Tables whose rows are bitemporal facts: an UPDATE only closes the recorded period (trg_bitemporal_guard). */
    static final Set<String> BITEMPORAL = Set.of("node_attr", "node_identifier", "legal_entity_profile", "hierarchy_relationship",
            "property_value", "ownership_edge", "user_role", "user_group_member", "user_group_scope");

    /** Columns that say when or by which request a row was written, or are surrogate keys: not part of "what changed". */
    static final List<String> TECHNICAL = List.of("recorded_period", "valid_period", "change_request_id", "relationship_id",
            "property_value_id", "edge_id", "created_at", "row_version");

    /** The subject columns (shown as node, hierarchy, property): also left out of before/after. */
    private static final Set<String> SUBJECT = Set.of("hierarchy_id", "node_id", "child_node_id", "property_id", "owned_node_id");

    /** {@code readable}: null = every hierarchy; {@code admin}: no scope at all (§18.5). */
    public record Criteria(Instant from, Instant to, UUID user, UUID hierarchy, UUID node, UUID property, UUID request,
                           Set<String> categories, boolean includeSuperseded, boolean admin, Set<UUID> readable,
                           Instant cursorAt, String cursorSource, Long cursorId, int limit) {
    }

    /** One entry (§18.3). {@code id} is "source:audit id"; before/after carry only the meaningful columns. */
    public record AuditEntry(String id, Instant occurredAt, String category, String kind, String table, String operation,
                             UUID nodeId, String nodeName, String hierarchyCode, String propertyCode, String propertyLabel,
                             LocalDate validFrom, LocalDate validTo, JsonNode before, JsonNode after, List<String> changedFields,
                             UUID changeRequestId, String changeRequestTitle, String requestedBy, String decidedBy,
                             String decisionBasis, String actor) {
    }

    /** Raw row plus the sort key the cursor needs. */
    public record Row(AuditEntry entry, Instant occurredAt, String source, long auditId) {
    }

    private final JdbcClient jdbc;
    private final ObjectMapper mapper;

    public AuditQuery(JdbcClient jdbc, ObjectMapper mapper) {
        this.jdbc = jdbc;
        this.mapper = mapper;
    }

    /** Up to {@code limit + 1} rows, newest first, so the caller knows whether there is a next page. */
    public List<Row> search(Criteria c) {
        Set<String> mdmTables = c.categories().stream().flatMap(k -> CATEGORIES.get(k).stream()).collect(Collectors.toCollection(TreeSet::new));
        boolean config = c.categories().contains("configuration");
        StringBuilder sql = new StringBuilder("""
                WITH src AS (
                  SELECT 'mdm'::text AS src, a.audit_id, a.occurred_at, a.actor_id, a.change_request_id, a.table_name, a.action,
                         a.old_row, a.new_row, a.hierarchy_id, a.node_id, a.property_id
                  FROM mdm.audit_log a
                  WHERE a.table_name = ANY(string_to_array(:tables, ',')) AND a.occurred_at >= :from AND a.occurred_at < :to
                """);
        if (config) {
            sql.append("""
                  UNION ALL
                  SELECT 'wf'::text, c.audit_id, c.occurred_at, c.actor_id, NULL::uuid, c.table_name, c.action, c.old_row, c.new_row,
                         NULL::uuid, NULL::uuid, NULL::uuid
                  FROM wf.config_audit c
                  WHERE c.occurred_at >= :from AND c.occurred_at < :to
                """);
        }
        sql.append("""
                ),
                picked AS (
                  SELECT s.*, prev.old_row AS before_row
                  FROM src s
                  LEFT JOIN LATERAL (
                    SELECT x.old_row FROM mdm.audit_log x
                    WHERE s.src = 'mdm' AND s.action = 'INSERT' AND s.table_name = ANY(string_to_array(:bitemporal, ','))
                      AND x.change_request_id = s.change_request_id AND x.table_name = s.table_name AND x.action = 'UPDATE'
                      AND x.node_id IS NOT DISTINCT FROM s.node_id AND x.hierarchy_id IS NOT DISTINCT FROM s.hierarchy_id
                      AND x.property_id IS NOT DISTINCT FROM s.property_id AND x.audit_id < s.audit_id
                    ORDER BY x.audit_id DESC LIMIT 1) prev ON true
                  WHERE true
                """);
        if (!c.includeSuperseded()) {
            sql.append("""
                    AND NOT (s.action = 'UPDATE' AND s.table_name = ANY(string_to_array(:bitemporal, ',')))
                    AND (prev.old_row IS NULL
                         OR (s.new_row - string_to_array(:technical, ',')) IS DISTINCT FROM (prev.old_row - string_to_array(:technical, ',')))
                    """);
        }
        if (c.request() != null) {
            sql.append(" AND s.change_request_id = :request");
        }
        if (c.node() != null) {
            sql.append(" AND s.node_id = :node");
        }
        if (c.property() != null) {
            sql.append(" AND s.property_id = :property");
        }
        if (c.hierarchy() != null) {
            sql.append("""
                     AND (s.hierarchy_id = :hierarchy OR (s.hierarchy_id IS NULL AND EXISTS (
                          SELECT 1 FROM mdm.change_item ci WHERE ci.change_request_id = s.change_request_id AND ci.hierarchy_id = :hierarchy)))
                    """);
        }
        if (c.user() != null) {
            sql.append("""
                     AND (s.actor_id = :user OR EXISTS (SELECT 1 FROM mdm.change_request cr WHERE cr.change_request_id = s.change_request_id
                                                         AND (cr.requester_id = :user OR cr.decided_by = :user)))
                    """);
        }
        if (!c.admin()) {
            // §18.5: data rows written by a request; a row's own hierarchy must be readable, and a row without one (a node's
            // name, a global value) only when every hierarchy its request touched is readable
            sql.append(" AND s.change_request_id IS NOT NULL");
            if (c.readable() != null) {
                sql.append("""
                         AND (s.hierarchy_id = ANY(string_to_array(:readable, ',')::uuid[])
                              OR (s.hierarchy_id IS NULL
                                  AND EXISTS (SELECT 1 FROM mdm.change_item ci WHERE ci.change_request_id = s.change_request_id)
                                  AND NOT EXISTS (SELECT 1 FROM mdm.change_item ci WHERE ci.change_request_id = s.change_request_id
                                                  AND (ci.hierarchy_id IS NULL OR ci.hierarchy_id <> ALL(string_to_array(:readable, ',')::uuid[])))))
                        """);
            }
        }
        if (c.cursorAt() != null) {
            sql.append(" AND (s.occurred_at, s.src, s.audit_id) < (CAST(:cursorAt AS timestamptz), CAST(:cursorSource AS text), CAST(:cursorId AS bigint))");
        }
        sql.append("""
                  ORDER BY s.occurred_at DESC, s.src DESC, s.audit_id DESC
                  LIMIT :limit
                )
                SELECT p.src, p.audit_id, p.occurred_at, p.table_name, p.action, p.old_row::text AS old_row, p.new_row::text AS new_row,
                       p.before_row::text AS before_row, p.node_id, p.change_request_id,
                       lower((coalesce(p.new_row, p.old_row) ->> 'valid_period')::daterange) AS valid_from,
                       upper((coalesce(p.new_row, p.old_row) ->> 'valid_period')::daterange) AS valid_to,
                       (SELECT na.node_name FROM mdm.node_attr na WHERE na.node_id = p.node_id AND upper_inf(na.recorded_period)
                        ORDER BY upper_inf(na.valid_period) DESC, lower(na.valid_period) DESC LIMIT 1) AS node_name,
                       (SELECT na.node_name FROM mdm.node_attr na WHERE na.node_id = (p.new_row ->> 'parent_node_id')::uuid
                          AND upper_inf(na.recorded_period) ORDER BY upper_inf(na.valid_period) DESC LIMIT 1) AS parent_after,
                       (SELECT na.node_name FROM mdm.node_attr na
                        WHERE na.node_id = (coalesce(p.before_row, p.old_row) ->> 'parent_node_id')::uuid
                          AND upper_inf(na.recorded_period) ORDER BY upper_inf(na.valid_period) DESC LIMIT 1) AS parent_before,
                       h.hierarchy_code, pd.property_code, pd.label AS property_label,
                       cr.title AS request_title, cr.decision_basis::text AS decision_basis,
                       coalesce(ru.display_name, ru.login) AS requested_by, coalesce(du.display_name, du.login) AS decided_by,
                       coalesce(au.display_name, au.login) AS actor
                FROM picked p
                LEFT JOIN mdm.hierarchy h ON h.hierarchy_id = p.hierarchy_id
                LEFT JOIN mdm.property_definition pd ON pd.property_id = p.property_id
                LEFT JOIN mdm.change_request cr ON cr.change_request_id = p.change_request_id
                LEFT JOIN mdm.app_user ru ON ru.user_id = cr.requester_id
                LEFT JOIN mdm.app_user du ON du.user_id = cr.decided_by
                LEFT JOIN mdm.app_user au ON au.user_id = p.actor_id
                ORDER BY p.occurred_at DESC, p.src DESC, p.audit_id DESC
                """);

        JdbcClient.StatementSpec spec = jdbc.sql(sql.toString())
                .param("tables", String.join(",", mdmTables.isEmpty() ? Set.of("-") : mdmTables))
                .param("bitemporal", String.join(",", BITEMPORAL))
                .param("technical", String.join(",", TECHNICAL))
                .param("from", Timestamp.from(c.from())).param("to", Timestamp.from(c.to()))
                .param("limit", c.limit() + 1);
        if (c.request() != null) spec = spec.param("request", c.request());
        if (c.node() != null) spec = spec.param("node", c.node());
        if (c.property() != null) spec = spec.param("property", c.property());
        if (c.hierarchy() != null) spec = spec.param("hierarchy", c.hierarchy());
        if (c.user() != null) spec = spec.param("user", c.user());
        if (!c.admin() && c.readable() != null) {
            spec = spec.param("readable", c.readable().isEmpty() ? "00000000-0000-0000-0000-000000000000"
                    : c.readable().stream().map(UUID::toString).collect(Collectors.joining(",")));
        }
        if (c.cursorAt() != null) {
            spec = spec.param("cursorAt", Timestamp.from(c.cursorAt())).param("cursorSource", c.cursorSource()).param("cursorId", c.cursorId());
        }
        return spec.query((rs, i) -> row(rs)).list();
    }

    private Row row(ResultSet rs) throws SQLException {
        String source = rs.getString("src");
        String table = rs.getString("table_name");
        String op = rs.getString("action");
        JsonNode oldRow = json(rs.getString("old_row"));
        JsonNode newRow = json(rs.getString("new_row"));
        JsonNode beforeRow = json(rs.getString("before_row"));
        String category = "wf".equals(source) ? "configuration" : categoryOf(table);

        String kind;
        JsonNode before;
        JsonNode after;
        if (!"wf".equals(source) && BITEMPORAL.contains(table)) {
            if ("UPDATE".equals(op)) {
                kind = "superseded";
                before = meaningful(oldRow, rs.getString("parent_before"));
                after = null;
            } else {
                before = meaningful(beforeRow, rs.getString("parent_before"));
                after = meaningful(newRow, rs.getString("parent_after"));
                kind = before != null && before.equals(after) ? "restated" : "stated";
            }
        } else {
            kind = switch (op) {
                case "INSERT" -> "created";
                case "DELETE" -> "deleted";
                default -> "updated";
            };
            before = meaningful(oldRow, null);
            after = meaningful(newRow, null);
        }
        Timestamp at = rs.getTimestamp("occurred_at");
        AuditEntry entry = new AuditEntry(source + ":" + rs.getLong("audit_id"), at.toInstant(), category, kind, table, op,
                rs.getObject("node_id", UUID.class), rs.getString("node_name"), rs.getString("hierarchy_code"),
                rs.getString("property_code"), rs.getString("property_label"),
                rs.getObject("valid_from", LocalDate.class), rs.getObject("valid_to", LocalDate.class),
                before, after, changed(before, after),
                rs.getObject("change_request_id", UUID.class), rs.getString("request_title"), rs.getString("requested_by"),
                rs.getString("decided_by"), rs.getString("decision_basis"), rs.getString("actor"));
        return new Row(entry, at.toInstant(), source, rs.getLong("audit_id"));
    }

    static String categoryOf(String table) {
        return CATEGORIES.entrySet().stream().filter(e -> e.getValue().contains(table)).map(Map.Entry::getKey).findFirst().orElse("data");
    }

    /** The row without technical and subject columns, plus the parent's name for a placement; null for no row. */
    private JsonNode meaningful(JsonNode row, String parentName) {
        if (row == null || !row.isObject()) {
            return null;
        }
        ObjectNode copy = ((ObjectNode) row).deepCopy();
        TECHNICAL.forEach(copy::remove);
        SUBJECT.forEach(copy::remove);
        if (parentName != null && copy.has("parent_node_id")) {
            copy.put("parent_name", parentName);
        }
        return copy;
    }

    /** Fields whose value differs between before and after (both present), in the after row's order. */
    private static List<String> changed(JsonNode before, JsonNode after) {
        if (before == null || after == null) {
            return List.of();
        }
        Map<String, Boolean> keys = new LinkedHashMap<>();
        for (Iterator<String> it = after.fieldNames(); it.hasNext(); ) {
            keys.put(it.next(), true);
        }
        for (Iterator<String> it = before.fieldNames(); it.hasNext(); ) {
            keys.putIfAbsent(it.next(), true);
        }
        List<String> out = new ArrayList<>();
        for (String k : keys.keySet()) {
            if (!java.util.Objects.equals(before.get(k), after.get(k)) && !"parent_name".equals(k)) {
                out.add(k);
            }
        }
        return out;
    }

    private JsonNode json(String s) {
        if (s == null) {
            return null;
        }
        try {
            return mapper.readTree(s);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }
}
