package com.mdm.api.workflow.worklist;

import com.mdm.api.common.Cursors;
import com.mdm.api.security.Actor;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.sql.Timestamp;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * GOV-13 worklist (Phase 2 LLD §4.9, §5.1): the nine DRG views with a count per view, search, a model filter and keyset
 * paging. Every row is filtered in SQL ({@code wf.worklist_page} uses {@code wf.can_act}); this class does not re-check
 * permissions. {@code notified} is always empty until notifications (GOV-08) are decided.
 */
@RestController
@RequestMapping("/api/v1/worklist")
public class WorklistController {

    static final Set<String> VIEWS = Set.of("assigned", "urgent", "overdue", "claimed", "submitted", "drafted", "participated",
            "notified", "all");

    public record WorklistRow(UUID rowId, UUID instanceStageId, UUID instanceId, UUID changeRequestId, String title,
                              String modelCode, String stageLabel, String stageType, String stageStatus, Instant dueAt,
                              UUID claimedBy, boolean isUrgent, boolean isOverdue, UUID requesterId) {
    }

    public record WorklistPage(List<WorklistRow> items, String nextCursor, Map<String, Long> counts) {
    }

    private final JdbcClient jdbc;
    private final Cursors cursors;

    public WorklistController(JdbcClient jdbc, Cursors cursors) {
        this.jdbc = jdbc;
        this.cursors = cursors;
    }

    @GetMapping
    public WorklistPage getWorklist(Actor actor,
                                    @RequestParam(defaultValue = "assigned") String view,
                                    @RequestParam(required = false) String search,
                                    @RequestParam(required = false) String model,
                                    @RequestParam(defaultValue = "50") int limit,
                                    @RequestParam(required = false) String cursor) {
        if (!VIEWS.contains(view)) {
            throw new IllegalArgumentException("view must be one of " + new java.util.TreeSet<>(VIEWS));
        }
        if (search != null && search.length() > 100) {
            throw new IllegalArgumentException("search must be at most 100 characters");
        }
        cursors.checkLimit(limit);
        String q = search == null || search.isBlank() ? null : search.trim();
        String m = model == null || model.isBlank() ? null : model.trim();
        List<String> after = cursors.decode(cursor, 2);

        record Fetched(WorklistRow row, String sortDue) {
        }
        List<Fetched> fetched = jdbc.sql("""
                SELECT * FROM wf.worklist_page(:user, :view, :search, :model, CAST(:afterDue AS timestamptz), CAST(:afterId AS uuid), :limit)
                """)
                .param("user", actor.userId()).param("view", view).param("search", q).param("model", m)
                .param("afterDue", after == null ? null : after.get(0))   // PostgreSQL text, including 'infinity'
                .param("afterId", after == null ? null : UUID.fromString(after.get(1)))
                .param("limit", limit + 1)
                .query((rs, i) -> new Fetched(new WorklistRow(rs.getObject("row_id", UUID.class), rs.getObject("instance_stage_id", UUID.class),
                        rs.getObject("instance_id", UUID.class), rs.getObject("change_request_id", UUID.class), rs.getString("title"),
                        rs.getString("model_code"), rs.getString("stage_label"), rs.getString("stage_type"), rs.getString("stage_status"),
                        instant(rs.getTimestamp("due_at")), rs.getObject("claimed_by", UUID.class), rs.getBoolean("is_urgent"),
                        rs.getBoolean("is_overdue"), rs.getObject("requester_id", UUID.class)),
                        rs.getString("sort_due")))
                .list();

        Map<String, Long> counts = new LinkedHashMap<>();
        jdbc.sql("SELECT view, n FROM wf.worklist_counts(:user, :search, :model)")
                .param("user", actor.userId()).param("search", q).param("model", m)
                .query((rs, i) -> counts.put(rs.getString("view"), rs.getLong("n"))).list();

        boolean more = fetched.size() > limit;
        List<Fetched> page = more ? fetched.subList(0, limit) : fetched;
        String next = more ? cursors.encode(page.get(page.size() - 1).sortDue(), page.get(page.size() - 1).row().rowId().toString()) : null;
        return new WorklistPage(page.stream().map(Fetched::row).toList(), next, counts);
    }

    private static Instant instant(Timestamp t) {
        return t == null ? null : t.toInstant();
    }
}
