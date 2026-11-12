package com.mdm.api.workflow;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.PostgresIntegrationTest;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.UUID;

import static org.hamcrest.Matchers.hasItem;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** Phase 2 increment 2-8c: model and commit-policy administration through the API, four-eyes enforced by the database. */
class WorkflowAdminApiTest extends PostgresIntegrationTest {

    static final String ADMIN1 = "wa_admin1";
    static final String ADMIN2 = "wa_admin2";
    static final String POLICY_ADMIN = "wa_policy_admin";
    static final String APPROVER = "wa_policy_approver";
    static final String STEWARD = "wa_steward";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    @BeforeEach
    void seed() {
        grant(ADMIN1, "WORKFLOW_ADMIN", null, null);
        grant(ADMIN2, "WORKFLOW_ADMIN", null, null);
        grant(POLICY_ADMIN, "POLICY_ADMIN", null, null);
        grant(STEWARD, "STEWARD", null, null);
        UUID approver = ensureUser(APPROVER, "human");
        ownerJdbc().sql("""
                INSERT INTO wf.user_group (group_code, name) VALUES ('T_APPROVERS', 'Approvers'), ('T_COMMITTERS', 'Committers'),
                                                                   ('WA_OWNERS', 'Policy owners')
                ON CONFLICT (group_code) DO NOTHING
                """).update();
        ownerJdbc().sql("""
                INSERT INTO wf.user_group_member (group_id, user_id)
                SELECT group_id, :u FROM wf.user_group g WHERE group_code = 'POLICY_APPROVERS'
                  AND NOT EXISTS (SELECT 1 FROM wf.user_group_member m WHERE m.group_id = g.group_id AND m.user_id = :u)
                """).param("u", approver).update();
    }

    @Test
    void modelsAreLoadedByOneAdministratorAndActivatedByAnother() throws Exception {
        String definition;
        try (InputStream in = getClass().getResourceAsStream("/workflow/t_add_leaf.json")) {
            definition = new String(in.readAllBytes(), StandardCharsets.UTF_8).replace("\"T_ADD_LEAF\"", "\"WA_ADD_LEAF\"");
        }
        mvc.perform(post("/api/v1/admin/workflow-models").with(asUser(STEWARD)).contentType(MediaType.APPLICATION_JSON).content(definition))
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.code").value("entitlement.missing"));
        MvcResult r = mvc.perform(post("/api/v1/admin/workflow-models").with(asUser(ADMIN1)).contentType(MediaType.APPLICATION_JSON).content(definition))
                .andExpect(status().isCreated()).andReturn();
        String id = mapper.readTree(r.getResponse().getContentAsString()).get("id").asText();
        mvc.perform(post("/api/v1/admin/workflow-models/" + id + "/activate").with(asUser(ADMIN1)))
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.code").value("wf.model_self_activation"));
        mvc.perform(post("/api/v1/admin/workflow-models/" + id + "/activate").with(asUser(ADMIN2))).andExpect(status().isNoContent());
        mvc.perform(get("/api/v1/admin/workflow-models").with(asUser(ADMIN1)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items[?(@.code == 'WA_ADD_LEAF')].status", hasItem("active")))
                .andExpect(jsonPath("$.items[?(@.code == 'WA_ADD_LEAF')].activatedBy", hasItem(ensureUser(ADMIN2, "human").toString())));
    }

    @Test
    void policiesAreProposedSubmittedAndApprovedByDifferentPeople() throws Exception {
        String code = "WA_P_" + UUID.randomUUID().toString().substring(0, 8);
        String shadow = propose(code, "shadow");
        mvc.perform(post("/api/v1/admin/commit-policies/" + shadow + "/submit").with(asUser(POLICY_ADMIN))).andExpect(status().isNoContent());
        mvc.perform(post("/api/v1/admin/commit-policies/" + shadow + "/approve").with(asUser(POLICY_ADMIN)))
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.code").value("maker_checker.self_decision"));
        mvc.perform(post("/api/v1/admin/commit-policies/" + shadow + "/approve").with(asUser(APPROVER))
                        .contentType(MediaType.APPLICATION_JSON).content("{\"note\":\"shadow first\"}"))
                .andExpect(status().isNoContent());
        mvc.perform(get("/api/v1/admin/commit-policies").with(asUser(POLICY_ADMIN)))
                .andExpect(jsonPath("$.items[?(@.code == '" + code + "')].status", hasItem("approved")));

        mvc.perform(post("/api/v1/admin/commit-policies/" + code + "/kill-switch").with(asUser(STEWARD))
                        .contentType(MediaType.APPLICATION_JSON).content("{\"reason\":\"not mine to stop\"}"))
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.code").value("policy.kill_switch_not_allowed"));
        mvc.perform(post("/api/v1/admin/commit-policies/" + code + "/kill-switch").with(asUser(APPROVER))
                        .contentType(MediaType.APPLICATION_JSON).content("{\"reason\":\"test stop\"}"))
                .andExpect(status().isNoContent());

        String active = propose(code + "_A", "active");
        mvc.perform(post("/api/v1/admin/commit-policies/" + active + "/submit").with(asUser(POLICY_ADMIN))).andExpect(status().isNoContent());
        mvc.perform(post("/api/v1/admin/commit-policies/" + active + "/approve").with(asUser(APPROVER)))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("policy.activation_not_allowed"));
    }

    @Test
    void hardLimitsAndRolesAreEnforced() throws Exception {
        mvc.perform(post("/api/v1/admin/commit-policies").with(asUser(STEWARD)).contentType(MediaType.APPLICATION_JSON)
                        .content(body("WA_NO_ROLE", "shadow", "add_node")))
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.code").value("entitlement.missing"));
        mvc.perform(post("/api/v1/admin/commit-policies").with(asUser(POLICY_ADMIN)).contentType(MediaType.APPLICATION_JSON)
                        .content(body("WA_MOVES", "shadow", "move_node")))
                .andExpect(status().isUnprocessableEntity());   // hard limit: moves always need a human (CHECK)
    }

    private String propose(String code, String mode) throws Exception {
        MvcResult r = mvc.perform(post("/api/v1/admin/commit-policies").with(asUser(POLICY_ADMIN)).contentType(MediaType.APPLICATION_JSON)
                        .content(body(code, mode, "set_property")))
                .andExpect(status().isCreated()).andReturn();
        return mapper.readTree(r.getResponse().getContentAsString()).get("id").asText();
    }

    private static String body(String code, String mode, String action) {
        return "{\"code\":\"" + code + "\",\"description\":\"Routine notes\",\"rationale\":\"Test only\",\"mode\":\"" + mode
                + "\",\"allowedActions\":[\"" + action + "\"],\"ownerGroupCode\":\"WA_OWNERS\",\"modelCodes\":[\"WA_ADD_LEAF\"]}";
    }
}
