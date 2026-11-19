package com.mdm.api.compare;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.mdm.api.common.BusinessClock;
import com.mdm.api.common.Cursors;
import com.mdm.api.common.ItemValidationException;
import com.mdm.api.common.NotFoundException;
import com.mdm.api.common.Page;
import com.mdm.api.common.RuleException;
import com.mdm.api.compare.CompareDtos.CompareRequest;
import com.mdm.api.compare.CompareDtos.CompareRow;
import com.mdm.api.compare.CompareDtos.CompareRunView;
import com.mdm.api.compare.CompareDtos.CompareSide;
import com.mdm.api.compare.CompareDtos.ResolvedSide;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import com.mdm.api.security.ForbiddenException;
import jakarta.annotation.PreDestroy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/**
 * Compares (QRY-02, VER-04; Phase 5 LLD §17.4). A compare is a run: both sides are resolved to a slice (hierarchy,
 * business date, recorded time), the run is stored, and a bounded executor fills its rows with {@code mdm.compare_fill}
 * in one transaction. A run whose two sides are frozen (recorded in the past) gives the same answer for ever, so a done,
 * unexpired run of the same slices is reused, for any user: rows are checked against the reader's scope when read.
 * Runs expire after {@code compare_result_ttl_h}; a run still running after {@code compare_timeout_min} reads as failed.
 */
@Service
public class CompareService {

    static final Set<String> KINDS = Set.of("structure", "property", "rename");
    private static final Logger LOG = LoggerFactory.getLogger(CompareService.class);
    private static final int MAX_LIMIT = 500;

    private final JdbcClient jdbc;
    private final ObjectMapper mapper;
    private final EntitlementService entitlements;
    private final BusinessClock clock;
    private final Cursors cursors;
    private final ExecutorService executor;

    public CompareService(JdbcClient jdbc, ObjectMapper mapper, EntitlementService entitlements, BusinessClock clock, Cursors cursors) {
        this.jdbc = jdbc;
        this.mapper = mapper;
        this.entitlements = entitlements;
        this.clock = clock;
        this.cursors = cursors;
        int parallelism = setting("compare_parallelism", 2);
        // bounded: COMPARE_PARALLELISM runs at a time per instance, a short queue, and a refusal beyond it (§17.4.3)
        this.executor = new ThreadPoolExecutor(parallelism, parallelism, 0, TimeUnit.MILLISECONDS, new LinkedBlockingQueue<>(50),
                r -> {
                    Thread t = new Thread(r, "compare-run");
                    t.setDaemon(true);
                    return t;
                });
    }

    @PreDestroy
    void stop() {
        executor.shutdownNow();
    }

    /** Starts a run, or returns a reusable one. READ on both hierarchies is required. */
    public CompareRunView start(Actor actor, CompareRequest body) {
        if (body == null || body.left() == null || body.right() == null) {
            throw ItemValidationException.field("left", "both sides are required");
        }
        Instant now = Instant.now().truncatedTo(ChronoUnit.MICROS);
        Side left = resolve(actor, body.left(), "left", now);
        Side right = resolve(actor, body.right(), "right", now);
        Set<String> kinds = new TreeSet<>(body.kinds() == null || body.kinds().isEmpty() ? KINDS : body.kinds());
        if (!KINDS.containsAll(kinds)) {
            throw ItemValidationException.field("kinds", "must be among " + new TreeSet<>(KINDS));
        }
        Set<UUID> propertyIds = null;
        if (body.propertyCodes() != null && !body.propertyCodes().isEmpty()) {
            propertyIds = new TreeSet<>();
            for (String code : new LinkedHashSet<>(body.propertyCodes())) {
                propertyIds.add(jdbc.sql("SELECT property_id FROM mdm.property_definition WHERE property_code = :c").param("c", code)
                        .query(UUID.class).optional()
                        .orElseThrow(() -> ItemValidationException.field("propertyCodes", "unknown property " + code)));
            }
        }

        ObjectNode definition = mapper.createObjectNode();
        definition.set("left", left.json(mapper));
        definition.set("right", right.json(mapper));
        ArrayNode k = definition.putArray("kinds");
        kinds.forEach(k::add);
        if (propertyIds != null) {
            ArrayNode p = definition.putArray("propertyIds");
            propertyIds.forEach(id -> p.add(id.toString()));
        }
        if (body.subtreeRootId() != null) {
            definition.put("subtreeRootId", body.subtreeRootId().toString());
        }
        definition.put("includeInactive", Boolean.TRUE.equals(body.includeInactive()));
        definition.put("includeOrder", Boolean.TRUE.equals(body.includeOrder()));
        String sliceKey = md5(definition.toString());
        boolean frozen = left.frozen() && right.frozen();

        jdbc.sql("DELETE FROM mdm.compare_run WHERE expires_at < now()").update();   // expired runs and their rows (§17.4.3)
        if (frozen) {
            Optional<UUID> reuse = jdbc.sql("""
                    SELECT compare_run_id FROM mdm.compare_run
                    WHERE slice_key = :k AND status = 'done' AND is_frozen AND expires_at > now()
                    ORDER BY finished_at DESC LIMIT 1
                    """).param("k", sliceKey).query(UUID.class).optional();
            if (reuse.isPresent()) {
                return view(reuse.get(), true);
            }
        }
        UUID id = jdbc.sql("""
                INSERT INTO mdm.compare_run (requested_by, definition, slice_key, is_frozen, expires_at)
                VALUES (:by, CAST(:def AS jsonb), :k, :frozen, now() + make_interval(hours => :ttl))
                RETURNING compare_run_id
                """).param("by", actor.userId()).param("def", definition.toString()).param("k", sliceKey).param("frozen", frozen)
                .param("ttl", setting("compare_result_ttl_h", 24)).query(UUID.class).single();
        try {
            executor.execute(() -> fill(id));
        } catch (RejectedExecutionException e) {
            fail(id, "Too many compares are running; try again in a moment.");
            throw new RuleException("compare.busy", "Too many compares are running on this server. Try again in a moment.");
        }
        return view(id, false);
    }

    public CompareRunView get(Actor actor, UUID id) {
        requireReadable(actor, id);
        return view(id, false);
    }

    /** One page of rows, by kind then node name; {@code kind} null = every kind. */
    public Page<CompareRow> rows(Actor actor, UUID id, String kind, String cursor, int limit) {
        if (limit < 1 || limit > MAX_LIMIT) {
            throw ItemValidationException.field("limit", "must be between 1 and " + MAX_LIMIT);
        }
        if (kind != null && !KINDS.contains(kind)) {
            throw ItemValidationException.field("kind", "must be one of " + new TreeSet<>(KINDS));
        }
        requireReadable(actor, id);
        CompareRunView run = view(id, false);
        if (!"done".equals(run.status())) {
            throw new RuleException("compare.not_done", "running".equals(run.status())
                    ? "The compare is still running." : "The compare failed: " + run.error());
        }
        List<String> key = cursors.decode(cursor, 3);
        List<Object[]> rows = jdbc.sql("""
                SELECT kind, node_id, node_name, detail::text AS detail, seq
                FROM mdm.compare_row
                WHERE compare_run_id = :id AND (CAST(:kind AS text) IS NULL OR kind = CAST(:kind AS text))
                  AND (CAST(:ck AS text) IS NULL OR (kind, node_name, seq) > (CAST(:ck AS text), CAST(:cn AS text), CAST(:cs AS bigint)))
                ORDER BY kind, node_name, seq
                LIMIT :limit
                """).param("id", id).param("kind", kind)
                .param("ck", key == null ? null : key.get(0)).param("cn", key == null ? null : key.get(1))
                .param("cs", key == null ? null : Long.valueOf(key.get(2))).param("limit", limit + 1)
                .query((rs, i) -> new Object[] {new CompareRow(rs.getString("kind"), rs.getObject("node_id", UUID.class),
                        rs.getString("node_name"), json(rs.getString("detail"))), rs.getLong("seq")})
                .list();
        boolean more = rows.size() > limit;
        List<Object[]> page = more ? rows.subList(0, limit) : rows;
        String next = null;
        if (more) {
            Object[] last = page.get(page.size() - 1);
            CompareRow r = (CompareRow) last[0];
            next = cursors.encode(r.kind(), r.nodeName(), String.valueOf(last[1]));
        }
        return new Page<>(page.stream().map(r -> (CompareRow) r[0]).toList(), next);
    }

    // ------------------------------------------------------------------ helpers

    private record Side(UUID hierarchyId, String hierarchyCode, String hierarchyName, String version, LocalDate asOf,
                        Instant recordedAsOf, boolean frozen) {
        ObjectNode json(ObjectMapper mapper) {
            ObjectNode n = mapper.createObjectNode();
            n.put("hierarchyId", hierarchyId.toString());
            n.put("hierarchyCode", hierarchyCode);
            n.put("hierarchyName", hierarchyName);
            if (version != null) {
                n.put("version", version);
            }
            n.put("asOf", asOf.toString());
            n.put("recordedAsOf", recordedAsOf.toString());
            return n;
        }
    }

    /** A version gives its business date and, once frozen, its recorded time; otherwise the given date (default today). */
    private Side resolve(Actor actor, CompareSide s, String field, Instant now) {
        if (s.hierarchyCode() == null || s.hierarchyCode().isBlank()) {
            throw ItemValidationException.field(field + ".hierarchyCode", "is required");
        }
        Object[] h = jdbc.sql("SELECT hierarchy_id, hierarchy_name FROM mdm.hierarchy WHERE hierarchy_code = :c")
                .param("c", s.hierarchyCode()).query((rs, i) -> new Object[] {rs.getObject(1, UUID.class), rs.getString(2)}).optional()
                .orElseThrow(() -> ItemValidationException.field(field + ".hierarchyCode", "unknown hierarchy " + s.hierarchyCode()));
        UUID hierarchyId = (UUID) h[0];
        if (!entitlements.canRead(actor, hierarchyId)) {
            throw new ForbiddenException("entitlement.missing", "You can't read " + s.hierarchyCode() + ", so you can't compare it.");
        }
        if (s.version() != null && !s.version().isBlank()) {
            if (s.asOf() != null || s.recordedAsOf() != null) {
                throw ItemValidationException.field(field + ".version", "give a version or a date, not both");
            }
            Object[] v = jdbc.sql("SELECT business_as_of, recorded_as_of FROM mdm.version WHERE version_name = :n")
                    .param("n", s.version().trim())
                    .query((rs, i) -> new Object[] {rs.getObject(1, LocalDate.class), rs.getTimestamp(2)}).optional()
                    .orElseThrow(() -> ItemValidationException.field(field + ".version", "unknown version " + s.version()));
            Timestamp pinned = (Timestamp) v[1];
            return new Side(hierarchyId, s.hierarchyCode(), (String) h[1], s.version().trim(), (LocalDate) v[0],
                    pinned == null ? now : pinned.toInstant(), pinned != null);
        }
        LocalDate asOf = s.asOf() == null ? clock.today() : s.asOf();
        Instant rec = s.recordedAsOf() == null ? now : s.recordedAsOf();
        if (rec.isAfter(now)) {
            throw ItemValidationException.field(field + ".recordedAsOf", "must not be in the future");
        }
        return new Side(hierarchyId, s.hierarchyCode(), (String) h[1], null, asOf, rec, s.recordedAsOf() != null);
    }

    private void fill(UUID id) {
        try {
            jdbc.sql("SELECT mdm.compare_fill(:id)").param("id", id).query(String.class).single();
        } catch (RuntimeException e) {
            LOG.warn("Compare run {} failed", id, e);
            fail(id, "The compare could not be completed. Try again, or narrow it to a sub-tree.");
        }
    }

    private void fail(UUID id, String error) {
        jdbc.sql("UPDATE mdm.compare_run SET status = 'failed', error = :e, finished_at = now() WHERE compare_run_id = :id AND status = 'running'")
                .param("e", error).param("id", id).update();
    }

    /** 404 unless the run exists and the reader can read both its hierarchies (a reused run is shared, §17.4.4). */
    private void requireReadable(Actor actor, UUID id) {
        List<UUID> hierarchies = jdbc.sql("""
                SELECT (definition #>> '{left,hierarchyId}')::uuid, (definition #>> '{right,hierarchyId}')::uuid
                FROM mdm.compare_run WHERE compare_run_id = :id AND expires_at > now()
                """).param("id", id).query((rs, i) -> List.of(rs.getObject(1, UUID.class), rs.getObject(2, UUID.class)))
                .optional().orElseThrow(() -> new NotFoundException("Compare " + id + " not found or expired"));
        if (!hierarchies.stream().allMatch(h -> entitlements.canRead(actor, h))) {
            throw new NotFoundException("Compare " + id + " not found or expired");
        }
    }

    private CompareRunView view(UUID id, boolean reused) {
        int timeoutMin = setting("compare_timeout_min", 15);
        return jdbc.sql("""
                SELECT compare_run_id, status, counts::text AS counts, error, definition::text AS definition, started_at, finished_at,
                       expires_at, is_frozen, (status = 'running' AND started_at < now() - make_interval(mins => :t)) AS timed_out
                FROM mdm.compare_run WHERE compare_run_id = :id
                """).param("id", id).param("t", timeoutMin)
                .query((rs, i) -> {
                    JsonNode def = json(rs.getString("definition"));
                    boolean timedOut = rs.getBoolean("timed_out");
                    List<String> kinds = new ArrayList<>();
                    def.path("kinds").forEach(n -> kinds.add(n.asText()));
                    return new CompareRunView(rs.getObject("compare_run_id", UUID.class), timedOut ? "failed" : rs.getString("status"),
                            json(rs.getString("counts")), timedOut ? "The compare took too long. Narrow it to a sub-tree." : rs.getString("error"),
                            side(def.path("left")), side(def.path("right")), kinds, instant(rs.getTimestamp("started_at")),
                            instant(rs.getTimestamp("finished_at")), instant(rs.getTimestamp("expires_at")), rs.getBoolean("is_frozen"), reused);
                }).single();
    }

    private static ResolvedSide side(JsonNode n) {
        return new ResolvedSide(n.path("hierarchyCode").asText(), n.path("hierarchyName").asText(null),
                n.hasNonNull("version") ? n.get("version").asText() : null, LocalDate.parse(n.path("asOf").asText()),
                Instant.parse(n.path("recordedAsOf").asText()));
    }

    /** A named parameter (§17.15) from system_setting, or its default if it is missing or the table cannot be read. */
    private int setting(String key, int fallback) {
        try {
            return jdbc.sql("SELECT setting_value FROM mdm.system_setting WHERE setting_key = :k").param("k", key)
                    .query(String.class).optional().map(Integer::valueOf).orElse(fallback);
        } catch (RuntimeException e) {
            return fallback;
        }
    }

    private static Instant instant(Timestamp t) {
        return t == null ? null : t.toInstant();
    }

    private JsonNode json(String s) {
        try {
            return s == null ? null : mapper.readTree(s);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static String md5(String s) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("MD5").digest(s.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }
}
