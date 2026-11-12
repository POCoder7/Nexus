package com.mdm.api.node;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.common.BusinessClock;
import com.mdm.api.common.Cursors;
import com.mdm.api.common.NotFoundException;
import com.mdm.api.common.Page;
import com.mdm.api.common.Slice;
import com.mdm.api.hierarchy.HierarchyRepository;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * Read-only views on one node for the node panel (Phase 3 second scope extension):
 * <ul>
 *   <li>{@code /history} (QRY-04): every version of its attributes, its placements and its property values, with valid and
 *       recorded periods and the change request that wrote them, newest recorded first, keyset-paged;</li>
 *   <li>{@code /owners} and {@code /holdings} (NEW-02, view only): direct ownership edges at a slice, paged. No path
 *       calculation here: effective ownership and UBO results are Phase 6.</li>
 * </ul>
 * The caller must be able to read a hierarchy that contains the node (as {@code GET /nodes/{id}}); placements are listed
 * only for hierarchies the caller can read.
 */
@RestController
@RequestMapping("/api/v1/nodes")
public class NodeHistoryController {

    public static final int MAX_LIMIT = 200;

    /** {@code kind}: attribute | placement | property. Fields not relevant to the kind are null. */
    public record HistoryEvent(String kind, LocalDate validFrom, LocalDate validTo, Instant recordedFrom, Instant recordedTo,
                               UUID changeRequestId, String changeRequestTitle,
                               String name, String description, Boolean active, Boolean allowsChildren,
                               String hierarchyCode, UUID parentId, String parentName, Boolean primary,
                               String propertyCode, String propertyLabel, JsonNode value) {
    }

    /** One direct ownership edge, seen from the node: {@code otherNodeId} is the owner (owners) or the owned entity (holdings). */
    public record OwnershipEdge(UUID edgeId, UUID otherNodeId, String otherName, String otherKind, String relation, String shareClass,
                                BigDecimal economicPct, BigDecimal votingPct, boolean direct, UUID nomineeForNodeId,
                                String source, BigDecimal confidence, LocalDate validFrom) {
    }

    private final JdbcClient jdbc;
    private final ObjectMapper mapper;
    private final NodeRepository nodes;
    private final HierarchyRepository hierarchies;
    private final EntitlementService entitlements;
    private final BusinessClock clock;
    private final Cursors cursors;

    public NodeHistoryController(JdbcClient jdbc, ObjectMapper mapper, NodeRepository nodes, HierarchyRepository hierarchies,
                                 EntitlementService entitlements, BusinessClock clock, Cursors cursors) {
        this.jdbc = jdbc;
        this.mapper = mapper;
        this.nodes = nodes;
        this.hierarchies = hierarchies;
        this.entitlements = entitlements;
        this.clock = clock;
        this.cursors = cursors;
    }

    @GetMapping("/{nodeId}/history")
    public Page<HistoryEvent> getNodeHistory(Actor actor, @PathVariable UUID nodeId,
                                             @RequestParam(required = false) String hierarchy,
                                             @RequestParam(defaultValue = "50") int limit,
                                             @RequestParam(required = false) String cursor) {
        checkLimit(limit);
        String[] readable = readableHierarchyIds(actor, nodeId, hierarchy);
        List<String> after = cursors.decode(cursor, 2);
        // one list of every fact row about the node; key = kind + its natural key, unique per recorded version
        List<KeyedEvent> rows = jdbc.sql("""
                WITH ev AS (
                  SELECT 'attribute' AS kind, lower(a.valid_period) AS vf, upper(a.valid_period) AS vt,
                         lower(a.recorded_period) AS rf, upper(a.recorded_period) AS rt, a.change_request_id AS cr,
                         a.node_name AS name, a.description, a.is_active AS active, a.allows_children,
                         NULL::text AS hcode, NULL::uuid AS parent_id, NULL::text AS parent_name, NULL::boolean AS is_primary,
                         NULL::text AS pcode, NULL::text AS plabel, NULL::text AS value,
                         'a:' || lower(a.valid_period)::text AS k
                  FROM mdm.node_attr a WHERE a.node_id = :n
                  UNION ALL
                  SELECT 'placement', lower(r.valid_period), upper(r.valid_period), lower(r.recorded_period), upper(r.recorded_period),
                         r.change_request_id, NULL, NULL, NULL, NULL, h.hierarchy_code, r.parent_node_id,
                         (SELECT pa.node_name FROM mdm.node_attr pa WHERE pa.node_id = r.parent_node_id AND upper_inf(pa.recorded_period)
                          ORDER BY lower(pa.valid_period) DESC LIMIT 1),
                         r.is_primary, NULL, NULL, NULL,
                         'r:' || h.hierarchy_code || ':' || r.parent_node_id::text || ':' || lower(r.valid_period)::text
                  FROM mdm.hierarchy_relationship r JOIN mdm.hierarchy h ON h.hierarchy_id = r.hierarchy_id
                  WHERE r.child_node_id = :n AND (CAST(:ids AS text[]) IS NULL OR r.hierarchy_id::text = ANY (CAST(:ids AS text[])))
                  UNION ALL
                  SELECT 'property', lower(v.valid_period), upper(v.valid_period), lower(v.recorded_period), upper(v.recorded_period),
                         v.change_request_id, NULL, NULL, NULL, NULL, vh.hierarchy_code, NULL, NULL, NULL,
                         d.property_code, d.label, v.value::text,
                         'p:' || d.property_code || ':' || coalesce(vh.hierarchy_code, '') || ':' || lower(v.valid_period)::text
                  FROM mdm.property_value v JOIN mdm.property_definition d ON d.property_id = v.property_id
                  LEFT JOIN mdm.hierarchy vh ON vh.hierarchy_id = v.hierarchy_id
                  WHERE v.node_id = :n
                    AND (v.hierarchy_id IS NULL OR CAST(:ids AS text[]) IS NULL OR v.hierarchy_id::text = ANY (CAST(:ids AS text[])))
                )
                SELECT ev.*, cr.title AS cr_title FROM ev LEFT JOIN mdm.change_request cr ON cr.change_request_id = ev.cr
                WHERE CAST(:afterRf AS timestamptz) IS NULL OR (ev.rf, ev.k) < (CAST(:afterRf AS timestamptz), CAST(:afterK AS text))
                ORDER BY ev.rf DESC, ev.k DESC
                LIMIT :limit
                """)
                .param("n", nodeId).param("ids", readable)
                .param("afterRf", after == null ? null : after.get(0)).param("afterK", after == null ? null : after.get(1))
                .param("limit", limit + 1)
                .query((rs, i) -> new KeyedEvent(new HistoryEvent(rs.getString("kind"), rs.getObject("vf", LocalDate.class),
                        rs.getObject("vt", LocalDate.class), instant(rs.getTimestamp("rf")), instant(rs.getTimestamp("rt")),
                        rs.getObject("cr", UUID.class), rs.getString("cr_title"), rs.getString("name"), rs.getString("description"),
                        (Boolean) rs.getObject("active"), (Boolean) rs.getObject("allows_children"), rs.getString("hcode"),
                        rs.getObject("parent_id", UUID.class), rs.getString("parent_name"), (Boolean) rs.getObject("is_primary"),
                        rs.getString("pcode"), rs.getString("plabel"), json(rs.getString("value"))),
                        rs.getTimestamp("rf").toInstant().toString(), rs.getString("k")))
                .list();
        // the cursor carries the last row's (recorded from, key); the extra fetched row only says "there is more"
        Page<KeyedEvent> page = Page.of(rows, limit, k -> cursors.encode(k.rf(), k.key()));
        return new Page<>(page.items().stream().map(KeyedEvent::event).toList(), page.nextCursor());
    }

    @GetMapping("/{nodeId}/owners")
    public Page<OwnershipEdge> listNodeOwners(Actor actor, @PathVariable UUID nodeId,
                                              @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf,
                                              @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant recordedAsOf,
                                              @RequestParam(defaultValue = "50") int limit,
                                              @RequestParam(required = false) String cursor) {
        return edges(actor, nodeId, true, Slice.of(asOf, recordedAsOf, clock), limit, cursor);
    }

    @GetMapping("/{nodeId}/holdings")
    public Page<OwnershipEdge> listNodeHoldings(Actor actor, @PathVariable UUID nodeId,
                                                @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf,
                                                @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant recordedAsOf,
                                                @RequestParam(defaultValue = "50") int limit,
                                                @RequestParam(required = false) String cursor) {
        return edges(actor, nodeId, false, Slice.of(asOf, recordedAsOf, clock), limit, cursor);
    }

    // ------------------------------------------------------------------ helpers

    private record KeyedEvent(HistoryEvent event, String rf, String key) {
    }

    private Page<OwnershipEdge> edges(Actor actor, UUID nodeId, boolean owners, Slice slice, int limit, String cursor) {
        checkLimit(limit);
        readableHierarchyIds(actor, nodeId, null);
        List<String> after = cursors.decode(cursor, 2);
        String self = owners ? "owned_node_id" : "owner_node_id";
        String other = owners ? "owner_node_id" : "owned_node_id";
        List<OwnershipEdge> rows = jdbc.sql("""
                SELECT e.edge_id, e.%2$s AS other_id, a.node_name AS other_name, n.node_kind::text AS other_kind,
                       e.relation::text AS relation, e.share_class, e.economic_pct, e.voting_pct, e.is_direct,
                       e.nominee_for_node_id, e.source::text AS source, e.confidence, lower(e.valid_period) AS valid_from
                FROM mdm.ownership_edge e
                JOIN mdm.node n ON n.node_id = e.%2$s
                LEFT JOIN mdm.node_attr a ON a.node_id = e.%2$s AND a.valid_period @> CAST(:asOf AS date) AND %3$s
                WHERE e.%1$s = :n AND e.valid_period @> CAST(:asOf AS date) AND %4$s
                  AND (CAST(:afterName AS text) IS NULL
                       OR (coalesce(a.node_name, ''), e.edge_id) > (CAST(:afterName AS text), CAST(:afterId AS uuid)))
                ORDER BY coalesce(a.node_name, ''), e.edge_id
                LIMIT :limit
                """.formatted(self, other, slice.recorded("a"), slice.recorded("e")))
                .param("n", nodeId).param("asOf", slice.asOf()).param("rec", slice.recBind())
                .param("afterName", after == null ? null : after.get(0)).param("afterId", after == null ? null : after.get(1))
                .param("limit", limit + 1)
                .query((rs, i) -> new OwnershipEdge(rs.getObject("edge_id", UUID.class), rs.getObject("other_id", UUID.class),
                        rs.getString("other_name"), rs.getString("other_kind"), rs.getString("relation"), rs.getString("share_class"),
                        rs.getBigDecimal("economic_pct"), rs.getBigDecimal("voting_pct"), rs.getBoolean("is_direct"),
                        rs.getObject("nominee_for_node_id", UUID.class), rs.getString("source"), rs.getBigDecimal("confidence"),
                        rs.getObject("valid_from", LocalDate.class)))
                .list();
        return Page.of(rows, limit, e -> cursors.encode(e.otherName() == null ? "" : e.otherName(), e.edgeId().toString()));
    }

    /**
     * The hierarchies (ids as text) whose rows the caller may see for this node; null = every hierarchy. 404 when the caller
     * can read no hierarchy that contains the node (or the named hierarchy), so existence is not revealed.
     */
    private String[] readableHierarchyIds(Actor actor, UUID nodeId, String hierarchyCode) {
        LocalDate today = clock.today();
        if (hierarchyCode != null) {
            UUID h = hierarchies.findIdByCode(hierarchyCode).filter(id -> entitlements.canRead(actor, id))
                    .orElseThrow(() -> new NotFoundException("Hierarchy " + hierarchyCode + " not found"));
            if (!nodes.isInHierarchy(nodeId, h, today) && !everPlaced(nodeId, h)) {
                throw new NotFoundException("Node " + nodeId + " not found");
            }
            return new String[] {h.toString()};
        }
        Optional<Set<UUID>> readable = entitlements.readableHierarchies(actor);
        if (readable.isEmpty()) {
            return null;
        }
        List<UUID> containing = nodes.hierarchiesContaining(nodeId, today);
        if (containing.stream().noneMatch(readable.get()::contains)) {
            throw new NotFoundException("Node " + nodeId + " not found");
        }
        return readable.get().stream().map(UUID::toString).toArray(String[]::new);
    }

    /** A node removed from the hierarchy still has its history there. */
    private boolean everPlaced(UUID nodeId, UUID hierarchyId) {
        return jdbc.sql("""
                SELECT EXISTS (SELECT 1 FROM mdm.hierarchy_relationship WHERE child_node_id = :n AND hierarchy_id = :h)
                    OR EXISTS (SELECT 1 FROM mdm.hierarchy WHERE hierarchy_id = :h AND top_node_id = :n)
                """).param("n", nodeId).param("h", hierarchyId).query(Boolean.class).single();
    }

    private void checkLimit(int limit) {
        if (limit < 1 || limit > MAX_LIMIT) {
            throw new IllegalArgumentException("limit must be between 1 and " + MAX_LIMIT);
        }
    }

    private JsonNode json(String s) {
        try {
            return s == null ? null : mapper.readTree(s);
        } catch (java.io.IOException e) {
            throw new IllegalStateException("Invalid JSON value", e);
        }
    }

    private static Instant instant(Timestamp t) {
        return t == null ? null : t.toInstant();
    }
}
