package com.mdm.api.workflow.engine;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.PostgresIntegrationTest;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * The engine contract (ADR-035): the same end-to-end scenarios run against every {@link WorkflowEngine} adapter. A new
 * engine is accepted when its subclass passes. Requests go through the API exactly as a steward, approver, enricher and
 * committer would act; the engine moves them between stages via the outbox relay.
 */
public abstract class WorkflowEngineContract extends PostgresIntegrationTest {

    static final UUID TOP = UUID.fromString("00000000-0000-0000-0000-0000000c7001");
    static final UUID LEAF = UUID.fromString("00000000-0000-0000-0000-0000000c7002");
    static final String STEWARD = "ct_steward";
    static final String APPROVER = "ct_approver";
    static final String COMMITTER = "ct_committer";
    static final String ENRICHER = "ct_enricher";

    @Autowired
    protected MockMvc mvc;
    @Autowired
    protected ObjectMapper mapper;
    @Autowired
    protected OutboxRelay relay;
    @Autowired
    protected WorkflowEngine engine;

    /** Lets the engine work until the request has settled (no more relay events, nothing left in flight to move). */
    protected abstract void drain() throws Exception;

    @BeforeEach
    void seedAndSkipOldEvents() {
        JdbcClient jdbc = ownerJdbc();
        ensureUser("nexus_system", "system_feed");
        grant(STEWARD, "STEWARD", null, null);
        grant(ENRICHER, "STEWARD", null, null);
        grant(APPROVER, "APPROVER", null, null);
        grant(COMMITTER, "APPROVER", null, null);
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'CT_H'").query(Integer.class).single() == 0) {
            jdbc.sql("INSERT INTO mdm.version (version_name, business_as_of) VALUES ('CT working', current_date)").update();
            jdbc.sql("INSERT INTO mdm.node (node_id, node_kind) VALUES (:t, 'structural'), (:l, 'legal_entity')").param("t", TOP).param("l", LEAF).update();
            jdbc.sql("INSERT INTO mdm.node_attr (node_id, node_name, valid_period) VALUES (:t, 'CT top', daterange('2020-01-01', NULL)), (:l, 'CT leaf', daterange('2020-01-01', NULL))")
                    .param("t", TOP).param("l", LEAF).update();
            jdbc.sql("INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, top_node_id) VALUES ('CT_H', 'Contract', :t)").param("t", TOP).update();
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, valid_period)
                    SELECT hierarchy_id, :t, :l, daterange('2020-01-01', NULL) FROM mdm.hierarchy WHERE hierarchy_code = 'CT_H'
                    """).param("t", TOP).param("l", LEAF).update();
            jdbc.sql("INSERT INTO mdm.property_definition (property_code, label, data_type, scope) VALUES ('CT.Note', 'Note', 'string', 'global')").update();
            jdbc.sql("""
                    INSERT INTO wf.user_group (group_code, name)
                    VALUES ('CT_APPROVERS', 'Approvers'), ('CT_COMMITTERS', 'Committers'), ('CT_ENRICHERS', 'Enrichers')
                    """).update();
            for (String[] m : new String[][] {{"CT_APPROVERS", APPROVER}, {"CT_COMMITTERS", COMMITTER}, {"CT_ENRICHERS", ENRICHER}}) {
                jdbc.sql("INSERT INTO wf.user_group_member (group_id, user_id) SELECT group_id, :u FROM wf.user_group WHERE group_code = :g")
                        .param("u", ensureUser(m[1], "human")).param("g", m[0]).update();
            }
            jdbc.sql("""
                    INSERT INTO wf.workflow_task (task_code, label, allowed_actions) VALUES
                      ('CT_SUBMIT', 'Submit', '{add_node,update_node,set_property}'), ('CT_APPROVE', 'Approve', '{}'),
                      ('CT_ENRICH', 'Enrich', '{set_property}')
                    """).update();
            jdbc.sql("""
                    INSERT INTO wf.task_property (task_id, property_id) SELECT t.task_id, p.property_id
                    FROM wf.workflow_task t, mdm.property_definition p WHERE t.task_code = 'CT_ENRICH' AND p.property_code = 'CT.Note'
                    """).update();
            model(jdbc, "CT_ADD", "approve", "CT_APPROVERS", "CT_APPROVE");
            model(jdbc, "CT_ENR", "enrich", "CT_ENRICHERS", "CT_ENRICH");
            // a shadow policy covers CT_ADD: evaluated on every request, never commits on its own
            UUID policy = jdbc.sql("""
                    INSERT INTO wf.commit_policy (policy_code, description, rationale, mode, allowed_actions, owner_group_id, proposed_by)
                    SELECT 'CT_SHADOW', 'Adds', 'Contract test', 'shadow', '{add_node}', group_id, :s FROM wf.user_group WHERE group_code = 'CT_COMMITTERS'
                    RETURNING policy_id
                    """).param("s", ensureUser(STEWARD, "human")).query(UUID.class).single();
            jdbc.sql("INSERT INTO wf.policy_scope (policy_id, model_code) VALUES (:p, 'CT_ADD')").param("p", policy).update();
            jdbc.sql("SELECT wf.submit_commit_policy(:p, :s)").param("p", policy).param("s", ensureUser(STEWARD, "human")).query((rs, i) -> 0).single();
            UUID approver = ensureUser("ct_policy_approver", "human");
            jdbc.sql("INSERT INTO wf.user_group_member (group_id, user_id) SELECT group_id, :u FROM wf.user_group WHERE group_code = 'POLICY_APPROVERS'")
                    .param("u", approver).update();
            jdbc.sql("SELECT wf.approve_commit_policy(:p, :a, 'contract')").param("p", policy).param("a", approver).query((rs, i) -> 0).single();
        }
        // scenarios drive only their own requests: skip events other test classes left behind
        jdbc.sql("UPDATE wf.outbox_consumer SET last_event_id = (SELECT coalesce(max(event_id), 0) FROM wf.event_outbox) WHERE consumer_code = :c")
                .param("c", OutboxRelay.CONSUMER).update();
    }

    @Test
    void addLeafEndToEnd() throws Exception {
        String name = "CT New " + UUID.randomUUID().toString().substring(0, 8);
        String cr = submit("CT_ADD", "{\"action\":\"add_node\",\"hierarchyCode\":\"CT_H\",\"targetParentId\":\"" + TOP
                + "\",\"payload\":{\"nodeKind\":\"legal_entity\",\"name\":\"" + name + "\",\"isLeaf\":true}}");
        drain();
        assertThat(currentStage(cr)).isEqualTo("approve/active");
        decide(APPROVER, activeStage(cr), "approve");
        drain();
        assertThat(currentStage(cr)).isEqualTo("commit/active");
        assertThat(ownerJdbc().sql("SELECT policy_mode::text || '/' || outcome::text FROM wf.policy_evaluation pe JOIN wf.workflow_instance i USING (instance_id) WHERE i.change_request_id = CAST(:cr AS uuid)")
                .param("cr", cr).query(String.class).single()).startsWith("shadow/shadow_would_");
        decide(COMMITTER, activeStage(cr), "approve");
        drain();
        assertThat(outcome(cr)).isEqualTo("applied/committed");
        assertThat(ownerJdbc().sql("SELECT count(*) FROM mdm.node_attr WHERE node_name = :n AND upper_inf(recorded_period)").param("n", name)
                .query(Integer.class).single()).isEqualTo(1);
    }

    @Test
    void rejectionEndsTheRequest() throws Exception {
        String cr = submit("CT_ADD", updateLeaf());
        drain();
        decide(APPROVER, activeStage(cr), "reject");
        drain();
        assertThat(outcome(cr)).isEqualTo("rejected/rejected");
    }

    @Test
    void withdrawalEndsTheRequest() throws Exception {
        String cr = submit("CT_ADD", updateLeaf());
        drain();
        mvc.perform(post("/api/v1/change-requests/" + cr + "/withdraw").with(asUser(STEWARD)).header("If-Match", etag(cr)))
                .andExpect(status().isOk());
        drain();
        assertThat(outcome(cr)).isEqualTo("withdrawn/withdrawn");
    }

    @Test
    void enrichmentThenCommitAppliesBothItems() throws Exception {
        String cr = submit("CT_ENR", updateLeaf());
        drain();
        assertThat(currentStage(cr)).isEqualTo("enrich/active");
        mvc.perform(post("/api/v1/workflow/stages/" + activeStage(cr) + "/items").with(asUser(ENRICHER)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"action\":\"set_property\",\"hierarchyCode\":\"CT_H\",\"nodeId\":\"" + LEAF
                                + "\",\"propertyCode\":\"CT.Note\",\"payload\":{\"value\":\"enriched " + cr + "\"}}"))
                .andExpect(status().isCreated());
        decide(ENRICHER, activeStage(cr), "approve");
        drain();
        assertThat(currentStage(cr)).isEqualTo("commit/active");
        decide(COMMITTER, activeStage(cr), "approve");
        drain();
        assertThat(outcome(cr)).isEqualTo("applied/committed");
        assertThat(ownerJdbc().sql("""
                SELECT value #>> '{}' FROM mdm.property_value pv JOIN mdm.property_definition d USING (property_id)
                WHERE d.property_code = 'CT.Note' AND pv.node_id = :n AND upper_inf(pv.recorded_period) AND pv.valid_period @> current_date
                """).param("n", LEAF).query(String.class).single()).isEqualTo("enriched " + cr);
    }

    @Test
    void repeatedDeliveriesChangeNothing() throws Exception {
        String cr = submit("CT_ADD", updateLeaf());
        drain();
        UUID instance = instance(cr);
        engine.startProcess(instance, UUID.fromString(cr));   // a duplicate start
        decide(APPROVER, activeStage(cr), "approve");
        long before = offset();
        drain();
        assertThat(offset()).isGreaterThan(before);
        assertThat(relay.poll()).isZero();                      // nothing left to relay
        assertThat(currentStage(cr)).isEqualTo("commit/active");
        assertThat(ownerJdbc().sql("SELECT count(*) FROM wf.instance_stage WHERE instance_id = :i AND status = 'active'")
                .param("i", instance).query(Integer.class).single()).isEqualTo(1);
    }

    // ------------------------------------------------------------------ helpers

    private static void model(JdbcClient jdbc, String code, String middleType, String middleGroup, String middleTask) {
        UUID model = jdbc.sql("INSERT INTO wf.workflow_model (model_code, label) VALUES (:c, :c) RETURNING model_id").param("c", code).query(UUID.class).single();
        jdbc.sql("""
                INSERT INTO wf.workflow_stage (model_id, seq, stage_type, label, task_id) VALUES
                  (:m, 1, 'submit', 'Submit', NULL),
                  (:m, 2, CAST(:type AS wf.stage_type), 'Middle', (SELECT task_id FROM wf.workflow_task WHERE task_code = :task)),
                  (:m, 3, 'commit', 'Commit', NULL)
                """).param("m", model).param("type", middleType).param("task", middleTask).update();
        jdbc.sql("""
                INSERT INTO wf.stage_group (stage_id, group_id)
                SELECT s.stage_id, g.group_id FROM wf.workflow_stage s, wf.user_group g
                WHERE s.model_id = :m AND ((s.seq = 2 AND g.group_code = :mg) OR (s.seq = 3 AND g.group_code = 'CT_COMMITTERS'))
                """).param("m", model).param("mg", middleGroup).update();
        jdbc.sql("INSERT INTO wf.submit_task SELECT :m, task_id FROM wf.workflow_task WHERE task_code = 'CT_SUBMIT'").param("m", model).update();
        jdbc.sql("UPDATE wf.workflow_model SET status = 'active', activated_by = :a WHERE model_id = :m")
                .param("a", ensureUser("ct_policy_approver", "human")).param("m", model).update();
    }

    private String updateLeaf() {
        return "{\"action\":\"update_node\",\"hierarchyCode\":\"CT_H\",\"nodeId\":\"" + LEAF + "\",\"payload\":{\"description\":\"CT "
                + UUID.randomUUID() + "\"}}";
    }

    private String submit(String model, String item) throws Exception {
        MvcResult r = mvc.perform(post("/api/v1/change-requests").with(asUser(STEWARD)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"versionName\":\"CT working\",\"title\":\"CT " + model + "\",\"workflowModelCode\":\"" + model + "\"}"))
                .andExpect(status().isCreated()).andReturn();
        String id = mapper.readTree(r.getResponse().getContentAsString()).get("id").asText();
        mvc.perform(post("/api/v1/change-requests/" + id + "/items").with(asUser(STEWARD)).header("If-Match", etag(id))
                .contentType(MediaType.APPLICATION_JSON).content(item)).andExpect(status().isCreated());
        mvc.perform(post("/api/v1/change-requests/" + id + "/submit").with(asUser(STEWARD)).header("If-Match", etag(id)))
                .andExpect(status().isOk());
        return id;
    }

    private void decide(String login, UUID stage, String decision) throws Exception {
        mvc.perform(post("/api/v1/workflow/stages/" + stage + "/decision").with(asUser(login)).contentType(MediaType.APPLICATION_JSON)
                .content("{\"decision\":\"" + decision + "\"}")).andExpect(status().isOk());
    }

    protected UUID instance(String cr) {
        return ownerJdbc().sql("SELECT instance_id FROM wf.workflow_instance WHERE change_request_id = CAST(:cr AS uuid) AND parent_instance_id IS NULL")
                .param("cr", cr).query(UUID.class).single();
    }

    private UUID activeStage(String cr) {
        return ownerJdbc().sql("SELECT instance_stage_id FROM wf.instance_stage WHERE instance_id = :i AND status IN ('active', 'claimed')")
                .param("i", instance(cr)).query(UUID.class).single();
    }

    private String currentStage(String cr) throws Exception {
        JsonNode view = mapper.readTree(mvc.perform(get("/api/v1/workflow/instances/" + instance(cr)).with(asUser(STEWARD)))
                .andReturn().getResponse().getContentAsString());
        for (JsonNode s : view.path("stages")) {
            if (s.path("seq").asInt() == view.path("currentSeq").asInt()) {
                return s.path("type").asText() + "/" + s.path("status").asText();
            }
        }
        return "none";
    }

    private String outcome(String cr) {
        return ownerJdbc().sql("""
                SELECT cr.status::text || '/' || i.status::text FROM mdm.change_request cr
                JOIN wf.workflow_instance i ON i.change_request_id = cr.change_request_id AND i.parent_instance_id IS NULL
                WHERE cr.change_request_id = CAST(:cr AS uuid)
                """).param("cr", cr).query(String.class).single();
    }

    private long offset() {
        return ownerJdbc().sql("SELECT last_event_id FROM wf.outbox_consumer WHERE consumer_code = :c").param("c", OutboxRelay.CONSUMER)
                .query(Long.class).single();
    }

    private String etag(String id) throws Exception {
        return mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(STEWARD))).andReturn().getResponse().getHeader("ETag");
    }
}
