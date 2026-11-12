package com.mdm.api.workflow;

import com.mdm.api.security.Actor;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import java.sql.Timestamp;
import java.time.Instant;
import java.util.Arrays;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * Read model of a workflow instance (LLD §5.1 {@code GET /workflow/instances/{id}}): its stages in order with their
 * group decisions, and the policy evaluations. {@code youCanAct} is {@code wf.can_act} for the viewer, so a UI shows the
 * actions the database would accept. Stage names come from the model; no names or values of the request's data.
 */
@Component
public class InstanceQuery {

    public record InstanceView(UUID instanceId, UUID changeRequestId, String modelCode, int modelVersion, String status,
                               Integer currentSeq, UUID submittedBy, Instant submittedAt, Instant closedAt,
                               List<StageView> stages, List<PolicyEvaluationView> policyEvaluations) {
    }

    public record StageView(UUID instanceStageId, int seq, int iteration, String label, String type, String status,
                            Boolean included, Instant dueAt, UUID claimedBy, Instant claimExpiresAt, boolean youCanAct,
                            /* the server's reason when an open stage is not yours to decide (wf.why_cannot_act), Phase 3 */ String whyNot,
                            List<DecisionView> decisions) {
    }

    public record DecisionView(String groupCode, UUID decidedBy, String decision, String comment, Instant decidedAt) {
    }

    public record PolicyEvaluationView(String policyCode, String mode, boolean eligible, String outcome,
                                       List<String> failedChecks, Instant evaluatedAt) {
    }

    private final JdbcClient jdbc;

    public InstanceQuery(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    public Optional<UUID> changeRequestOf(UUID instanceId) {
        return jdbc.sql("SELECT change_request_id FROM wf.workflow_instance WHERE instance_id = :i").param("i", instanceId)
                .query(UUID.class).optional();
    }

    public Optional<InstanceView> find(UUID instanceId, Actor viewer) {
        List<StageView> stages = jdbc.sql("""
                SELECT ist.instance_stage_id, ist.seq, ist.iteration, ws.label, ws.stage_type::text AS type, ist.status::text AS status,
                       ist.included, ist.due_at, ist.claimed_by, ist.claim_expires_at, wf.can_act(ist.instance_stage_id, :viewer) AS can_act,
                       CASE WHEN ist.status IN ('active', 'claimed')
                            THEN (SELECT w.message FROM wf.why_cannot_act(ist.instance_stage_id, :viewer) w LIMIT 1) END AS why_not
                FROM wf.instance_stage ist JOIN wf.workflow_stage ws ON ws.stage_id = ist.stage_id
                WHERE ist.instance_id = :i ORDER BY ist.seq, ist.iteration
                """).param("i", instanceId).param("viewer", viewer.userId())
                .query((rs, n) -> new StageView(rs.getObject("instance_stage_id", UUID.class), rs.getInt("seq"), rs.getInt("iteration"),
                        rs.getString("label"), rs.getString("type"), rs.getString("status"), (Boolean) rs.getObject("included"),
                        instant(rs.getTimestamp("due_at")), rs.getObject("claimed_by", UUID.class),
                        instant(rs.getTimestamp("claim_expires_at")), rs.getBoolean("can_act"), rs.getString("why_not"),
                        decisions(rs.getObject("instance_stage_id", UUID.class))))
                .list();
        List<PolicyEvaluationView> evaluations = jdbc.sql("""
                SELECT cp.policy_code, pe.policy_mode::text AS mode, pe.eligible, pe.outcome::text AS outcome, pe.failed_checks, pe.evaluated_at
                FROM wf.policy_evaluation pe LEFT JOIN wf.commit_policy cp ON cp.policy_id = pe.policy_id
                WHERE pe.instance_id = :i ORDER BY pe.evaluated_at
                """).param("i", instanceId)
                .query((rs, n) -> new PolicyEvaluationView(rs.getString("policy_code"), rs.getString("mode"), rs.getBoolean("eligible"),
                        rs.getString("outcome"), Arrays.asList((String[]) rs.getArray("failed_checks").getArray()),
                        instant(rs.getTimestamp("evaluated_at"))))
                .list();
        return jdbc.sql("""
                SELECT i.instance_id, i.change_request_id, m.model_code, m.model_version, i.status::text AS status, i.current_seq,
                       i.submitted_by, i.submitted_at, i.closed_at
                FROM wf.workflow_instance i JOIN wf.workflow_model m ON m.model_id = i.model_id
                WHERE i.instance_id = :i
                """).param("i", instanceId)
                .query((rs, n) -> new InstanceView(rs.getObject("instance_id", UUID.class), rs.getObject("change_request_id", UUID.class),
                        rs.getString("model_code"), rs.getInt("model_version"), rs.getString("status"), (Integer) rs.getObject("current_seq"),
                        rs.getObject("submitted_by", UUID.class), instant(rs.getTimestamp("submitted_at")),
                        instant(rs.getTimestamp("closed_at")), stages, evaluations))
                .optional();
    }

    private List<DecisionView> decisions(UUID stageId) {
        return jdbc.sql("""
                SELECT g.group_code, d.decided_by, d.decision, d.comment, d.decided_at
                FROM wf.stage_group_decision d JOIN wf.user_group g ON g.group_id = d.group_id
                WHERE d.instance_stage_id = :s ORDER BY d.decided_at
                """).param("s", stageId)
                .query((rs, n) -> new DecisionView(rs.getString(1), rs.getObject(2, UUID.class), rs.getString(3), rs.getString(4),
                        instant(rs.getTimestamp(5))))
                .list();
    }

    private static Instant instant(Timestamp t) {
        return t == null ? null : t.toInstant();
    }
}
