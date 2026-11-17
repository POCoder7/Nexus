package com.mdm.api.changerequest;

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
import org.springframework.test.web.servlet.ResultActions;

import java.util.UUID;

import static org.hamcrest.Matchers.hasItem;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Governed access changes through the API (ADR-042 D3; Phase 5 LLD §19.4, §19.9): an ADMIN proposes, another ADMIN
 * decides, apply writes the group, its scope and its member; non-ADMINs neither propose, see nor decide them.
 */
class AccessChangeApiTest extends PostgresIntegrationTest {

    static final UUID TOP = UUID.fromString("00000000-0000-0000-0000-0000000acc01");
    static final String ADMIN1 = "ac_admin1";
    static final String ADMIN2 = "ac_admin2";
    static final String APPROVER = "ac_approver";   // APPROVER on every hierarchy, not ADMIN
    static final String EDITOR = "ac_editor";
    static final String USER = "ac_user";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    @BeforeEach
    void seed() {
        JdbcClient jdbc = ownerJdbc();
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'AC_H'").query(Integer.class).single() == 0) {
            jdbc.sql("INSERT INTO mdm.version (version_name, business_as_of) VALUES ('AC working', current_date)").update();
            jdbc.sql("INSERT INTO mdm.node (node_id, node_kind) VALUES (:t, 'structural')").param("t", TOP).update();
            jdbc.sql("INSERT INTO mdm.node_attr (node_id, node_name, allows_children, valid_period) VALUES (:t, 'AC top', true, daterange('2020-01-01', NULL))")
                    .param("t", TOP).update();
            jdbc.sql("INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, top_node_id) VALUES ('AC_H', 'Access', :t)")
                    .param("t", TOP).update();
        }
        grant(ADMIN1, "ADMIN", null, null);
        grant(ADMIN2, "ADMIN", null, null);
        grant(APPROVER, "APPROVER", null, null);
        grant(EDITOR, "EDITOR", "AC_H", null);
        ensureUser(USER, "human");
    }

    @Test
    void anAdminProposesAnotherAdminDecidesAndTheGroupGrantsItsRole() throws Exception {
        String id = create(ADMIN1, "AC viewers group");
        addItem(ADMIN1, id, "{\"action\":\"create_group\",\"payload\":{\"group\":\"AC_VIEWERS\",\"name\":\"AC viewers\",\"role\":\"VIEWER\"}}")
                .andExpect(status().isCreated());
        addItem(ADMIN1, id, "{\"action\":\"add_group_scope\",\"payload\":{\"group\":\"AC_VIEWERS\",\"hierarchy\":\"AC_H\"}}")
                .andExpect(status().isCreated());
        addItem(ADMIN1, id, "{\"action\":\"add_group_member\",\"payload\":{\"group\":\"AC_VIEWERS\",\"user\":\"" + USER + "\"}}")
                .andExpect(status().isCreated());
        submit(ADMIN1, id).andExpect(status().isOk()).andExpect(jsonPath("$.status").value("submitted"));

        mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(APPROVER))).andExpect(status().isNotFound());
        mvc.perform(get("/api/v1/change-requests").param("mine", "false").with(asUser(ADMIN2)))
                .andExpect(status().isOk()).andExpect(jsonPath("$.items[*].id", hasItem(id)));
        decide(ADMIN1, id, "approve").andExpect(status().isForbidden()).andExpect(jsonPath("$.code").value("maker_checker.self_decision"));

        decide(ADMIN2, id, "approve").andExpect(status().isOk()).andExpect(jsonPath("$.status").value("applied"));
        mvc.perform(get("/api/v1/me").with(asUser(USER)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.groups[0]").value("AC_VIEWERS"))
                .andExpect(jsonPath("$.grants[0].roleCode").value("VIEWER"))
                .andExpect(jsonPath("$.grants[0].hierarchyCode").value("AC_H"))
                .andExpect(jsonPath("$.grants[0].sourceGroup").value("AC_VIEWERS"));
    }

    @Test
    void onlyAdminsProposeAccessChanges() throws Exception {
        String id = create(EDITOR, "AC editor tries");
        addItem(EDITOR, id, "{\"action\":\"grant_role\",\"payload\":{\"user\":\"" + USER + "\",\"role\":\"VIEWER\"}}")
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.code").value("entitlement.missing"));
    }

    @Test
    void nobodyProposesAccessForThemselves() throws Exception {
        String id = create(ADMIN1, "AC self");
        addItem(ADMIN1, id, "{\"action\":\"grant_role\",\"payload\":{\"user\":\"" + ADMIN1 + "\",\"role\":\"VIEWER\"}}")
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.code").value("access.self_grant"));
    }

    @Test
    void anApproverForEveryHierarchyDoesNotDecideAccess() throws Exception {
        String id = create(ADMIN1, "AC approver tries");
        addItem(ADMIN1, id, "{\"action\":\"grant_role\",\"payload\":{\"user\":\"" + USER + "\",\"role\":\"VIEWER\",\"hierarchy\":\"AC_H\"}}")
                .andExpect(status().isCreated());
        submit(ADMIN1, id).andExpect(status().isOk());
        mvc.perform(post("/api/v1/change-requests/" + id + "/decision").with(asUser(APPROVER)).header("If-Match", etag(ADMIN1, id))
                        .contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"approve\"}"))
                .andExpect(status().isNotFound());   // not visible to them at all
    }

    @Test
    void accessChangesStandAlone() throws Exception {
        String id = create(ADMIN1, "AC mixed");
        addItem(ADMIN1, id, "{\"action\":\"grant_role\",\"payload\":{\"user\":\"" + USER + "\",\"role\":\"VIEWER\"}}")
                .andExpect(status().isCreated());
        addItem(ADMIN1, id, "{\"action\":\"update_node\",\"hierarchyCode\":\"AC_H\",\"nodeId\":\"" + TOP + "\",\"payload\":{\"name\":\"AC renamed\"}}")
                .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.code").value("access.mixed_request"));
    }

    @Test
    void holderKindsAreCheckedWhenTheItemIsAdded() throws Exception {
        String id = create(ADMIN1, "AC consumer for a person");
        addItem(ADMIN1, id, "{\"action\":\"grant_role\",\"payload\":{\"user\":\"" + USER + "\",\"role\":\"CONSUMER\"}}")
                .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.code").value("roles.holder_kind"));
        addItem(ADMIN1, id, "{\"action\":\"add_group_member\",\"payload\":{\"group\":\"NO_SUCH\",\"user\":\"" + USER + "\"}}")
                .andExpect(status().isBadRequest());
    }

    // ------------------------------------------------------------------ helpers

    private String create(String login, String title) throws Exception {
        MvcResult r = mvc.perform(post("/api/v1/change-requests").with(asUser(login)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"versionName\":\"AC working\",\"title\":\"" + title + "\"}"))
                .andExpect(status().isCreated()).andReturn();
        return json(r).get("id").asText();
    }

    private ResultActions addItem(String login, String id, String body) throws Exception {
        return mvc.perform(post("/api/v1/change-requests/" + id + "/items").with(asUser(login)).header("If-Match", etag(login, id))
                .contentType(MediaType.APPLICATION_JSON).content(body));
    }

    private ResultActions submit(String login, String id) throws Exception {
        return mvc.perform(post("/api/v1/change-requests/" + id + "/submit").with(asUser(login)).header("If-Match", etag(login, id)));
    }

    private ResultActions decide(String login, String id, String decision) throws Exception {
        return mvc.perform(post("/api/v1/change-requests/" + id + "/decision").with(asUser(login)).header("If-Match", etag(login, id))
                .contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"" + decision + "\",\"note\":\"AC test\"}"));
    }

    private String etag(String login, String id) throws Exception {
        return mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(login))).andReturn().getResponse().getHeader("ETag");
    }

    private JsonNode json(MvcResult r) throws Exception {
        return mapper.readTree(r.getResponse().getContentAsString());
    }
}
