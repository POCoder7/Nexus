package com.mdm.api.audit;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.changerequest.ChangeRequestService;
import com.mdm.api.common.Cursors;
import com.mdm.api.common.ItemValidationException;
import com.mdm.api.common.Page;
import com.mdm.api.security.Actor;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.sql.Timestamp;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

/**
 * Request history (AUD-02; Phase 5 LLD §18.6): everything that happened to one request, oldest first, merged from the
 * request's and its items' audit rows, the workflow's actions and the commit-policy evaluations. Events are facts (a type
 * and fields); the UI words them. Visible to whoever can see the request (404 otherwise). Read-only.
 *
 * <p>Types: {@code created}, {@code edited}, {@code status} (with from and to: submitted, in review, approved, rejected,
 * applied, apply failed, withdrawn), {@code item_added}, {@code item_changed}, {@code item_removed}, {@code workflow}
 * (with the workflow action, stage and comment; an override's reason is its comment) and {@code policy}.
 */
@RestController
@RequestMapping("/api/v1/change-requests")
public class RequestHistoryController {

    private static final int DEFAULT_LIMIT = 100;
    private static final int MAX_LIMIT = 200;

    /** {@code data}: the event's fields (status from/to, note, error, item, stage, comment, policy, outcome, checks). */
    public record RequestEvent(String id, Instant at, String type, UUID actorId, String actor, JsonNode data) {
    }

    private final JdbcClient jdbc;
    private final ObjectMapper mapper;
    private final ChangeRequestService requests;
    private final Cursors cursors;

    public RequestHistoryController(JdbcClient jdbc, ObjectMapper mapper, ChangeRequestService requests, Cursors cursors) {
        this.jdbc = jdbc;
        this.mapper = mapper;
        this.requests = requests;
        this.cursors = cursors;
    }

    @GetMapping("/{id}/history")
    public Page<RequestEvent> getRequestHistory(Actor actor, @PathVariable UUID id, @RequestParam(required = false) String cursor,
                                                @RequestParam(defaultValue = "" + DEFAULT_LIMIT) int limit) {
        if (limit < 1 || limit > MAX_LIMIT) {
            throw ItemValidationException.field("limit", "must be between 1 and " + MAX_LIMIT);
        }
        requests.get(actor, id);   // 404 when the actor cannot see the request (as the request itself)
        List<String> key = cursors.decode(cursor, 3);
        String sql = """
                WITH cr AS (SELECT * FROM mdm.change_request WHERE change_request_id = :id),
                inst AS (SELECT instance_id FROM wf.workflow_instance WHERE change_request_id = :id),
                ev AS (
                  -- the request row: created, edited while a draft, and every status change
                  SELECT 'a'::text AS src, lpad(a.audit_id::text, 20, '0') AS sid, a.occurred_at AS at,
                         CASE WHEN a.action = 'INSERT' THEN 'created'
                              WHEN a.old_row ->> 'status' IS DISTINCT FROM a.new_row ->> 'status' THEN 'status'
                              ELSE 'edited' END AS type,
                         CASE WHEN a.action = 'INSERT' THEN (a.new_row ->> 'requester_id')::uuid
                              WHEN a.new_row ->> 'status' IN ('approved', 'rejected') AND a.old_row ->> 'status' IS DISTINCT FROM a.new_row ->> 'status'
                                THEN (a.new_row ->> 'decided_by')::uuid
                              WHEN a.new_row ->> 'status' IN ('applied', 'apply_failed') AND a.old_row ->> 'status' IS DISTINCT FROM a.new_row ->> 'status'
                                THEN a.actor_id
                              WHEN a.new_row ->> 'status' = 'in_review' THEN coalesce(a.actor_id, (a.new_row ->> 'requester_id')::uuid)
                              ELSE (a.new_row ->> 'requester_id')::uuid END AS actor_id,
                         jsonb_strip_nulls(jsonb_build_object(
                           'from', CASE WHEN a.action = 'UPDATE' THEN a.old_row ->> 'status' END,
                           'to', a.new_row ->> 'status',
                           'note', CASE WHEN a.old_row ->> 'status' IS DISTINCT FROM a.new_row ->> 'status' THEN a.new_row ->> 'decision_note' END,
                           'basis', CASE WHEN a.new_row ->> 'status' = 'approved' AND a.old_row ->> 'status' IS DISTINCT FROM a.new_row ->> 'status'
                                         THEN a.new_row ->> 'decision_basis' END,
                           'error', CASE WHEN a.new_row ->> 'status' = 'apply_failed' THEN a.new_row ->> 'apply_error' END,
                           'title', CASE WHEN a.action = 'INSERT' OR a.old_row ->> 'title' IS DISTINCT FROM a.new_row ->> 'title'
                                         THEN a.new_row ->> 'title' END,
                           'effectiveFrom', CASE WHEN a.action = 'INSERT' OR a.old_row ->> 'effective_from' IS DISTINCT FROM a.new_row ->> 'effective_from'
                                                 THEN a.new_row ->> 'effective_from' END)) AS data
                  FROM mdm.audit_log a
                  WHERE a.change_request_id = :id AND a.table_name = 'change_request'
                    -- a row-version bump (an item changed) is not an event of its own: the item event says it
                    AND (a.action = 'INSERT'
                         OR (a.old_row - ARRAY['row_version', 'updated_at']) IS DISTINCT FROM (a.new_row - ARRAY['row_version', 'updated_at']))
                  UNION ALL
                  -- items: added, changed or removed while a draft (by the requester); enrichment items arrive in review
                  SELECT 'a', lpad(a.audit_id::text, 20, '0'), a.occurred_at,
                         CASE a.action WHEN 'INSERT' THEN 'item_added' WHEN 'DELETE' THEN 'item_removed' ELSE 'item_changed' END,
                         coalesce(a.actor_id, CASE WHEN (SELECT submitted_at FROM cr) IS NULL OR a.occurred_at <= (SELECT submitted_at FROM cr)
                                                   THEN (SELECT requester_id FROM cr) END),
                         jsonb_build_object('item', jsonb_strip_nulls(jsonb_build_object(
                           'seq', (coalesce(a.new_row, a.old_row) ->> 'seq')::int,
                           'action', coalesce(a.new_row, a.old_row) ->> 'action',
                           'hierarchyCode', h.hierarchy_code,
                           'nodeId', coalesce(a.new_row, a.old_row) ->> 'node_id',
                           'nodeName', (SELECT na.node_name FROM mdm.node_attr na WHERE na.node_id = a.node_id AND upper_inf(na.recorded_period)
                                        ORDER BY upper_inf(na.valid_period) DESC LIMIT 1),
                           'propertyCode', pd.property_code,
                           'payload', coalesce(a.new_row, a.old_row) -> 'payload')))
                  FROM mdm.audit_log a
                  LEFT JOIN mdm.hierarchy h ON h.hierarchy_id = a.hierarchy_id
                  LEFT JOIN mdm.property_definition pd ON pd.property_id = a.property_id
                  WHERE a.change_request_id = :id AND a.table_name = 'change_item'
                  UNION ALL
                  -- the workflow: every action, with its stage and comment (an override's reason)
                  SELECT 'w', lpad(ia.action_id::text, 20, '0'), ia.occurred_at, 'workflow', ia.actor_id,
                         jsonb_strip_nulls(jsonb_build_object('action', ia.action::text, 'stage', ws.label, 'stageType', ws.stage_type::text,
                                                              'comment', ia.comment, 'decision', ia.payload ->> 'decision',
                                                              'aiModel', ia.ai_model))
                  FROM wf.instance_action ia
                  LEFT JOIN wf.instance_stage ist ON ist.instance_stage_id = ia.instance_stage_id
                  LEFT JOIN wf.workflow_stage ws ON ws.stage_id = ist.stage_id
                  WHERE ia.instance_id IN (SELECT instance_id FROM inst)
                  UNION ALL
                  -- commit-policy evaluations, with every failed check
                  SELECT 'p', pe.evaluation_id::text, pe.evaluated_at, 'policy', NULL::uuid,
                         jsonb_strip_nulls(jsonb_build_object('policy', cp.policy_code, 'mode', pe.policy_mode::text,
                                                              'outcome', pe.outcome::text, 'eligible', pe.eligible,
                                                              'failedChecks', to_jsonb(pe.failed_checks)))
                  FROM wf.policy_evaluation pe LEFT JOIN wf.commit_policy cp ON cp.policy_id = pe.policy_id
                  WHERE pe.instance_id IN (SELECT instance_id FROM inst)
                )
                SELECT ev.src, ev.sid, ev.at, ev.type, ev.actor_id, coalesce(u.display_name, u.login) AS actor, ev.data::text AS data
                FROM ev LEFT JOIN mdm.app_user u ON u.user_id = ev.actor_id
                WHERE (CAST(:cursorAt AS timestamptz) IS NULL
                       OR (ev.at, ev.src, ev.sid) > (CAST(:cursorAt AS timestamptz), CAST(:cursorSrc AS text), CAST(:cursorSid AS text)))
                ORDER BY ev.at, ev.src, ev.sid
                LIMIT :limit
                """;
        List<Object[]> rows = jdbc.sql(sql)
                .param("id", id)
                .param("cursorAt", key == null ? null : Timestamp.from(Instant.parse(key.get(0))))
                .param("cursorSrc", key == null ? null : key.get(1))
                .param("cursorSid", key == null ? null : key.get(2))
                .param("limit", limit + 1)
                .query((rs, i) -> new Object[] {
                        new RequestEvent(rs.getString("src") + ":" + rs.getString("sid"), rs.getTimestamp("at").toInstant(),
                                rs.getString("type"), rs.getObject("actor_id", UUID.class), rs.getString("actor"), json(rs.getString("data"))),
                        rs.getString("src"), rs.getString("sid")})
                .list();
        boolean more = rows.size() > limit;
        List<Object[]> page = more ? rows.subList(0, limit) : rows;
        String next = null;
        if (more) {
            Object[] last = page.get(page.size() - 1);
            next = cursors.encode(((RequestEvent) last[0]).at().toString(), last[1], last[2]);
        }
        return new Page<>(page.stream().map(r -> (RequestEvent) r[0]).toList(), next);
    }

    private JsonNode json(String s) {
        try {
            return s == null ? null : mapper.readTree(s);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }
}
