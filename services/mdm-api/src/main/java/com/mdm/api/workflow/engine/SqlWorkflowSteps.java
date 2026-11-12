package com.mdm.api.workflow.engine;

import com.mdm.api.apply.ApplyService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import java.sql.Timestamp;
import java.time.LocalDate;
import java.util.Optional;
import java.util.UUID;

/**
 * {@link WorkflowSteps} over the guarded {@code wf} functions, run as the worker ({@link WorkerDatabase}). Each step is
 * one call (or a read followed by one call) and safe to repeat; the guards decide, this class only reads who acts.
 */
@Component
public class SqlWorkflowSteps implements WorkflowSteps {

    private static final Logger log = LoggerFactory.getLogger(SqlWorkflowSteps.class);

    private final JdbcClient jdbc;
    private final ApplyService apply;
    private final String systemActorLogin;

    public SqlWorkflowSteps(WorkerDatabase worker, ApplyService apply,
                            @Value("${mdm.workflow.system-actor-login:nexus_system}") String systemActorLogin) {
        this.jdbc = worker.jdbc();
        this.apply = apply;
        this.systemActorLogin = systemActorLogin;
    }

    @Override
    public StepResult nextStage(UUID instanceId) {
        StepResult r = jdbc.sql("SELECT action, instance_stage_id, stage_type::text AS stage_type, due_at FROM wf.advance_instance(:i)")
                .param("i", instanceId)
                .query((rs, n) -> new StepResult(rs.getString("action"), rs.getObject("instance_stage_id", UUID.class),
                        rs.getString("stage_type"), rs.getTimestamp("due_at") == null ? null : rs.getTimestamp("due_at").toInstant()))
                .single();
        if ((StepResult.WAIT.equals(r.action()) || StepResult.ACTIVATED.equals(r.action())) && r.instanceStageId() != null) {
            String outcome = jdbc.sql("SELECT wf.stage_outcome(:s)").param("s", r.instanceStageId()).query(String.class).single();
            if ("approved".equals(outcome) || "rejected".equals(outcome)) {
                r = new StepResult("approved".equals(outcome) ? StepResult.DECIDED_APPROVED : StepResult.DECIDED_REJECTED,
                        r.instanceStageId(), r.stageType(), r.dueAt());
            }
        }
        log.info("workflow.next_stage instanceId={} action={} stageId={}", instanceId, r.action(), r.instanceStageId());
        return r;
    }

    @Override
    public String completeStage(UUID instanceStageId) {
        return jdbc.sql("SELECT wf.complete_stage(:s)").param("s", instanceStageId).query(String.class).single();
    }

    @Override
    public String evaluatePolicy(UUID instanceId) {
        record Req(UUID changeRequest, LocalDate effectiveFrom) {
        }
        Req req = jdbc.sql("""
                SELECT cr.change_request_id, cr.effective_from FROM wf.workflow_instance i
                JOIN mdm.change_request cr ON cr.change_request_id = i.change_request_id WHERE i.instance_id = :i
                """).param("i", instanceId).query((rs, n) -> new Req(rs.getObject(1, UUID.class), rs.getObject(2, LocalDate.class))).single();
        Timestamp validatedAt = jdbc.sql("SELECT clock_timestamp()").query(Timestamp.class).single();
        jdbc.sql("SELECT count(*) FROM mdm.validate_change_request(:cr, :d)").param("cr", req.changeRequest())
                .param("d", req.effectiveFrom()).query(Integer.class).single();   // trial apply + rules; findings stored
        String outcome = jdbc.sql("SELECT wf.apply_commit_policy(:i, :at, :system)::text")
                .param("i", instanceId).param("at", validatedAt).param("system", systemActor()).query(String.class).single();
        log.info("workflow.policy_evaluated instanceId={} outcome={}", instanceId, outcome);
        return outcome;
    }

    @Override
    public boolean closeCommitted(UUID instanceId) {
        Optional<UUID> committer = jdbc.sql("""
                SELECT d.decided_by
                FROM wf.workflow_instance i
                JOIN wf.instance_stage ist ON ist.instance_id = i.instance_id
                JOIN wf.workflow_stage ws  ON ws.stage_id = ist.stage_id AND ws.stage_type = 'commit'
                JOIN wf.stage_group_decision d ON d.instance_stage_id = ist.instance_stage_id AND d.decision = 'approve'
                WHERE i.instance_id = :i AND i.status = 'in_flight' AND ist.status = 'completed'
                ORDER BY ist.iteration DESC, d.decided_at DESC LIMIT 1
                """).param("i", instanceId).query(UUID.class).optional();
        if (committer.isEmpty()) {
            return false;   // not open, or Commit not yet approved and completed: nothing to do
        }
        jdbc.sql("SELECT wf.close_instance(:i, 'committed', :actor, NULL)").param("i", instanceId).param("actor", committer.get())
                .query((rs, n) -> 0).single();
        log.info("workflow.closed instanceId={} outcome=committed", instanceId);
        return true;
    }

    @Override
    public boolean closeRejected(UUID instanceStageId) {
        record Rejection(UUID instance, UUID rejecter) {
        }
        Optional<Rejection> r = jdbc.sql("""
                SELECT ist.instance_id, d.decided_by
                FROM wf.instance_stage ist
                JOIN wf.workflow_instance i ON i.instance_id = ist.instance_id AND i.status = 'in_flight'
                JOIN wf.stage_group_decision d ON d.instance_stage_id = ist.instance_stage_id AND d.decision = 'reject'
                WHERE ist.instance_stage_id = :s
                ORDER BY d.decided_at DESC LIMIT 1
                """).param("s", instanceStageId).query((rs, n) -> new Rejection(rs.getObject(1, UUID.class), rs.getObject(2, UUID.class)))
                .optional();
        if (r.isEmpty()) {
            return false;
        }
        jdbc.sql("SELECT wf.close_instance(:i, 'rejected', :actor, NULL)").param("i", r.get().instance()).param("actor", r.get().rejecter())
                .query((rs, n) -> 0).single();
        log.info("workflow.closed instanceId={} outcome=rejected", r.get().instance());
        return true;
    }

    @Override
    public String apply(UUID instanceId) {
        record Decided(UUID changeRequest, String status, UUID decidedBy) {
        }
        Decided d = jdbc.sql("""
                SELECT cr.change_request_id, cr.status::text, cr.decided_by FROM wf.workflow_instance i
                JOIN mdm.change_request cr ON cr.change_request_id = i.change_request_id WHERE i.instance_id = :i
                """).param("i", instanceId)
                .query((rs, n) -> new Decided(rs.getObject(1, UUID.class), rs.getString(2), rs.getObject(3, UUID.class))).single();
        if (!"approved".equals(d.status())) {
            return d.status();   // already applied, or not approved: nothing to do
        }
        return apply.apply(d.decidedBy(), d.changeRequest()).status();
    }

    @Override
    public UUID instanceOfStage(UUID instanceStageId) {
        return jdbc.sql("SELECT instance_id FROM wf.instance_stage WHERE instance_stage_id = :s").param("s", instanceStageId)
                .query(UUID.class).single();
    }

    private UUID systemActor() {
        return jdbc.sql("SELECT user_id FROM mdm.app_user WHERE login = :l AND kind = 'system_feed' AND is_active")
                .param("l", systemActorLogin).query(UUID.class).optional()
                .orElseThrow(() -> new IllegalStateException("System actor " + systemActorLogin
                        + " (kind system_feed) is missing; it records policy evaluations (mdm.workflow.system-actor-login)"));
    }
}
