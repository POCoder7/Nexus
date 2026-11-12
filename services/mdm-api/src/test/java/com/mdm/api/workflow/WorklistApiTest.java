package com.mdm.api.workflow;

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

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** GOV-13 worklist (Phase 2 increment 2-9): each view for sample users, SoD, claims, overdue, counts, search, paging. */
class WorklistApiTest extends PostgresIntegrationTest {

    static final UUID TOP = UUID.fromString("00000000-0000-0000-0000-0000000f7001");
    static final UUID LEAF = UUID.fromString("00000000-0000-0000-0000-0000000f7002");
    static final String STEWARD = "wl_steward";
    static final String A1 = "wl_approver1";
    static final String A2 = "wl_approver2";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    String urgent;
    String plain;
    String draft;

    @BeforeEach
    void seed() throws Exception {
        JdbcClient jdbc = ownerJdbc();
        grant(STEWARD, "STEWARD", null, null);
        grant(A1, "APPROVER", null, null);
        grant(A2, "APPROVER", null, null);
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'WL_H'").query(Integer.class).single() == 0) {
            jdbc.sql("INSERT INTO mdm.version (version_name, business_as_of) VALUES ('WL working', current_date)").update();
            jdbc.sql("INSERT INTO mdm.node (node_id, node_kind) VALUES (:t, 'structural'), (:l, 'legal_entity')").param("t", TOP).param("l", LEAF).update();
            jdbc.sql("INSERT INTO mdm.node_attr (node_id, node_name, valid_period) VALUES (:t, 'WL top', daterange('2020-01-01', NULL)), (:l, 'WL leaf', daterange('2020-01-01', NULL))")
                    .param("t", TOP).param("l", LEAF).update();
            jdbc.sql("INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, top_node_id) VALUES ('WL_H', 'Worklist', :t)").param("t", TOP).update();
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, valid_period)
                    SELECT hierarchy_id, :t, :l, daterange('2020-01-01', NULL) FROM mdm.hierarchy WHERE hierarchy_code = 'WL_H'
                    """).param("t", TOP).param("l", LEAF).update();
            jdbc.sql("INSERT INTO wf.user_group (group_code, name) VALUES ('WL_APPROVERS', 'Approvers'), ('WL_COMMITTERS', 'Committers')").update();
            for (String[] m : new String[][] {{"WL_APPROVERS", A1}, {"WL_APPROVERS", A2}, {"WL_COMMITTERS", A2}}) {
                jdbc.sql("INSERT INTO wf.user_group_member (group_id, user_id) SELECT group_id, :u FROM wf.user_group WHERE group_code = :g")
                        .param("u", ensureUser(m[1], "human")).param("g", m[0]).update();
            }
            jdbc.sql("INSERT INTO wf.workflow_task (task_code, label, allowed_actions) VALUES ('WL_SUBMIT', 'Submit', '{update_node}'), ('WL_APPROVE', 'Approve', '{}')").update();
            UUID model = jdbc.sql("INSERT INTO wf.workflow_model (model_code, label) VALUES ('WL_TWO', 'Two approvals') RETURNING model_id").query(UUID.class).single();
            String[] types = {"submit", "approve", "approve", "commit"};
            String[] groups = {null, "WL_APPROVERS", "WL_APPROVERS", "WL_COMMITTERS"};
            for (int s = 0; s < types.length; s++) {
                UUID stage = jdbc.sql("""
                        INSERT INTO wf.workflow_stage (model_id, seq, stage_type, label, task_id, separation_of_duties, stage_duration)
                        VALUES (:m, :seq, CAST(:type AS wf.stage_type), :label,
                                CASE WHEN :type = 'approve' THEN (SELECT task_id FROM wf.workflow_task WHERE task_code = 'WL_APPROVE') END,
                                :type = 'approve', interval '2 days')
                        RETURNING stage_id
                        """).param("m", model).param("seq", s + 1).param("type", types[s]).param("label", "WL stage " + (s + 1))
                        .query(UUID.class).single();
                if (groups[s] != null) {
                    jdbc.sql("INSERT INTO wf.stage_group (stage_id, group_id) SELECT :s, group_id FROM wf.user_group WHERE group_code = :g")
                            .param("s", stage).param("g", groups[s]).update();
                }
            }
            jdbc.sql("INSERT INTO wf.submit_task SELECT :m, task_id FROM wf.workflow_task WHERE task_code = 'WL_SUBMIT'").param("m", model).update();
            jdbc.sql("UPDATE wf.workflow_model SET status = 'active', activated_by = :a WHERE model_id = :m")
                    .param("a", ensureUser(A1, "human")).param("m", model).update();
        }
        String tag = UUID.randomUUID().toString().substring(0, 8);
        urgent = request("WL urgent " + tag, true, true);
        plain = request("WL plain " + tag, false, true);
        draft = request("WL draft " + tag, false, false);
        advance(urgent);
        advance(plain);
    }

    @Test
    void eachViewShowsTheRightRequests() throws Exception {
        assertThat(ids(A1, "assigned")).contains(urgent, plain);
        assertThat(ids(A1, "urgent")).contains(urgent).doesNotContain(plain);
        assertThat(ids(STEWARD, "submitted")).contains(urgent, plain).doesNotContain(draft);
        assertThat(ids(STEWARD, "drafted")).contains(draft).doesNotContain(urgent);
        assertThat(ids(STEWARD, "assigned")).doesNotContain(urgent, plain);      // a requester is never assigned their own request

        // a claim takes the stage out of the other approver's list
        mvc.perform(post("/api/v1/workflow/stages/" + stage(plain, 2) + "/claim").with(asUser(A1))).andExpect(status().isNoContent());
        assertThat(ids(A1, "claimed")).contains(plain);
        assertThat(ids(A2, "assigned")).contains(urgent).doesNotContain(plain);

        // SoD: after approving the first stage, A1 is not assigned the second but still sees the request as participated
        mvc.perform(post("/api/v1/workflow/stages/" + stage(urgent, 2) + "/decision").with(asUser(A1)).contentType(MediaType.APPLICATION_JSON)
                .content("{\"decision\":\"approve\"}")).andExpect(status().isOk());
        ownerJdbc().sql("SELECT wf.complete_stage(:s)").param("s", stage(urgent, 2)).query(String.class).single();
        advance(urgent);
        assertThat(ids(A1, "assigned")).doesNotContain(urgent);
        assertThat(ids(A1, "participated")).contains(urgent);
        assertThat(ids(A2, "assigned")).contains(urgent);

        // overdue
        ownerJdbc().sql("UPDATE wf.instance_stage SET due_at = now() - interval '1 hour' WHERE instance_stage_id = :s")
                .param("s", stage(plain, 2)).update();
        assertThat(ids(A1, "overdue")).contains(plain);
        assertThat(ids(A2, "overdue")).doesNotContain(plain);
    }

    @Test
    void countsSearchAndPaging() throws Exception {
        JsonNode page = page(A1, "assigned", "&search=" + titleOf(urgent).substring(0, 14), 50, null);
        assertThat(page.path("items").size()).isEqualTo(1);
        assertThat(page.path("counts").size()).isEqualTo(9);
        assertThat(page.path("counts").path("notified").asLong()).isZero();
        assertThat(page.path("counts").path("assigned").asLong()).isEqualTo(1);

        // every row of the 'all' view exactly once, one per page
        List<String> seen = new ArrayList<>();
        String cursor = null;
        for (int i = 0; i < 200; i++) {
            JsonNode p = page(STEWARD, "all", "", 1, cursor);
            p.path("items").forEach(r -> seen.add(r.path("rowId").asText()));
            cursor = p.path("nextCursor").isNull() || p.path("nextCursor").isMissingNode() ? null : p.path("nextCursor").asText();
            if (cursor == null) {
                break;
            }
        }
        Set<String> unique = new HashSet<>(seen);
        assertThat(unique).hasSameSizeAs(seen);
        assertThat(seen.size()).isGreaterThanOrEqualTo(3);
        mvc.perform(get("/api/v1/worklist").param("view", "everything").with(asUser(A1))).andExpect(status().isBadRequest());
    }

    // ------------------------------------------------------------------ helpers

    private List<String> ids(String login, String view) throws Exception {
        List<String> out = new ArrayList<>();
        page(login, view, "", 1000, null).path("items").forEach(r -> out.add(r.path("changeRequestId").asText()));
        return out;
    }

    private JsonNode page(String login, String view, String extra, int limit, String cursor) throws Exception {
        String url = "/api/v1/worklist?view=" + view + "&limit=" + limit + extra + (cursor == null ? "" : "&cursor=" + cursor);
        MvcResult r = mvc.perform(get(url).with(asUser(login))).andExpect(status().isOk()).andReturn();
        return mapper.readTree(r.getResponse().getContentAsString());
    }

    private String request(String title, boolean isUrgent, boolean submit) throws Exception {
        MvcResult r = mvc.perform(post("/api/v1/change-requests").with(asUser(STEWARD)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"versionName\":\"WL working\",\"title\":\"" + title + "\",\"workflowModelCode\":\"WL_TWO\",\"isUrgent\":" + isUrgent + "}"))
                .andExpect(status().isCreated()).andReturn();
        String id = mapper.readTree(r.getResponse().getContentAsString()).get("id").asText();
        if (submit) {
            mvc.perform(post("/api/v1/change-requests/" + id + "/items").with(asUser(STEWARD)).header("If-Match", etag(id))
                            .contentType(MediaType.APPLICATION_JSON)
                            .content("{\"action\":\"update_node\",\"hierarchyCode\":\"WL_H\",\"nodeId\":\"" + LEAF
                                    + "\",\"payload\":{\"description\":\"" + title + "\"}}"))
                    .andExpect(status().isCreated());
            mvc.perform(post("/api/v1/change-requests/" + id + "/submit").with(asUser(STEWARD)).header("If-Match", etag(id)))
                    .andExpect(status().isOk());
        }
        return id;
    }

    private void advance(String changeRequest) {
        ownerJdbc().sql("SELECT action FROM wf.advance_instance((SELECT instance_id FROM wf.workflow_instance WHERE change_request_id = CAST(:cr AS uuid)))")
                .param("cr", changeRequest).query(String.class).single();
    }

    private UUID stage(String changeRequest, int seq) {
        return ownerJdbc().sql("""
                SELECT ist.instance_stage_id FROM wf.instance_stage ist JOIN wf.workflow_instance i ON i.instance_id = ist.instance_id
                WHERE i.change_request_id = CAST(:cr AS uuid) AND ist.seq = :s
                """).param("cr", changeRequest).param("s", seq).query(UUID.class).single();
    }

    private String titleOf(String changeRequest) {
        return ownerJdbc().sql("SELECT title FROM mdm.change_request WHERE change_request_id = CAST(:cr AS uuid)")
                .param("cr", changeRequest).query(String.class).single();
    }

    private String etag(String id) throws Exception {
        return mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(STEWARD))).andReturn().getResponse().getHeader("ETag");
    }
}
