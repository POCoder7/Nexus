package com.mdm.api.workflow;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.PostgresIntegrationTest;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.ResultActions;

import java.util.UUID;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Phase 2 increment 2-8b: stage decisions, claims, enrichment items and the instance view through the API, with every
 * refusal explained in words (LLD §5.1). The engine's steps (advance, complete) are called directly here; the engine
 * itself arrives in 2-10.
 */
class WorkflowStageApiTest extends PostgresIntegrationTest {

    static final UUID TOP = UUID.fromString("00000000-0000-0000-0000-0000000f6001");
    static final UUID LEAF = UUID.fromString("00000000-0000-0000-0000-0000000f6002");
    static final String STEWARD = "wf_steward";
    static final String APPROVER1 = "wf_approver1";
    static final String APPROVER2 = "wf_approver2";
    static final String ENRICHER = "wf_enricher";
    static final String VIEWER = "wf_viewer";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    @BeforeEach
    void seed() {
        JdbcClient jdbc = ownerJdbc();
        grant(STEWARD, "STEWARD", null, null);
        grant(STEWARD, "APPROVER", null, null);   // so the refusal comes from the workflow rules, not the role
        grant(APPROVER1, "APPROVER", null, null);
        grant(APPROVER2, "APPROVER", null, null);
        grant(ENRICHER, "STEWARD", null, null);
        grant(VIEWER, "VIEWER", null, null);
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'WF_H'").query(Integer.class).single() > 0) {
            return;
        }
        jdbc.sql("INSERT INTO mdm.version (version_name, business_as_of) VALUES ('WF working', current_date)").update();
        jdbc.sql("INSERT INTO mdm.node (node_id, node_kind) VALUES (:t, 'structural'), (:l, 'legal_entity')").param("t", TOP).param("l", LEAF).update();
        jdbc.sql("INSERT INTO mdm.node_attr (node_id, node_name, valid_period) VALUES (:t, 'WF top', daterange('2020-01-01', NULL)), (:l, 'WF leaf', daterange('2020-01-01', NULL))")
                .param("t", TOP).param("l", LEAF).update();
        jdbc.sql("INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, top_node_id) VALUES ('WF_H', 'Workflow', :t)").param("t", TOP).update();
        jdbc.sql("""
                INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, valid_period)
                SELECT hierarchy_id, :t, :l, daterange('2020-01-01', NULL) FROM mdm.hierarchy WHERE hierarchy_code = 'WF_H'
                """).param("t", TOP).param("l", LEAF).update();
        jdbc.sql("INSERT INTO mdm.property_definition (property_code, label, data_type, scope) VALUES ('WF.Note', 'Note', 'string', 'global')").update();
        jdbc.sql("""
                INSERT INTO wf.user_group (group_code, name) VALUES ('WF_APPROVERS', 'Approvers'), ('WF_COMMITTERS', 'Committers'),
                                                                   ('WF_ENRICHERS', 'Enrichers')
                """).update();
        for (String[] m : new String[][] {{"WF_APPROVERS", STEWARD}, {"WF_APPROVERS", APPROVER1}, {"WF_APPROVERS", APPROVER2},
                                          {"WF_COMMITTERS", APPROVER2}, {"WF_ENRICHERS", ENRICHER}}) {
            jdbc.sql("INSERT INTO wf.user_group_member (group_id, user_id) SELECT group_id, :u FROM wf.user_group WHERE group_code = :g")
                    .param("u", ensureUser(m[1], "human")).param("g", m[0]).update();
        }
        jdbc.sql("""
                INSERT INTO wf.workflow_task (task_code, label, allowed_actions) VALUES
                  ('WF_SUBMIT', 'Submit', '{update_node,set_property}'), ('WF_APPROVE', 'Approve', '{}'), ('WF_ENRICH', 'Enrich', '{set_property}')
                """).update();
        jdbc.sql("""
                INSERT INTO wf.task_property (task_id, property_id)
                SELECT t.task_id, p.property_id FROM wf.workflow_task t, mdm.property_definition p
                WHERE t.task_code = 'WF_ENRICH' AND p.property_code = 'WF.Note'
                """).update();
        model(jdbc, "WF_TWO", new String[] {"submit", "approve", "approve", "commit"}, new String[] {null, "WF_APPROVERS", "WF_APPROVERS", "WF_COMMITTERS"});
        model(jdbc, "WF_ENR", new String[] {"submit", "enrich", "commit"}, new String[] {null, "WF_ENRICHERS", "WF_COMMITTERS"});
    }

    @Test
    void decisionsClaimsAndRefusalsInWords() throws Exception {
        UUID instance = submitted("WF_TWO");
        advance(instance);
        String stage2 = stageId(instance, 2);

        mvc.perform(get("/api/v1/workflow/instances/" + instance).with(asUser(APPROVER1)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.modelCode").value("WF_TWO"))
                .andExpect(jsonPath("$.stages[1].status").value("active"))
                .andExpect(jsonPath("$.stages[1].youCanAct").value(true));
        mvc.perform(get("/api/v1/workflow/instances/" + instance).with(asUser(STEWARD)))
                .andExpect(jsonPath("$.stages[1].youCanAct").value(false));

        decide(STEWARD, stage2, "approve").andExpect(status().isForbidden())
                .andExpect(jsonPath("$.code").value("maker_checker.own_request"))
                .andExpect(jsonPath("$.detail").value("You requested or submitted this change, so you cannot approve or commit it."));
        decide(VIEWER, stage2, "approve").andExpect(status().isForbidden())
                .andExpect(jsonPath("$.code").value("entitlement.missing"));

        mvc.perform(post("/api/v1/workflow/stages/" + stage2 + "/claim").with(asUser(APPROVER1))).andExpect(status().isNoContent());
        decide(APPROVER2, stage2, "approve").andExpect(status().isForbidden())
                .andExpect(jsonPath("$.code").value("wf.claimed_by_other"));

        String key = "wf-decision-" + UUID.randomUUID();
        mvc.perform(post("/api/v1/workflow/stages/" + stage2 + "/decision").with(asUser(APPROVER1)).header("Idempotency-Key", key)
                        .contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"approve\",\"comment\":\"fine\"}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.stageOutcome").value("approved"));
        mvc.perform(post("/api/v1/workflow/stages/" + stage2 + "/decision").with(asUser(APPROVER1)).header("Idempotency-Key", key)
                        .contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"approve\",\"comment\":\"fine\"}"))
                .andExpect(status().isOk()).andExpect(header().string("Idempotent-Replayed", "true"));
        decide(APPROVER1, stage2, "reject").andExpect(status().isUnprocessableEntity())   // N2201 is class N2 (ADR-020)
                .andExpect(jsonPath("$.code").value("wf.conflicting_decision"));

        complete(stage2);
        advance(instance);
        String stage3 = stageId(instance, 3);
        decide(APPROVER1, stage3, "approve").andExpect(status().isForbidden())
                .andExpect(jsonPath("$.code").value("sod.violation"))
                .andExpect(jsonPath("$.detail").value("You approved an earlier stage of this request, so you cannot approve this one."));
        decide(APPROVER2, stage3, "approve").andExpect(status().isOk()).andExpect(jsonPath("$.stageOutcome").value("approved"));

        mvc.perform(get("/api/v1/workflow/instances/" + instance).with(asUser(VIEWER)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.stages[1].decisions[0].groupCode").value("WF_APPROVERS"))
                .andExpect(jsonPath("$.stages[1].decisions[0].decision").value("approve"));
    }

    @Test
    void enrichmentItemsAreCheckedByTheStagesTask() throws Exception {
        UUID instance = submitted("WF_ENR");
        advance(instance);
        String stage = stageId(instance, 2);
        enrich(ENRICHER, stage, "{\"action\":\"set_property\",\"hierarchyCode\":\"WF_H\",\"nodeId\":\"" + LEAF
                + "\",\"propertyCode\":\"WF.Note\",\"payload\":{\"value\":\"enriched\"}}")
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.seq").value(2))
                .andExpect(jsonPath("$.payload.expected.present").value(false));
        enrich(ENRICHER, stage, "{\"action\":\"update_node\",\"hierarchyCode\":\"WF_H\",\"nodeId\":\"" + LEAF
                + "\",\"payload\":{\"description\":\"not allowed here\"}}")
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.code").value("wf.item_not_editable"));
        enrich(ENRICHER, stage, "{\"action\":\"add_node\",\"hierarchyCode\":\"WF_H\",\"targetParentId\":\"" + TOP
                + "\",\"payload\":{\"nodeKind\":\"legal_entity\",\"name\":\"WF new\"}}")
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("enrichment.action_not_supported"));
        enrich(APPROVER1, stage, "{\"action\":\"set_property\",\"hierarchyCode\":\"WF_H\",\"nodeId\":\"" + LEAF
                + "\",\"propertyCode\":\"WF.Note\",\"payload\":{\"value\":\"x\"}}")
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.code").value("entitlement.missing"));
    }

    @Test
    void anUnknownStageIsNotFound() throws Exception {
        decide(APPROVER1, UUID.randomUUID().toString(), "approve").andExpect(status().isNotFound());
    }

    // ------------------------------------------------------------------ helpers

    private static void model(JdbcClient jdbc, String code, String[] types, String[] groups) {
        UUID model = jdbc.sql("INSERT INTO wf.workflow_model (model_code, label) VALUES (:c, :c) RETURNING model_id").param("c", code).query(UUID.class).single();
        for (int s = 0; s < types.length; s++) {
            String task = switch (types[s]) { case "approve" -> "WF_APPROVE"; case "enrich" -> "WF_ENRICH"; default -> null; };
            UUID stage = jdbc.sql("""
                    INSERT INTO wf.workflow_stage (model_id, seq, stage_type, label, task_id, separation_of_duties)
                    VALUES (:m, :seq, CAST(:type AS wf.stage_type), :label, (SELECT task_id FROM wf.workflow_task WHERE task_code = :task), :sod)
                    RETURNING stage_id
                    """).param("m", model).param("seq", s + 1).param("type", types[s]).param("label", code + " " + (s + 1))
                    .param("task", task).param("sod", "approve".equals(types[s])).query(UUID.class).single();
            if (groups[s] != null) {
                jdbc.sql("INSERT INTO wf.stage_group (stage_id, group_id) SELECT :s, group_id FROM wf.user_group WHERE group_code = :g")
                        .param("s", stage).param("g", groups[s]).update();
            }
        }
        jdbc.sql("INSERT INTO wf.submit_task SELECT :m, task_id FROM wf.workflow_task WHERE task_code = 'WF_SUBMIT'").param("m", model).update();
        jdbc.sql("UPDATE wf.workflow_model SET status = 'active', activated_by = :a WHERE model_id = :m")
                .param("a", ensureUser(VIEWER, "human")).param("m", model).update();
    }

    private UUID submitted(String model) throws Exception {
        MvcResult r = mvc.perform(post("/api/v1/change-requests").with(asUser(STEWARD)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"versionName\":\"WF working\",\"title\":\"WF " + model + "\",\"workflowModelCode\":\"" + model + "\"}"))
                .andExpect(status().isCreated()).andReturn();
        String id = mapper.readTree(r.getResponse().getContentAsString()).get("id").asText();
        mvc.perform(post("/api/v1/change-requests/" + id + "/items").with(asUser(STEWARD)).header("If-Match", etag(id))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"action\":\"update_node\",\"hierarchyCode\":\"WF_H\",\"nodeId\":\"" + LEAF
                                + "\",\"payload\":{\"description\":\"WF " + UUID.randomUUID() + "\"}}"))
                .andExpect(status().isCreated());
        mvc.perform(post("/api/v1/change-requests/" + id + "/submit").with(asUser(STEWARD)).header("If-Match", etag(id)))
                .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("in_review"));
        return ownerJdbc().sql("SELECT instance_id FROM wf.workflow_instance WHERE change_request_id = CAST(:cr AS uuid)")
                .param("cr", id).query(UUID.class).single();
    }

    private void advance(UUID instance) {
        ownerJdbc().sql("SELECT action FROM wf.advance_instance(:i)").param("i", instance).query(String.class).single();
    }

    private void complete(String stage) {
        ownerJdbc().sql("SELECT wf.complete_stage(CAST(:s AS uuid))").param("s", stage).query(String.class).single();
    }

    private String stageId(UUID instance, int seq) {
        return ownerJdbc().sql("SELECT instance_stage_id FROM wf.instance_stage WHERE instance_id = :i AND seq = :s")
                .param("i", instance).param("s", seq).query(UUID.class).single().toString();
    }

    private ResultActions decide(String login, String stage, String decision) throws Exception {
        return mvc.perform(post("/api/v1/workflow/stages/" + stage + "/decision").with(asUser(login))
                .contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"" + decision + "\"}"));
    }

    private ResultActions enrich(String login, String stage, String body) throws Exception {
        return mvc.perform(post("/api/v1/workflow/stages/" + stage + "/items").with(asUser(login))
                .contentType(MediaType.APPLICATION_JSON).content(body));
    }

    private String etag(String id) throws Exception {
        return mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(STEWARD))).andReturn().getResponse().getHeader("ETag");
    }
}
