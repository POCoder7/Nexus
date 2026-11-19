package com.mdm.api.home;

import com.mdm.api.audit.AuditQuery;
import com.mdm.api.changerequest.ChangeRequestDtos.ChangeRequestView;
import com.mdm.api.changerequest.ChangeRequestService;
import com.mdm.api.common.BusinessClock;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import com.mdm.api.security.Permission;
import com.mdm.api.security.PreferencesRepository;
import com.mdm.api.workflow.worklist.WorklistQuery;
import com.mdm.api.workflow.worklist.WorklistQuery.WorklistRow;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * Home (NEW-10, OD-27; Phase 3 LLD §5.1): one bounded summary for the landing page. Each list is capped, so no paging is
 * needed; the full lists are the worklist, the change-request list and the hierarchy list. The governance panel
 * (shadow summary) is returned only to policy roles: ADMIN (policy administration) or {@code POLICY_APPROVERS} member.
 */
@RestController
@RequestMapping("/api/v1/home")
public class HomeController {

    static final int WORKLIST_TOP = 5;
    static final int MY_REQUESTS_LATEST = 5;
    static final int HIERARCHIES_MAX = 10;
    static final int RECENT_DAYS = 7;
    static final int RECENT_ACTIVITY = 5;

    public record WorklistSummary(List<WorklistRow> top, Map<String, Long> counts) {
    }

    public record MyRequests(Map<String, Long> countsByStatus, List<ChangeRequestView> latest) {
    }

    public record HierarchyCard(String code, String name, String purpose, boolean lastUsed, long openRequests) {
    }

    public record ShadowSummaryRow(String policyCode, int policyVersion, long decidedRequests, long wouldAutoCommit,
                                   long tooLoose, long possiblyTooStrict, BigDecimal tooLoosePct) {
    }

    /** Changes in the last {@code days} days the user can see (the audit search's scope, Phase 5 LLD §18.5, §21). */
    public record RecentChanges(int days, long nodesChanged, long requestsApplied) {
    }

    /** A request applied or rejected recently that the user can see (Phase 5 LLD §21). */
    public record ActivityItem(UUID changeRequestId, String title, String status, Instant at, String requestedBy, String decidedBy,
                               String decisionBasis) {
    }

    /**
     * {@code policySummary} is null when the caller has no policy role (the panel is not shown). {@code hierarchyCount} is
     * every readable hierarchy ({@code hierarchies} lists the first {@value #HIERARCHIES_MAX}).
     */
    public record HomeView(WorklistSummary worklist, MyRequests requests, List<HierarchyCard> hierarchies,
                           List<ShadowSummaryRow> policySummary, long hierarchyCount, RecentChanges recentChanges,
                           List<ActivityItem> recentActivity) {
    }

    private final JdbcClient jdbc;
    private final WorklistQuery worklist;
    private final ChangeRequestService changeRequests;
    private final EntitlementService entitlements;
    private final PreferencesRepository preferences;
    private final BusinessClock clock;
    private final AuditQuery audit;

    public HomeController(JdbcClient jdbc, WorklistQuery worklist, ChangeRequestService changeRequests,
                          EntitlementService entitlements, PreferencesRepository preferences, BusinessClock clock, AuditQuery audit) {
        this.jdbc = jdbc;
        this.worklist = worklist;
        this.changeRequests = changeRequests;
        this.entitlements = entitlements;
        this.preferences = preferences;
        this.clock = clock;
        this.audit = audit;
    }

    @GetMapping
    public HomeView getHome(Actor actor) {
        WorklistQuery.WorklistPage assigned = worklist.page(actor, "assigned", null, null, WORKLIST_TOP, null);
        return new HomeView(new WorklistSummary(assigned.items(), assigned.counts()), myRequests(actor), hierarchies(actor),
                isPolicyRole(actor) ? shadowSummary() : null, hierarchyCount(actor), recentChanges(actor), recentActivity(actor));
    }

    private MyRequests myRequests(Actor actor) {
        Map<String, Long> counts = new LinkedHashMap<>();
        jdbc.sql("""
                SELECT status::text AS status, count(*) AS n FROM mdm.change_request
                WHERE requester_id = :me AND kind = 'request'   -- sandboxes are counted under /sandboxes (NEW-08)
                GROUP BY status ORDER BY status
                """).param("me", actor.userId())
                .query((rs, i) -> counts.put(rs.getString("status"), rs.getLong("n"))).list();
        List<ChangeRequestView> latest = changeRequests.mine(actor, null, null, null, MY_REQUESTS_LATEST);
        return new MyRequests(counts, latest.size() > MY_REQUESTS_LATEST ? latest.subList(0, MY_REQUESTS_LATEST) : latest);
    }

    /** Readable hierarchies, the last one used first, then by sort sequence; open = not yet in a terminal status. */
    private List<HierarchyCard> hierarchies(Actor actor) {
        Optional<Set<UUID>> readable = entitlements.readableHierarchies(actor);
        String[] ids = readable.map(s -> s.stream().map(UUID::toString).toArray(String[]::new)).orElse(null);
        UUID last = preferences.lastHierarchyId(actor.userId()).orElse(null);
        return jdbc.sql("""
                SELECT h.hierarchy_code, h.hierarchy_name, h.purpose, h.hierarchy_id = CAST(:last AS uuid) AS last_used,
                       (SELECT count(DISTINCT ci.change_request_id)
                        FROM mdm.change_item ci JOIN mdm.change_request cr ON cr.change_request_id = ci.change_request_id
                        WHERE ci.hierarchy_id = h.hierarchy_id
                          AND cr.status IN ('submitted', 'in_review', 'approved')) AS open_requests
                FROM mdm.hierarchy h
                WHERE h.is_active
                  AND (CAST(:ids AS text[]) IS NULL OR h.hierarchy_id::text = ANY (CAST(:ids AS text[])))
                ORDER BY (h.hierarchy_id = CAST(:last AS uuid)) IS TRUE DESC, h.sort_seq NULLS LAST, h.hierarchy_code
                LIMIT :max
                """)
                .param("ids", ids).param("last", last).param("max", HIERARCHIES_MAX)
                .query((rs, i) -> new HierarchyCard(rs.getString("hierarchy_code"), rs.getString("hierarchy_name"),
                        rs.getString("purpose"), rs.getBoolean("last_used"), rs.getLong("open_requests")))
                .list();
    }

    private long hierarchyCount(Actor actor) {
        Optional<Set<UUID>> readable = entitlements.readableHierarchies(actor);
        if (readable.isPresent()) {
            return readable.get().size();
        }
        return jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE is_active").query(Long.class).single();
    }

    /** Data changes in the last {@value #RECENT_DAYS} days, counted over exactly what the Audit page would list. */
    private RecentChanges recentChanges(Actor actor) {
        boolean admin = entitlements.hasAny(actor, Permission.ADMIN_SYSTEM);
        Optional<Set<UUID>> readable = entitlements.readableHierarchies(actor);
        if (!admin && readable.map(Set::isEmpty).orElse(false)) {
            return new RecentChanges(RECENT_DAYS, 0, 0);
        }
        LocalDate today = clock.today();
        Instant from = today.minusDays(RECENT_DAYS - 1L).atStartOfDay(clock.zone()).toInstant();
        Instant to = today.plusDays(1).atStartOfDay(clock.zone()).toInstant();
        AuditQuery.Summary s = audit.summary(new AuditQuery.Criteria(from, to, null, null, null, null, null, null, Set.of("data"),
                false, admin, admin ? null : readable.orElse(null), null, null, null, 0));
        return new RecentChanges(RECENT_DAYS, s.nodesChanged(), s.requestsApplied());
    }

    /**
     * The last requests applied or rejected that the user can see: their own, or (as ChangeRequestService.canSee) requests
     * whose every item is in a hierarchy they can read; access requests to ADMINs only (ADR-042).
     */
    private List<ActivityItem> recentActivity(Actor actor) {
        boolean admin = entitlements.hasAny(actor, Permission.ADMIN_SYSTEM);
        Optional<Set<UUID>> readable = entitlements.readableHierarchies(actor);
        String ids = readable.map(set -> set.isEmpty() ? "00000000-0000-0000-0000-000000000000"
                : String.join(",", set.stream().map(UUID::toString).toList())).orElse(null);
        return jdbc.sql("""
                SELECT cr.change_request_id, cr.title, cr.status::text AS status, coalesce(cr.applied_at, cr.decided_at) AS at,
                       coalesce(ru.display_name, ru.login) AS requested_by, coalesce(du.display_name, du.login) AS decided_by,
                       cr.decision_basis::text AS decision_basis
                FROM mdm.change_request cr
                LEFT JOIN mdm.app_user ru ON ru.user_id = cr.requester_id
                LEFT JOIN mdm.app_user du ON du.user_id = cr.decided_by
                WHERE cr.kind = 'request' AND cr.status IN ('applied', 'rejected')
                  AND (:admin OR cr.requester_id = :me
                       OR (EXISTS (SELECT 1 FROM mdm.change_item ci WHERE ci.change_request_id = cr.change_request_id)
                           AND NOT EXISTS (SELECT 1 FROM mdm.change_item ci WHERE ci.change_request_id = cr.change_request_id
                                           AND (mdm.is_access_action(ci.action)
                                                OR (CAST(:ids AS text) IS NOT NULL
                                                    AND (ci.hierarchy_id IS NULL
                                                         OR ci.hierarchy_id <> ALL(string_to_array(CAST(:ids AS text), ',')::uuid[])))))))
                ORDER BY coalesce(cr.applied_at, cr.decided_at) DESC NULLS LAST
                LIMIT :max
                """).param("admin", admin).param("me", actor.userId()).param("ids", ids).param("max", RECENT_ACTIVITY)
                .query((rs, i) -> new ActivityItem(rs.getObject("change_request_id", UUID.class), rs.getString("title"),
                        rs.getString("status"), instant(rs.getTimestamp("at")), rs.getString("requested_by"), rs.getString("decided_by"),
                        rs.getString("decision_basis")))
                .list();
    }

    private static Instant instant(Timestamp t) {
        return t == null ? null : t.toInstant();
    }

    private boolean isPolicyRole(Actor actor) {
        boolean policyAdmin = entitlements.hasAny(actor, Permission.ADMIN_POLICY);   // ADMIN since ADR-042 C-1
        return policyAdmin || jdbc.sql("""
                SELECT wf.is_member((SELECT group_id FROM mdm.user_group WHERE group_code = 'POLICY_APPROVERS'), :me, CAST(:on AS date))
                """).param("me", actor.userId()).param("on", clock.today()).query(Boolean.class).single();
    }

    private List<ShadowSummaryRow> shadowSummary() {
        return jdbc.sql("""
                SELECT policy_code, policy_version, decided_requests, would_auto_commit, too_loose, possibly_too_strict, too_loose_pct
                FROM wf.v_shadow_summary ORDER BY policy_code, policy_version
                """)
                .query((rs, i) -> new ShadowSummaryRow(rs.getString("policy_code"), rs.getInt("policy_version"),
                        rs.getLong("decided_requests"), rs.getLong("would_auto_commit"), rs.getLong("too_loose"),
                        rs.getLong("possibly_too_strict"), rs.getBigDecimal("too_loose_pct")))
                .list();
    }
}
