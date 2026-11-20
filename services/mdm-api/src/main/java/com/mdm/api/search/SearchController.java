package com.mdm.api.search;

import com.mdm.api.common.BusinessClock;
import com.mdm.api.common.Cursors;
import com.mdm.api.common.ItemValidationException;
import com.mdm.api.common.Page;
import com.mdm.api.common.RuleException;
import com.mdm.api.common.Slice;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import com.mdm.api.security.Permission;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.time.LocalDate;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * Search across hierarchies (QRY-03; Phase 5 LLD §17.6, §17.6.1; ADR-045): hierarchies, nodes and requests in one call,
 * each limited to what the user can see. Nodes: one word matches name or description by substring (trigram indexes);
 * several words must all appear (full text, 'simple'); an identifier matches by exact value. Ranked identifier, exact
 * name, name prefix, then the rest, with a stable keyset order, so paging never skips or repeats a row.
 */
@RestController
@RequestMapping("/api/v1/search")
public class SearchController {

    public static final int MIN_CHARS = 2;
    private static final int MAX_LIMIT = 100;
    private static final int HIERARCHIES_MAX = 20;
    private static final Set<String> FIELDS = Set.of("name", "description", "identifier");
    private static final Set<String> TYPES = Set.of("hierarchies", "nodes", "requests");

    /** A hierarchy whose code, name or purpose contains the text. */
    public record HierarchyHit(String code, String name, String purpose) {
    }

    /**
     * A node in one hierarchy (a node placed in three hierarchies is three hits). {@code matched}: name, description or
     * identifier; {@code parentName}: its primary parent there (null for the top); {@code shared}: it also has a shared
     * placement in that hierarchy.
     */
    public record NodeHit(UUID nodeId, String name, String description, String matched, String hierarchyCode,
                          String hierarchyName, String parentName, boolean shared) {
    }

    /** A request the user can see whose title contains the text. */
    public record RequestHit(UUID id, String title, String status, String requestedBy, Instant createdAt) {
    }

    /** The groups; with {@code type}, only that group is filled and the others are null. */
    public record SearchResults(String q, List<HierarchyHit> hierarchies, Page<NodeHit> nodes, Page<RequestHit> requests) {
    }

    private final JdbcClient jdbc;
    private final EntitlementService entitlements;
    private final BusinessClock clock;
    private final Cursors cursors;

    public SearchController(JdbcClient jdbc, EntitlementService entitlements, BusinessClock clock, Cursors cursors) {
        this.jdbc = jdbc;
        this.entitlements = entitlements;
        this.clock = clock;
        this.cursors = cursors;
    }

    /**
     * {@code type}: hierarchies, nodes or requests (none = all three, first page each). {@code in}: the node fields to
     * match (name, description, identifier; default all). {@code asOf} and {@code recordedAsOf}: the slice, as every read.
     */
    @GetMapping
    public SearchResults search(Actor actor, @RequestParam String q, @RequestParam(required = false) String type,
                                @RequestParam(required = false) List<String> in,
                                @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf,
                                @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant recordedAsOf,
                                @RequestParam(required = false) String cursor, @RequestParam(defaultValue = "20") int limit) {
        String text = q == null ? "" : q.strip();
        if (text.length() < MIN_CHARS) {
            throw new RuleException("search.query_too_short", "Type at least " + MIN_CHARS + " characters to search.");
        }
        if (text.length() > 100) {
            throw ItemValidationException.field("q", "must be at most 100 characters");
        }
        if (limit < 1 || limit > MAX_LIMIT) {
            throw ItemValidationException.field("limit", "must be between 1 and " + MAX_LIMIT);
        }
        if (type != null && !TYPES.contains(type)) {
            throw ItemValidationException.field("type", "must be one of hierarchies, nodes, requests");
        }
        Set<String> fields = in == null || in.isEmpty() ? FIELDS : new LinkedHashSet<>(in);
        if (!FIELDS.containsAll(fields)) {
            throw ItemValidationException.field("in", "must be among name, description, identifier");
        }
        if (type == null && cursor != null) {
            throw ItemValidationException.field("cursor", "needs a type: a cursor pages one group");
        }
        Slice slice = Slice.of(asOf, recordedAsOf, clock);
        Optional<Set<UUID>> readable = entitlements.readableHierarchies(actor);
        String ids = readable.map(s -> s.isEmpty() ? "00000000-0000-0000-0000-000000000000"
                : s.stream().map(UUID::toString).collect(Collectors.joining(","))).orElse(null);
        boolean admin = entitlements.hasAny(actor, Permission.ADMIN_SYSTEM);

        List<HierarchyHit> hierarchies = type == null || "hierarchies".equals(type) ? hierarchies(text, ids) : null;
        Page<NodeHit> nodes = type == null || "nodes".equals(type)
                ? nodes(text, fields, slice, ids, "nodes".equals(type) ? cursors.decode(cursor, 4) : null, limit) : null;
        Page<RequestHit> requests = type == null || "requests".equals(type)
                ? requests(actor, admin, text, ids, "requests".equals(type) ? cursors.decode(cursor, 2) : null, type == null ? Math.min(limit, 5) : limit)
                : null;
        return new SearchResults(text, hierarchies, nodes, requests);
    }

    private List<HierarchyHit> hierarchies(String text, String ids) {
        return jdbc.sql("""
                SELECT h.hierarchy_code, h.hierarchy_name, h.purpose
                FROM mdm.hierarchy h
                WHERE h.is_active
                  AND (CAST(:ids AS text) IS NULL OR h.hierarchy_id = ANY(string_to_array(CAST(:ids AS text), ',')::uuid[]))
                  AND (h.hierarchy_code ILIKE :like OR h.hierarchy_name ILIKE :like OR coalesce(h.purpose, '') ILIKE :like)
                ORDER BY lower(h.hierarchy_code) = lower(:q) DESC, h.hierarchy_name, h.hierarchy_code
                LIMIT :max
                """).param("ids", ids).param("like", like(text)).param("q", text).param("max", HIERARCHIES_MAX)
                .query((rs, i) -> new HierarchyHit(rs.getString(1), rs.getString(2), rs.getString(3))).list();
    }

    private Page<NodeHit> nodes(String text, Set<String> fields, Slice slice, String ids, List<String> after, int limit) {
        String[] words = text.split("\\s+");
        boolean several = words.length > 1;
        StringBuilder match = new StringBuilder("false");
        if (several) {
            // every word must appear (full text, 'simple': no stemming); names and descriptions together
            if (fields.contains("name") || fields.contains("description")) {
                match.append(" OR to_tsvector('simple', a.node_name || ' ' || coalesce(a.description, '')) @@ plainto_tsquery('simple', :q)");
            }
        } else {
            if (fields.contains("name")) match.append(" OR a.node_name ILIKE :like");
            if (fields.contains("description")) match.append(" OR a.description ILIKE :like");
        }
        String identifiers = fields.contains("identifier") ? """
                  UNION ALL
                  SELECT i.node_id, a.node_name, a.description, 0 AS rank, 'identifier' AS matched
                  FROM mdm.node_identifier i
                  JOIN mdm.node_attr a ON a.node_id = i.node_id AND a.valid_period @> CAST(:on AS date) AND %s
                  WHERE lower(i.identifier_value) = lower(:q) AND i.valid_period @> CAST(:on AS date) AND %s
                """.formatted(slice.recorded("a"), slice.recorded("i")) : "";
        String sql = """
                WITH matched AS (
                  SELECT a.node_id, a.node_name, a.description,
                         CASE WHEN lower(a.node_name) = lower(:q) THEN 1 WHEN lower(a.node_name) LIKE :prefix THEN 2 ELSE 3 END AS rank,
                         CASE WHEN a.node_name ILIKE :like THEN 'name' ELSE 'description' END AS matched
                  FROM mdm.node_attr a
                  WHERE a.valid_period @> CAST(:on AS date) AND %s AND (%s)
                  %s
                ),
                best AS (SELECT DISTINCT ON (m.node_id) m.* FROM matched m ORDER BY m.node_id, m.rank),
                placed AS (
                  SELECT b.*, h.hierarchy_id, h.hierarchy_code, h.hierarchy_name
                  FROM best b
                  JOIN mdm.hierarchy h ON h.is_active
                   AND (CAST(:ids AS text) IS NULL OR h.hierarchy_id = ANY(string_to_array(CAST(:ids AS text), ',')::uuid[]))
                  WHERE h.top_node_id = b.node_id
                     OR EXISTS (SELECT 1 FROM mdm.hierarchy_relationship r WHERE r.hierarchy_id = h.hierarchy_id
                                AND r.child_node_id = b.node_id AND r.valid_period @> CAST(:on AS date) AND %s)
                )
                SELECT p.node_id, p.node_name, p.description, p.matched, p.hierarchy_code, p.hierarchy_name, p.rank,
                       (SELECT pa.node_name FROM mdm.hierarchy_relationship r
                        JOIN mdm.node_attr pa ON pa.node_id = r.parent_node_id AND pa.valid_period @> CAST(:on AS date) AND %s
                        WHERE r.hierarchy_id = p.hierarchy_id AND r.child_node_id = p.node_id AND r.is_primary
                          AND r.valid_period @> CAST(:on AS date) AND %s LIMIT 1) AS parent_name,
                       EXISTS (SELECT 1 FROM mdm.hierarchy_relationship r WHERE r.hierarchy_id = p.hierarchy_id
                               AND r.child_node_id = p.node_id AND NOT r.is_primary AND r.valid_period @> CAST(:on AS date) AND %s) AS shared
                FROM placed p
                WHERE CAST(:cr AS int) IS NULL
                   OR (p.rank, lower(p.node_name), p.node_id::text, p.hierarchy_code)
                      > (CAST(:cr AS int), CAST(:cn AS text), CAST(:ci AS text), CAST(:ch AS text))
                ORDER BY p.rank, lower(p.node_name), p.node_id::text, p.hierarchy_code
                LIMIT :limit
                """.formatted(slice.recorded("a"), match, identifiers, slice.recorded("r"), slice.recorded("pa"),
                slice.recorded("r"), slice.recorded("r"));
        List<Object[]> rows = jdbc.sql(sql)
                .param("q", text).param("like", like(text)).param("prefix", escape(text.toLowerCase()) + "%")
                .param("on", slice.asOf()).param("rec", slice.recBind()).param("ids", ids)
                .param("cr", after == null ? null : Integer.valueOf(after.get(0)))
                .param("cn", after == null ? null : after.get(1)).param("ci", after == null ? null : after.get(2))
                .param("ch", after == null ? null : after.get(3)).param("limit", limit + 1)
                .query((rs, i) -> new Object[] {new NodeHit(rs.getObject("node_id", UUID.class), rs.getString("node_name"),
                        rs.getString("description"), rs.getString("matched"), rs.getString("hierarchy_code"),
                        rs.getString("hierarchy_name"), rs.getString("parent_name"), rs.getBoolean("shared")), rs.getInt("rank")})
                .list();
        boolean more = rows.size() > limit;
        List<Object[]> page = more ? rows.subList(0, limit) : rows;
        String next = null;
        if (more) {
            Object[] last = page.get(page.size() - 1);
            NodeHit n = (NodeHit) last[0];
            next = cursors.encode(String.valueOf(last[1]), n.name().toLowerCase(), n.nodeId().toString(), n.hierarchyCode());
        }
        return new Page<>(page.stream().map(r -> (NodeHit) r[0]).toList(), next);
    }

    /** As ChangeRequestService.canSee: own requests; otherwise every item in a readable hierarchy, no access changes. */
    private Page<RequestHit> requests(Actor actor, boolean admin, String text, String ids, List<String> after, int limit) {
        List<RequestHit> rows = jdbc.sql("""
                SELECT cr.change_request_id, cr.title, cr.status::text AS status, coalesce(u.display_name, u.login) AS requested_by,
                       cr.created_at
                FROM mdm.change_request cr
                LEFT JOIN mdm.app_user u ON u.user_id = cr.requester_id
                WHERE cr.kind = 'request' AND cr.title ILIKE :like
                  AND (:admin OR cr.requester_id = :me
                       OR (EXISTS (SELECT 1 FROM mdm.change_item ci WHERE ci.change_request_id = cr.change_request_id)
                           AND NOT EXISTS (SELECT 1 FROM mdm.change_item ci WHERE ci.change_request_id = cr.change_request_id
                                           AND (mdm.is_access_action(ci.action)
                                                OR (CAST(:ids AS text) IS NOT NULL
                                                    AND (ci.hierarchy_id IS NULL
                                                         OR ci.hierarchy_id <> ALL(string_to_array(CAST(:ids AS text), ',')::uuid[])))))))
                  AND (CAST(:ca AS timestamptz) IS NULL
                       OR (cr.created_at, cr.change_request_id::text) < (CAST(:ca AS timestamptz), CAST(:cid AS text)))
                ORDER BY cr.created_at DESC, cr.change_request_id::text DESC
                LIMIT :limit
                """).param("like", like(text)).param("admin", admin).param("me", actor.userId()).param("ids", ids)
                .param("ca", after == null ? null : java.sql.Timestamp.from(Instant.parse(after.get(0))))
                .param("cid", after == null ? null : after.get(1)).param("limit", limit + 1)
                .query((rs, i) -> new RequestHit(rs.getObject(1, UUID.class), rs.getString(2), rs.getString(3), rs.getString(4),
                        rs.getTimestamp(5).toInstant()))
                .list();
        boolean more = rows.size() > limit;
        List<RequestHit> page = more ? rows.subList(0, limit) : rows;
        String next = more ? cursors.encode(page.get(page.size() - 1).createdAt().toString(), page.get(page.size() - 1).id().toString()) : null;
        return new Page<>(page, next);
    }

    /** %text% for ILIKE, with the user's % and _ taken literally. */
    private static String like(String text) {
        return "%" + escape(text) + "%";
    }

    private static String escape(String text) {
        return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_");
    }
}
