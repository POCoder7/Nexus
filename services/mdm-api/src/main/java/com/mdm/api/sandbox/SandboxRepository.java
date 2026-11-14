package com.mdm.api.sandbox;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.sandbox.SandboxDtos.Conflict;
import com.mdm.api.sandbox.SandboxDtos.DiffRow;
import com.mdm.api.sandbox.SandboxDtos.ItemFailure;
import com.mdm.api.sandbox.SandboxDtos.SandboxChild;
import com.mdm.api.sandbox.SandboxDtos.SandboxNode;
import com.mdm.api.sandbox.SandboxDtos.SandboxPlacement;
import com.mdm.api.sandbox.SandboxDtos.SandboxProperty;
import com.mdm.api.sandbox.SandboxDtos.SandboxView;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * SQL for sandboxes (NEW-08). The overlay is computed, refreshed and read by the V12 functions; the API never writes the
 * delta tables or a request's kind or base itself (ADR-014, ADR-019).
 */
@Repository
public class SandboxRepository {

    private static final String SELECT_SANDBOX = """
            SELECT cr.change_request_id, cr.sandbox_name, v.version_name, cr.kind, cr.status::text AS status, cr.requester_id,
                   cr.effective_from, cr.sandbox_base_recorded_at, cr.created_at, cr.row_version,
                   (SELECT count(*) FROM mdm.change_item ci WHERE ci.change_request_id = cr.change_request_id) AS item_count
            FROM mdm.change_request cr
            JOIN mdm.version v ON v.version_id = cr.version_id
            WHERE cr.origin = 'sandbox'
            """;

    private final JdbcClient jdbc;
    private final ObjectMapper mapper;
    private final RowMapper<SandboxView> sandboxMapper;
    private final RowMapper<ItemFailure> failureMapper;

    public SandboxRepository(JdbcClient jdbc, ObjectMapper mapper) {
        this.jdbc = jdbc;
        this.mapper = mapper;
        this.sandboxMapper = (rs, i) -> new SandboxView(
                rs.getObject("change_request_id", UUID.class), rs.getString("sandbox_name"), rs.getString("version_name"),
                rs.getString("kind"), rs.getString("status"), rs.getObject("requester_id", UUID.class),
                rs.getObject("effective_from", LocalDate.class), instant(rs.getTimestamp("sandbox_base_recorded_at")),
                instant(rs.getTimestamp("created_at")), rs.getInt("item_count"), null, rs.getInt("row_version"));
        this.failureMapper = (rs, i) -> new ItemFailure(rs.getInt("seq"), rs.getObject("change_item_id", UUID.class),
                rs.getString("error_code"), rs.getString("message"), json(rs.getString("detail")));
    }

    public UUID insert(UUID versionId, String name, UUID ownerId, String ownerKind, LocalDate effectiveFrom) {
        return jdbc.sql("""
                INSERT INTO mdm.change_request (version_id, title, requester_id, requester_kind, effective_from, origin, kind,
                                                sandbox_name, sandbox_base_recorded_at)
                VALUES (:version, :name, :owner, CAST(:kind AS mdm.requester_kind), :from, 'sandbox', 'sandbox', :name, now())
                RETURNING change_request_id
                """)
                .param("version", versionId).param("name", name).param("owner", ownerId).param("kind", ownerKind)
                .param("from", effectiveFrom)
                .query(UUID.class).single();
    }

    /**
     * Serialises sandbox creation per owner for the rest of the transaction, so two concurrent creates cannot both pass
     * the active-sandbox limit.
     */
    public void lockOwner(UUID ownerId) {
        jdbc.sql("SELECT pg_advisory_xact_lock(hashtext('nexus.sandbox.' || CAST(:owner AS text)))").param("owner", ownerId)
                .query((rs, i) -> 0).single();
    }

    public int activeCount(UUID ownerId) {
        return jdbc.sql("""
                SELECT count(*) FROM mdm.change_request
                WHERE requester_id = :owner AND kind = 'sandbox' AND status = 'draft'
                """).param("owner", ownerId).query(Integer.class).single();
    }

    public int maxActivePerUser() {
        return jdbc.sql("SELECT coalesce(max(setting_value::int), 5) FROM mdm.system_setting WHERE setting_key = 'sandbox_max_active_per_user'")
                .query(Integer.class).single();
    }

    public Optional<SandboxView> find(UUID id) {
        return jdbc.sql(SELECT_SANDBOX + " AND cr.change_request_id = :id").param("id", id).query(sandboxMapper).optional();
    }

    /** Locks the row for the rest of the transaction; edits of one sandbox are serialised (LLD §6.2). */
    public Optional<SandboxView> lock(UUID id) {
        return jdbc.sql(SELECT_SANDBOX + " AND cr.change_request_id = :id FOR UPDATE OF cr").param("id", id)
                .query(sandboxMapper).optional();
    }

    /** The owner's sandboxes in a status (open = draft), newest first. Requests a sandbox became are not listed. */
    public List<SandboxView> mine(UUID ownerId, String status, Instant afterCreated, UUID afterId, int limit) {
        return jdbc.sql(SELECT_SANDBOX + """
                  AND cr.requester_id = :owner AND cr.kind = 'sandbox' AND cr.status::text = :status
                  AND (CAST(:afterCreated AS timestamptz) IS NULL
                       OR (cr.created_at, cr.change_request_id) < (CAST(:afterCreated AS timestamptz), CAST(:afterId AS uuid)))
                ORDER BY cr.created_at DESC, cr.change_request_id DESC
                LIMIT :limit
                """)
                .param("owner", ownerId).param("status", status)
                .param("afterCreated", afterCreated == null ? null : Timestamp.from(afterCreated)).param("afterId", afterId)
                .param("limit", limit + 1)
                .query(sandboxMapper).list();
    }

    public List<UUID> itemHierarchies(UUID sandboxId) {
        return jdbc.sql("SELECT DISTINCT hierarchy_id FROM mdm.change_item WHERE change_request_id = :s AND hierarchy_id IS NOT NULL")
                .param("s", sandboxId).query(UUID.class).list();
    }

    // ------------------------------------------------------------------ the overlay (V12 functions)

    /** Rebuilds the overlay; {@code newItem} names an item just added, which may let a large sandbox refresh incrementally. */
    public List<ItemFailure> refresh(UUID sandboxId, UUID newItem) {
        return jdbc.sql("""
                SELECT seq, change_item_id, error_code, message, detail::text AS detail
                FROM mdm.refresh_sandbox_delta(:s, CAST(:item AS uuid))
                """).param("s", sandboxId).param("item", newItem).query(failureMapper).list();
    }

    public List<ItemFailure> rebase(UUID sandboxId, UUID actorId) {
        return jdbc.sql("""
                SELECT seq, change_item_id, error_code, message, detail::text AS detail FROM mdm.rebase_sandbox(:s, :actor)
                """).param("s", sandboxId).param("actor", actorId).query(failureMapper).list();
    }

    public List<Conflict> conflicts(UUID sandboxId) {
        return jdbc.sql("""
                SELECT seq, change_item_id, action, field, expected::text AS expected, actual::text AS actual,
                       changed_by_request, changed_at
                FROM mdm.sandbox_conflicts(:s)
                """).param("s", sandboxId)
                .query((rs, i) -> new Conflict(rs.getInt("seq"), rs.getObject("change_item_id", UUID.class),
                        rs.getString("action"), rs.getString("field"), json(rs.getString("expected")),
                        json(rs.getString("actual")), rs.getObject("changed_by_request", UUID.class),
                        instant(rs.getTimestamp("changed_at"))))
                .list();
    }

    public void convert(UUID sandboxId, UUID actorId) {
        jdbc.sql("SELECT mdm.convert_sandbox(:s, :actor)").param("s", sandboxId).param("actor", actorId)
                .query((rs, i) -> 0).single();
    }

    public void discard(UUID sandboxId, UUID actorId) {
        jdbc.sql("SELECT mdm.discard_sandbox(:s, :actor)").param("s", sandboxId).param("actor", actorId)
                .query((rs, i) -> 0).single();
    }

    // ------------------------------------------------------------------ overlay reads

    /** One page of children ({@code limit + 1} rows), keyset (sort order, name, node id) as the Phase 1 children page. */
    public List<SandboxChild> children(UUID sandboxId, UUID hierarchyId, UUID parentId, LocalDate asOf, List<String> after,
                                       int limit) {
        return jdbc.sql("""
                SELECT child_node_id, node_name, description, is_active, is_primary, sort_order, has_children, changed
                FROM mdm.sandbox_children(:s, :h, :p, CAST(:asOf AS date), CAST(:afterSort AS numeric),
                                          CAST(:afterName AS text), CAST(:afterId AS uuid), :limit)
                """)
                .param("s", sandboxId).param("h", hierarchyId).param("p", parentId).param("asOf", asOf)
                .param("afterSort", after == null ? null : new BigDecimal(after.get(0)))
                .param("afterName", after == null ? null : after.get(1))
                .param("afterId", after == null ? null : UUID.fromString(after.get(2)))
                .param("limit", limit + 1)
                .query((rs, i) -> new SandboxChild(rs.getObject("child_node_id", UUID.class), rs.getString("node_name"),
                        rs.getString("description"), rs.getBoolean("is_active"), rs.getBoolean("is_primary"),
                        rs.getBigDecimal("sort_order"), rs.getBoolean("has_children"), rs.getBoolean("changed")))
                .list();
    }

    /** Node detail in the overlay; empty when the node identity does not exist. */
    public Optional<SandboxNode> node(UUID sandboxId, UUID nodeId, UUID hierarchyId, LocalDate asOf) {
        return jdbc.sql("""
                SELECT n.node_id, n.node_kind::text AS node_kind, a.node_name, a.description,
                       coalesce(a.is_active, false) AS is_active, coalesce(a.allows_children, false) AS allows_children,
                       coalesce(a.changed, false) AS changed
                FROM mdm.node n
                LEFT JOIN LATERAL mdm.sandbox_node(:s, n.node_id, CAST(:asOf AS date)) a ON true
                WHERE n.node_id = :n
                """)
                .param("s", sandboxId).param("n", nodeId).param("asOf", asOf)
                .query((rs, i) -> new SandboxNode(rs.getObject("node_id", UUID.class), rs.getString("node_kind"),
                        rs.getString("node_name"), rs.getString("description"), rs.getBoolean("is_active"),
                        rs.getBoolean("allows_children"), rs.getBoolean("changed"),
                        hierarchyId == null ? List.of() : placements(sandboxId, hierarchyId, nodeId, asOf),
                        properties(sandboxId, nodeId, hierarchyId, asOf)))
                .optional();
    }

    private List<SandboxPlacement> placements(UUID sandboxId, UUID hierarchyId, UUID nodeId, LocalDate asOf) {
        return jdbc.sql("SELECT parent_node_id, is_primary, sort_order, changed FROM mdm.sandbox_placements(:s, :h, :n, CAST(:asOf AS date))")
                .param("s", sandboxId).param("h", hierarchyId).param("n", nodeId).param("asOf", asOf)
                .query((rs, i) -> new SandboxPlacement(rs.getObject("parent_node_id", UUID.class), rs.getBoolean("is_primary"),
                        rs.getBigDecimal("sort_order"), rs.getBoolean("changed")))
                .list();
    }

    /** Resolved properties over the overlay, in the order the Phase 1 node panel shows them. */
    private List<SandboxProperty> properties(UUID sandboxId, UUID nodeId, UUID hierarchyId, LocalDate asOf) {
        return jdbc.sql("""
                SELECT pd.property_code, pd.label, pd.data_type::text AS data_type, pd.scope::text AS scope, pd.category_code,
                       x.value::text AS value, x.provenance, x.source_node_id, x.changed
                FROM mdm.sandbox_node_properties(:s, :n, CAST(:h AS uuid), CAST(:asOf AS date)) x
                JOIN mdm.property_definition pd ON pd.property_id = x.property_id
                ORDER BY pd.category_code NULLS LAST, pd.label
                """)
                .param("s", sandboxId).param("n", nodeId).param("h", hierarchyId).param("asOf", asOf)
                .query((rs, i) -> new SandboxProperty(rs.getString("property_code"), rs.getString("label"),
                        rs.getString("data_type"), rs.getString("scope"), json(rs.getString("value")),
                        rs.getString("provenance"), rs.getObject("source_node_id", UUID.class),
                        rs.getString("category_code"), rs.getBoolean("changed")))
                .list();
    }

    /** A diff row with the key it is paged by. */
    public record KeyedDiff(String key, DiffRow row) {
    }

    /**
     * The overlay rows, grouped by node: each fact as it was in the base and is replaced (before), and as the sandbox
     * writes it (after). Keyset on a text key ({@code limit + 1} rows).
     */
    public List<KeyedDiff> diff(UUID sandboxId, String afterKey, int limit) {
        return jdbc.sql("""
                SELECT * FROM (
                  SELECT 'placement' AS fact, d.op, d.child_node_id AS node_id, h.hierarchy_code, d.parent_node_id,
                         NULL::text AS property_code, d.valid_period,
                         jsonb_build_object('primary', d.is_primary, 'sortOrder', d.sort_order)::text AS vals,
                         concat_ws('|', d.child_node_id::text, '1', d.hierarchy_id::text, d.parent_node_id::text,
                                   coalesce(lower(d.valid_period)::text, ''), d.op) AS k
                  FROM mdm.sandbox_delta_relationship d LEFT JOIN mdm.hierarchy h ON h.hierarchy_id = d.hierarchy_id
                  WHERE d.sandbox_id = :s
                  UNION ALL
                  SELECT 'attributes', d.op, d.node_id, NULL, NULL, NULL, d.valid_period,
                         jsonb_build_object('name', d.node_name, 'description', d.description, 'active', d.is_active,
                                            'allowsChildren', d.allows_children)::text,
                         concat_ws('|', d.node_id::text, '2', coalesce(lower(d.valid_period)::text, ''), d.op)
                  FROM mdm.sandbox_delta_node_attr d
                  WHERE d.sandbox_id = :s
                  UNION ALL
                  SELECT 'value', d.op, d.node_id, h.hierarchy_code, NULL, pd.property_code, d.valid_period,
                         jsonb_build_object('value', d.value)::text,
                         concat_ws('|', d.node_id::text, '3', d.property_id::text, d.hierarchy_key::text,
                                   coalesce(lower(d.valid_period)::text, ''), d.op)
                  FROM mdm.sandbox_delta_value d
                  JOIN mdm.property_definition pd ON pd.property_id = d.property_id
                  LEFT JOIN mdm.hierarchy h ON h.hierarchy_id = d.hierarchy_key
                  WHERE d.sandbox_id = :s
                ) x
                WHERE CAST(:after AS text) IS NULL OR x.k COLLATE "C" > CAST(:after AS text) COLLATE "C"
                ORDER BY x.k COLLATE "C"
                LIMIT :limit
                """)
                .param("s", sandboxId).param("after", afterKey).param("limit", limit + 1)
                .query((rs, i) -> new KeyedDiff(rs.getString("k"), new DiffRow(rs.getString("fact"),
                        "+".equals(rs.getString("op")) ? "after" : "before", rs.getObject("node_id", UUID.class),
                        rs.getString("hierarchy_code"), rs.getObject("parent_node_id", UUID.class),
                        rs.getString("property_code"), lowerOf(rs.getObject("valid_period")), upperOf(rs.getObject("valid_period")),
                        json(rs.getString("vals")))))
                .list();
    }

    // ------------------------------------------------------------------ helpers

    /** A PostgreSQL daterange in canonical form, {@code [a,b)}; either bound may be empty (infinite). */
    private static LocalDate lowerOf(Object range) {
        String[] b = bounds(range);
        return b[0].isEmpty() ? null : LocalDate.parse(b[0]);
    }

    private static LocalDate upperOf(Object range) {
        String[] b = bounds(range);
        return b[1].isEmpty() ? null : LocalDate.parse(b[1]);
    }

    private static String[] bounds(Object range) {
        String s = range.toString();
        String inner = s.substring(1, s.length() - 1);
        int comma = inner.indexOf(',');
        return new String[] {inner.substring(0, comma).trim(), inner.substring(comma + 1).trim()};
    }

    private static Instant instant(Timestamp t) {
        return t == null ? null : t.toInstant();
    }

    private JsonNode json(String s) {
        try {
            return s == null ? null : mapper.readTree(s);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Invalid JSON from the sandbox functions", e);
        }
    }
}
