package com.mdm.api.home;

import com.mdm.api.changerequest.ChangeRequestDtos.ChangeRequestView;
import com.mdm.api.changerequest.ChangeRequestService;
import com.mdm.api.common.BusinessClock;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import com.mdm.api.security.PreferencesRepository;
import com.mdm.api.workflow.worklist.WorklistQuery;
import com.mdm.api.workflow.worklist.WorklistQuery.WorklistRow;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.math.BigDecimal;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * Home (NEW-10, OD-27; Phase 3 LLD §5.1): one bounded summary for the landing page. Each list is capped, so no paging is
 * needed; the full lists are the worklist, the change-request list and the hierarchy list. The governance panel
 * (shadow summary) is returned only to policy roles: {@code POLICY_ADMIN} grant or {@code POLICY_APPROVERS} member.
 */
@RestController
@RequestMapping("/api/v1/home")
public class HomeController {

    static final int WORKLIST_TOP = 5;
    static final int MY_REQUESTS_LATEST = 5;
    static final int HIERARCHIES_MAX = 10;

    public record WorklistSummary(List<WorklistRow> top, Map<String, Long> counts) {
    }

    public record MyRequests(Map<String, Long> countsByStatus, List<ChangeRequestView> latest) {
    }

    public record HierarchyCard(String code, String name, String purpose, boolean lastUsed, long openRequests) {
    }

    public record ShadowSummaryRow(String policyCode, int policyVersion, long decidedRequests, long wouldAutoCommit,
                                   long tooLoose, long possiblyTooStrict, BigDecimal tooLoosePct) {
    }

    /** {@code policySummary} is null when the caller has no policy role (the panel is not shown). */
    public record HomeView(WorklistSummary worklist, MyRequests requests, List<HierarchyCard> hierarchies,
                           List<ShadowSummaryRow> policySummary) {
    }

    private final JdbcClient jdbc;
    private final WorklistQuery worklist;
    private final ChangeRequestService changeRequests;
    private final EntitlementService entitlements;
    private final PreferencesRepository preferences;
    private final BusinessClock clock;

    public HomeController(JdbcClient jdbc, WorklistQuery worklist, ChangeRequestService changeRequests,
                          EntitlementService entitlements, PreferencesRepository preferences, BusinessClock clock) {
        this.jdbc = jdbc;
        this.worklist = worklist;
        this.changeRequests = changeRequests;
        this.entitlements = entitlements;
        this.preferences = preferences;
        this.clock = clock;
    }

    @GetMapping
    public HomeView getHome(Actor actor) {
        WorklistQuery.WorklistPage assigned = worklist.page(actor, "assigned", null, null, WORKLIST_TOP, null);
        return new HomeView(new WorklistSummary(assigned.items(), assigned.counts()), myRequests(actor), hierarchies(actor),
                isPolicyRole(actor) ? shadowSummary() : null);
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

    private boolean isPolicyRole(Actor actor) {
        boolean policyAdmin = entitlements.grants(actor).stream().anyMatch(g -> "POLICY_ADMIN".equals(g.roleCode()));
        return policyAdmin || jdbc.sql("""
                SELECT wf.is_member((SELECT group_id FROM wf.user_group WHERE group_code = 'POLICY_APPROVERS'), :me, CAST(:on AS date))
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
