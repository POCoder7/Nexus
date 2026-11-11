package com.mdm.api.workflow;

import com.mdm.api.PostgresIntegrationTest;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.simple.JdbcClient;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * D-14 (Phase 2 increment 2-5): two requests evaluated under the same active policy at the same moment, one below the
 * daily cap. Exactly one may be auto-committed. Two real connections: the first evaluation holds its transaction open,
 * the second must wait on the policy lock and then see the first one's auto-commit.
 *
 * <p>The active policy exists only in this test database: the owner-only setting {@code policy_activation_allowed} is
 * switched on for the approval and removed straight after (OD-08 stays closed everywhere else).
 */
class CommitPolicyConcurrencyTest extends PostgresIntegrationTest {

    static final UUID STEWARD = UUID.fromString("00000000-0000-0000-0000-0000000cc001");
    static final UUID APPROVER = UUID.fromString("00000000-0000-0000-0000-0000000cc002");
    static final UUID SYSTEM = UUID.fromString("00000000-0000-0000-0000-0000000cc003");
    static final UUID MODEL = UUID.fromString("00000000-0000-0000-0000-0000000cc010");
    static final UUID POLICY = UUID.fromString("00000000-0000-0000-0000-0000000cc020");
    static final UUID VERSION = UUID.fromString("00000000-0000-0000-0000-0000000cc030");
    static final UUID GROUP = UUID.fromString("00000000-0000-0000-0000-0000000cc040");
    static final UUID TASK = UUID.fromString("00000000-0000-0000-0000-0000000cc050");
    static final UUID PROPERTY = UUID.fromString("00000000-0000-0000-0000-0000000cc060");
    static final UUID NODE = UUID.fromString("00000000-0000-0000-0000-0000000cc070");
    static final int CAP = 3;

    UUID first;
    UUID second;

    @BeforeEach
    void seed() {
        JdbcClient jdbc = ownerJdbc();
        if (jdbc.sql("SELECT count(*) FROM wf.commit_policy WHERE policy_id = :p").param("p", POLICY).query(Integer.class).single() == 0) {
            jdbc.sql("""
                    INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
                      (:s, 'cc_steward', 'CC steward', 'human'), (:a, 'cc_approver', 'CC approver', 'human'),
                      (:y, 'cc_system', 'CC system', 'system_feed')
                    """).param("s", STEWARD).param("a", APPROVER).param("y", SYSTEM).update();
            jdbc.sql("INSERT INTO mdm.version (version_id, version_name, business_as_of) VALUES (:v, 'CC_V', current_date)")
                    .param("v", VERSION).update();
            jdbc.sql("INSERT INTO mdm.node (node_id, node_kind) VALUES (:n, 'legal_entity')").param("n", NODE).update();
            jdbc.sql("INSERT INTO mdm.property_definition (property_id, property_code, label, data_type, scope) VALUES (:p, 'CC.Note', 'Note', 'string', 'global')")
                    .param("p", PROPERTY).update();
            jdbc.sql("INSERT INTO wf.user_group (group_id, group_code, name) VALUES (:g, 'CC_COMMITTERS', 'Committers')").param("g", GROUP).update();
            jdbc.sql("INSERT INTO wf.user_group_member (group_id, user_id) SELECT group_id, :a FROM wf.user_group WHERE group_code = 'POLICY_APPROVERS'")
                    .param("a", APPROVER).update();
            jdbc.sql("INSERT INTO wf.workflow_task (task_id, task_code, label) VALUES (:t, 'CC_TASK', 'Task')").param("t", TASK).update();
            jdbc.sql("INSERT INTO wf.workflow_model (model_id, model_code, label) VALUES (:m, 'CC_MODEL', 'Submit and commit')")
                    .param("m", MODEL).update();
            jdbc.sql("""
                    INSERT INTO wf.workflow_stage (stage_id, model_id, seq, stage_type, label) VALUES
                      (gen_random_uuid(), :m, 1, 'submit', 'Submit'), ('00000000-0000-0000-0000-0000000cc011', :m, 2, 'commit', 'Commit')
                    """).param("m", MODEL).update();
            jdbc.sql("INSERT INTO wf.submit_task VALUES (:m, :t)").param("m", MODEL).param("t", TASK).update();
            jdbc.sql("INSERT INTO wf.stage_group (stage_id, group_id) VALUES ('00000000-0000-0000-0000-0000000cc011', :g)").param("g", GROUP).update();
            jdbc.sql("UPDATE wf.workflow_model SET status = 'active' WHERE model_id = :m").param("m", MODEL).update();
            jdbc.sql("""
                    INSERT INTO wf.commit_policy (policy_id, policy_code, description, rationale, mode, allowed_actions,
                                                  max_auto_commits_per_day, owner_group_id, proposed_by)
                    VALUES (:p, 'CC_POLICY', 'Notes', 'Test only', 'active', '{set_property}', :cap, :g, :s)
                    """).param("p", POLICY).param("cap", CAP).param("g", GROUP).param("s", STEWARD).update();
            jdbc.sql("INSERT INTO wf.policy_scope (policy_id, model_code) VALUES (:p, 'CC_MODEL')").param("p", POLICY).update();
            jdbc.sql("SELECT wf.submit_commit_policy(:p, :s)").param("p", POLICY).param("s", STEWARD).query((rs, i) -> 0).single();
            jdbc.sql("INSERT INTO mdm.system_setting VALUES ('policy_activation_allowed', 'true', 'test only (CommitPolicyConcurrencyTest)')").update();
            try {
                jdbc.sql("SELECT wf.approve_commit_policy(:p, :a, 'test')").param("p", POLICY).param("a", APPROVER).query((rs, i) -> 0).single();
            } finally {
                jdbc.sql("DELETE FROM mdm.system_setting WHERE setting_key = 'policy_activation_allowed'").update();
            }
        }
        // today: the policy is one auto-commit below its cap
        UUID filler = request("CC filler");
        for (int n = 0; n < CAP - 1; n++) {
            jdbc.sql("""
                    INSERT INTO wf.policy_evaluation (instance_id, policy_id, policy_mode, eligible, outcome, validated_at)
                    SELECT instance_id, :p, 'active', true, 'auto_committed', now() FROM wf.workflow_instance WHERE change_request_id = :cr
                    """).param("p", POLICY).param("cr", filler).update();
        }
        first = instanceOf(request("CC first"));
        second = instanceOf(request("CC second"));
    }

    @Test
    void twoEvaluationsAtTheCapMinusOneCommitExactlyOne() throws Exception {
        try (Connection c1 = owner(); Connection c2 = owner()) {
            c1.setAutoCommit(false);
            c2.setAutoCommit(false);
            assertThat(apply(c1, first)).isEqualTo("auto_committed");   // holds the policy lock until commit

            CompletableFuture<String> other = CompletableFuture.supplyAsync(() -> {
                try {
                    return apply(c2, second);
                } catch (Exception e) {
                    throw new IllegalStateException(e);
                }
            });
            assertThat(waitsOnALock()).as("the second evaluation waits for the first (policy row lock)").isTrue();
            c1.commit();
            String outcome = other.get(10, TimeUnit.SECONDS);
            c2.commit();

            assertThat(outcome).isEqualTo("routed_to_human");
        }
        JdbcClient jdbc = ownerJdbc();
        assertThat(jdbc.sql("""
                SELECT count(*) FROM wf.policy_evaluation
                WHERE policy_id = :p AND outcome = 'auto_committed' AND evaluated_at >= mdm.business_day_start(mdm.business_today())
                """).param("p", POLICY).query(Integer.class).single()).isEqualTo(CAP);
        assertThat(jdbc.sql("SELECT 'daily auto-commit limit reached' = ANY (failed_checks) FROM wf.policy_evaluation WHERE instance_id = :i")
                .param("i", second).query(Boolean.class).single()).isTrue();
        assertThat(jdbc.sql("SELECT cr.status::text || '/' || cr.decision_basis FROM mdm.change_request cr JOIN wf.workflow_instance i USING (change_request_id) WHERE i.instance_id = :i")
                .param("i", first).query(String.class).single()).isEqualTo("approved/approved_policy");
    }

    // ------------------------------------------------------------------ helpers

    private UUID request(String title) {
        JdbcClient jdbc = ownerJdbc();
        UUID cr = jdbc.sql("""
                INSERT INTO mdm.change_request (version_id, title, requester_id, requester_kind, risk_tier)
                VALUES (:v, :t, :s, 'human', 'low') RETURNING change_request_id
                """).param("v", VERSION).param("t", title + " " + UUID.randomUUID()).param("s", STEWARD).query(UUID.class).single();
        jdbc.sql("""
                INSERT INTO mdm.change_item (change_request_id, seq, action, node_id, property_id, payload)
                VALUES (:cr, 1, 'set_property', :n, :p, '{"value": "x"}')
                """).param("cr", cr).param("n", NODE).param("p", PROPERTY).update();
        jdbc.sql("SELECT wf.start_instance(:cr, 'CC_MODEL', :s)").param("cr", cr).param("s", STEWARD).query(UUID.class).single();
        return cr;
    }

    private UUID instanceOf(UUID changeRequest) {
        return ownerJdbc().sql("SELECT instance_id FROM wf.workflow_instance WHERE change_request_id = :cr")
                .param("cr", changeRequest).query(UUID.class).single();
    }

    private static Connection owner() throws Exception {
        return DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private static String apply(Connection c, UUID instance) throws Exception {
        try (PreparedStatement ps = c.prepareStatement("SELECT wf.apply_commit_policy(?, now(), ?)::text")) {
            ps.setObject(1, instance);
            ps.setObject(2, SYSTEM);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                return rs.getString(1);
            }
        }
    }

    /** True once an apply_commit_policy call is waiting on a lock (checked from a third connection, up to 5 s). */
    private static boolean waitsOnALock() throws Exception {
        try (Connection probe = owner()) {
            for (int i = 0; i < 50; i++) {
                try (PreparedStatement ps = probe.prepareStatement("""
                        SELECT count(*) FROM pg_stat_activity
                        WHERE wait_event_type = 'Lock' AND query LIKE 'SELECT wf.apply_commit_policy%'
                        """); ResultSet rs = ps.executeQuery()) {
                    rs.next();
                    if (rs.getInt(1) > 0) {
                        return true;
                    }
                }
                Thread.sleep(100);
            }
        }
        return false;
    }
}
