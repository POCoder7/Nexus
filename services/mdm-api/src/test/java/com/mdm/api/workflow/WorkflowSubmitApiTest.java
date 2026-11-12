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

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** Phase 2 increment 2-8a: submit with a workflow model, urgent flag, withdraw through the workflow, requires_workflow. */
class WorkflowSubmitApiTest extends PostgresIntegrationTest {

    static final UUID TOP = UUID.fromString("00000000-0000-0000-0000-0000000f5001");
    static final UUID LEAF = UUID.fromString("00000000-0000-0000-0000-0000000f5002");
    static final UUID MODEL = UUID.fromString("00000000-0000-0000-0000-0000000f5010");
    static final String STEWARD = "ws_steward";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    @BeforeEach
    void seed() {
        JdbcClient jdbc = ownerJdbc();
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'WS_H'").query(Integer.class).single() == 0) {
            jdbc.sql("INSERT INTO mdm.version (version_name, business_as_of) VALUES ('WS working', current_date)").update();
            jdbc.sql("INSERT INTO mdm.node (node_id, node_kind) VALUES (:t, 'structural'), (:l, 'legal_entity')")
                    .param("t", TOP).param("l", LEAF).update();
            jdbc.sql("""
                    INSERT INTO mdm.node_attr (node_id, node_name, valid_period)
                    VALUES (:t, 'WS top', daterange('2020-01-01', NULL)), (:l, 'WS leaf', daterange('2020-01-01', NULL))
                    """).param("t", TOP).param("l", LEAF).update();
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, top_node_id, requires_workflow)
                    VALUES ('WS_H', 'Free', :t, false), ('WS_GOV', 'Governed', :t, true)
                    """).param("t", TOP).update();
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, valid_period)
                    SELECT hierarchy_id, :t, :l, daterange('2020-01-01', NULL) FROM mdm.hierarchy WHERE hierarchy_code IN ('WS_H', 'WS_GOV')
                    """).param("t", TOP).param("l", LEAF).update();
            UUID admin = ensureUser("ws_admin", "human");
            jdbc.sql("INSERT INTO wf.user_group (group_code, name) VALUES ('WS_APPROVERS', 'Approvers') ON CONFLICT DO NOTHING").update();
            jdbc.sql("INSERT INTO wf.workflow_task (task_code, label, allowed_actions) VALUES ('WS_TASK', 'Task', '{update_node}')").update();
            jdbc.sql("INSERT INTO wf.workflow_model (model_id, model_code, label) VALUES (:m, 'WS_MODEL', 'Approve then commit')")
                    .param("m", MODEL).update();
            jdbc.sql("""
                    INSERT INTO wf.workflow_stage (model_id, seq, stage_type, label, task_id)
                    SELECT :m, s, (ARRAY['submit', 'approve', 'commit'])[s]::wf.stage_type, 'Stage ' || s,
                           CASE WHEN s = 2 THEN (SELECT task_id FROM wf.workflow_task WHERE task_code = 'WS_TASK') END
                    FROM generate_series(1, 3) s
                    """).param("m", MODEL).update();
            jdbc.sql("INSERT INTO wf.submit_task SELECT :m, task_id FROM wf.workflow_task WHERE task_code = 'WS_TASK'").param("m", MODEL).update();
            jdbc.sql("""
                    INSERT INTO wf.stage_group (stage_id, group_id)
                    SELECT s.stage_id, g.group_id FROM wf.workflow_stage s, wf.user_group g
                    WHERE s.model_id = :m AND s.seq > 1 AND g.group_code = 'WS_APPROVERS'
                    """).param("m", MODEL).update();
            jdbc.sql("UPDATE wf.workflow_model SET status = 'active', activated_by = :a WHERE model_id = :m")
                    .param("a", admin).param("m", MODEL).update();
        }
        grant(STEWARD, "STEWARD", "WS_H", null);
        grant(STEWARD, "STEWARD", "WS_GOV", null);
    }

    @Test
    void anUnknownWorkflowModelIsRefused() throws Exception {
        mvc.perform(post("/api/v1/change-requests").with(asUser(STEWARD)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"versionName\":\"WS working\",\"title\":\"WS bad model\",\"workflowModelCode\":\"NO_SUCH_MODEL\"}"))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("workflow.unknown_model"));
    }

    @Test
    void submittingWithAModelStartsTheWorkflowAndWithdrawGoesThroughIt() throws Exception {
        String id = create("{\"versionName\":\"WS working\",\"title\":\"WS governed\",\"workflowModelCode\":\"WS_MODEL\",\"isUrgent\":true}");
        mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(STEWARD)))
                .andExpect(jsonPath("$.workflowModelCode").value("WS_MODEL"))
                .andExpect(jsonPath("$.isUrgent").value(true));
        addItem(id, "WS_H").andExpect(status().isCreated());
        mvc.perform(post("/api/v1/change-requests/" + id + "/submit").with(asUser(STEWARD)).header("If-Match", etag(id)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("in_review"))
                .andExpect(jsonPath("$.governedByWorkflow").value(true));
        assertThat(instanceStatus(id)).isEqualTo("in_flight");

        mvc.perform(patch("/api/v1/change-requests/" + id).with(asUser(STEWARD)).header("If-Match", etag(id))
                        .contentType(MediaType.APPLICATION_JSON).content("{\"isUrgent\":false}"))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("change_request.not_draft"));

        mvc.perform(post("/api/v1/change-requests/" + id + "/withdraw").with(asUser(STEWARD)).header("If-Match", etag(id)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("withdrawn"));
        assertThat(instanceStatus(id)).isEqualTo("withdrawn");
    }

    @Test
    void aHierarchyThatRequiresAWorkflowCannotBeSubmittedWithoutOne() throws Exception {
        String id = create("{\"versionName\":\"WS working\",\"title\":\"WS no model\"}");
        addItem(id, "WS_GOV").andExpect(status().isCreated());
        mvc.perform(post("/api/v1/change-requests/" + id + "/submit").with(asUser(STEWARD)).header("If-Match", etag(id)))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("change_request.workflow_required"));
        mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(STEWARD))).andExpect(jsonPath("$.status").value("draft"));
    }

    // ------------------------------------------------------------------ helpers

    private String create(String body) throws Exception {
        MvcResult r = mvc.perform(post("/api/v1/change-requests").with(asUser(STEWARD)).contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isCreated()).andReturn();
        return mapper.readTree(r.getResponse().getContentAsString()).get("id").asText();
    }

    private ResultActions addItem(String id, String hierarchy) throws Exception {
        return mvc.perform(post("/api/v1/change-requests/" + id + "/items").with(asUser(STEWARD)).header("If-Match", etag(id))
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"action\":\"update_node\",\"hierarchyCode\":\"" + hierarchy + "\",\"nodeId\":\"" + LEAF
                        + "\",\"payload\":{\"description\":\"WS described " + UUID.randomUUID() + "\"}}"));
    }

    private String etag(String id) throws Exception {
        return mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(STEWARD))).andReturn().getResponse().getHeader("ETag");
    }

    private String instanceStatus(String changeRequest) {
        return ownerJdbc().sql("SELECT status::text FROM wf.workflow_instance WHERE change_request_id = CAST(:cr AS uuid)")
                .param("cr", changeRequest).query(String.class).single();
    }
}
