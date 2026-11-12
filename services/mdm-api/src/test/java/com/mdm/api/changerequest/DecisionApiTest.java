package com.mdm.api.changerequest;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.PostgresIntegrationTest;
import com.mdm.api.apply.ApplyService;
import com.mdm.api.apply.ApplySweeper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.ResultActions;

import java.time.LocalDate;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.hasItem;
import static org.hamcrest.Matchers.not;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * SLICE-01 end to end in core mode (Phase 1 LLD §6.2): draft, submit, review queue, decision by a second human, apply,
 * and the read side showing the result; plus maker-checker, scope, rejection, stale base and the sweeper (§6.4).
 */
class DecisionApiTest extends PostgresIntegrationTest {

    static final UUID TOP = UUID.fromString("00000000-0000-0000-0000-0000000de001");
    static final UUID REGION = UUID.fromString("00000000-0000-0000-0000-0000000de002");
    static final UUID ENTITY = UUID.fromString("00000000-0000-0000-0000-0000000de003");
    static final String STEWARD = "de_steward";
    static final String APPROVER = "de_approver";
    static final String BOTH = "de_both";
    static final String VIEWER = "de_viewer";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;
    @Autowired
    ApplyService applyService;
    @Autowired
    JdbcClient appJdbc;

    @BeforeEach
    void seed() {
        JdbcClient jdbc = ownerJdbc();
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'DE_H'").query(Integer.class).single() == 0) {
            jdbc.sql("INSERT INTO mdm.version (version_name, business_as_of) VALUES ('DE working', current_date)").update();
            jdbc.sql("INSERT INTO mdm.node (node_id, node_kind) VALUES (:t, 'structural'), (:r, 'structural'), (:e, 'legal_entity')")
                    .param("t", TOP).param("r", REGION).param("e", ENTITY).update();
            jdbc.sql("""
                    INSERT INTO mdm.node_attr (node_id, node_name, allows_children, valid_period)
                    VALUES (:t, 'DE group', true, daterange('2020-01-01', NULL)), (:r, 'DE region', true, daterange('2020-01-01', NULL)),
                           (:e, 'DE entity', false, daterange('2020-01-01', NULL))
                    """).param("t", TOP).param("r", REGION).param("e", ENTITY).update();
            jdbc.sql("INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, top_node_id) VALUES ('DE_H', 'Decisions', :t)")
                    .param("t", TOP).update();
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, valid_period)
                    SELECT hierarchy_id, p, c, daterange('2020-01-01', NULL)
                    FROM mdm.hierarchy, (VALUES (CAST(:t AS uuid), CAST(:r AS uuid)), (:r, :e)) AS v(p, c)
                    WHERE hierarchy_code = 'DE_H'
                    """).param("t", TOP).param("r", REGION).param("e", ENTITY).update();
            jdbc.sql("""
                    INSERT INTO mdm.property_definition (property_code, label, data_type, scope)
                    VALUES ('DE.Ccy', 'Currency', 'string', 'global'), ('DE.Two', 'Contested', 'string', 'global')
                    """).update();
        }
        grant(STEWARD, "STEWARD", "DE_H", null);
        grant(APPROVER, "APPROVER", "DE_H", null);
        grant(BOTH, "STEWARD", "DE_H", null);
        grant(BOTH, "APPROVER", "DE_H", null);
        grant(VIEWER, "VIEWER", "DE_H", null);
    }

    @Test
    void draftSubmitApproveAndTheChangeIsLive() throws Exception {
        String id = create(STEWARD, "DE add an entity");
        MvcResult added = addItem(STEWARD, id, "{\"action\":\"add_node\",\"hierarchyCode\":\"DE_H\",\"targetParentId\":\"" + REGION
                + "\",\"payload\":{\"nodeKind\":\"legal_entity\",\"name\":\"DE New entity\",\"isLeaf\":true}}")
                .andExpect(status().isCreated()).andReturn();
        String node = json(added).get("nodeId").asText();
        addItem(STEWARD, id, "{\"action\":\"set_property\",\"hierarchyCode\":\"DE_H\",\"nodeId\":\"" + ENTITY
                + "\",\"propertyCode\":\"DE.Ccy\",\"payload\":{\"value\":\"USD\"}}").andExpect(status().isCreated());
        submit(STEWARD, id).andExpect(status().isOk()).andExpect(jsonPath("$.status").value("submitted"));

        mvc.perform(get("/api/v1/change-requests").param("mine", "false").with(asUser(APPROVER)))
                .andExpect(status().isOk()).andExpect(jsonPath("$.items[*].id", hasItem(id)));
        mvc.perform(get("/api/v1/change-requests").param("mine", "false").with(asUser(VIEWER)))
                .andExpect(status().isOk()).andExpect(jsonPath("$.items[*].id", not(hasItem(id))));

        decide(APPROVER, id, "approve")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("applied"))
                .andExpect(jsonPath("$.decisionBasis").value("human_review"))
                .andExpect(jsonPath("$.appliedAt").exists());

        mvc.perform(get("/api/v1/nodes/" + node).param("hierarchy", "DE_H").with(asUser(VIEWER)))
                .andExpect(status().isOk()).andExpect(jsonPath("$.name").value("DE New entity"));
        mvc.perform(get("/api/v1/nodes/" + node).param("hierarchy", "DE_H")
                        .param("asOf", LocalDate.now().minusDays(2).toString()).with(asUser(VIEWER)))
                .andExpect(status().isNotFound());
        mvc.perform(get("/api/v1/nodes/" + ENTITY).param("hierarchy", "DE_H").with(asUser(VIEWER)))
                .andExpect(jsonPath("$.properties[?(@.code == 'DE.Ccy')].value").value("USD"));
        mvc.perform(get("/api/v1/change-requests").param("mine", "false").with(asUser(APPROVER)))
                .andExpect(jsonPath("$.items[*].id", not(hasItem(id))));
    }

    @Test
    void theRequesterCannotDecideEvenWithTheApproverRole() throws Exception {
        String id = submitted(BOTH, "DE own request", "DE Own");
        decide(BOTH, id, "approve")
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.code").value("maker_checker.self_decision"));
        decide(STEWARD, id, "approve")
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.code").value("entitlement.missing"));
        mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(BOTH))).andExpect(jsonPath("$.status").value("submitted"));
    }

    @Test
    void aDecisionNeedsIfMatchAndAValidDecision() throws Exception {
        String id = submitted(STEWARD, "DE preconditions", "DE Precondition");
        mvc.perform(post("/api/v1/change-requests/" + id + "/decision").with(asUser(APPROVER))
                        .contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"approve\"}"))
                .andExpect(status().is(428));
        mvc.perform(post("/api/v1/change-requests/" + id + "/decision").with(asUser(APPROVER)).header("If-Match", etag(APPROVER, id))
                        .contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"maybe\"}"))
                .andExpect(status().isBadRequest());
    }

    @Test
    void aRejectionChangesNothing() throws Exception {
        String id = submitted(STEWARD, "DE reject me", "DE Rejected entity");
        decide(APPROVER, id, "reject").andExpect(status().isOk()).andExpect(jsonPath("$.status").value("rejected"));
        assertThat(ownerJdbc().sql("SELECT count(*) FROM mdm.node_attr WHERE node_name = 'DE Rejected entity'")
                .query(Integer.class).single()).isZero();
    }

    @Test
    void theSecondOfTwoConflictingRequestsFailsInsteadOfOverwriting() throws Exception {
        String first = setTwo("DE first", "A");
        String second = setTwo("DE second", "B");
        decide(APPROVER, first, "approve").andExpect(jsonPath("$.status").value("applied"));
        MvcResult r = decide(APPROVER, second, "approve")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("apply_failed"))
                .andReturn();
        assertThat(json(r).get("applyError").asText()).startsWith("N3001");
        mvc.perform(get("/api/v1/nodes/" + ENTITY).param("hierarchy", "DE_H").with(asUser(VIEWER)))
                .andExpect(jsonPath("$.properties[?(@.code == 'DE.Two')].value").value("A"));
    }

    @Test
    void theSweeperAppliesARequestLeftApproved() throws Exception {
        String id = submitted(STEWARD, "DE left approved", "DE Swept entity");
        UUID approver = ensureUser(APPROVER, "human");
        ownerJdbc().sql("""
                UPDATE mdm.change_request SET status = 'approved', decided_by = :a, decision_basis = 'human_review',
                       decided_at = now() - interval '2 minutes'
                WHERE change_request_id = CAST(:id AS uuid)
                """).param("a", approver).param("id", id).update();   // as if the API stopped after the decision
        new ApplySweeper(appJdbc, applyService).sweep();
        mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(STEWARD))).andExpect(jsonPath("$.status").value("applied"));
        assertThat(ownerJdbc().sql("SELECT count(*) FROM mdm.node_attr WHERE node_name = 'DE Swept entity'")
                .query(Integer.class).single()).isEqualTo(1);
    }

    // ------------------------------------------------------------------ helpers

    /** Two requests drafted against the same unset value: both expect it absent. */
    private String setTwo(String title, String value) throws Exception {
        String id = create(STEWARD, title);
        addItem(STEWARD, id, "{\"action\":\"set_property\",\"hierarchyCode\":\"DE_H\",\"nodeId\":\"" + ENTITY
                + "\",\"propertyCode\":\"DE.Two\",\"payload\":{\"value\":\"" + value + "\"}}").andExpect(status().isCreated());
        submit(STEWARD, id).andExpect(status().isOk());
        return id;
    }

    private String submitted(String login, String title, String nodeName) throws Exception {
        String id = create(login, title);
        addItem(login, id, "{\"action\":\"add_node\",\"hierarchyCode\":\"DE_H\",\"targetParentId\":\"" + REGION
                + "\",\"payload\":{\"nodeKind\":\"legal_entity\",\"name\":\"" + nodeName + "\",\"isLeaf\":true}}")
                .andExpect(status().isCreated());
        submit(login, id).andExpect(status().isOk());
        return id;
    }

    private String create(String login, String title) throws Exception {
        MvcResult r = mvc.perform(post("/api/v1/change-requests").with(asUser(login)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"versionName\":\"DE working\",\"title\":\"" + title + "\"}"))
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
                .contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"" + decision + "\",\"note\":\"DE test\"}"));
    }

    private String etag(String login, String id) throws Exception {
        return mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(login))).andReturn().getResponse().getHeader("ETag");
    }

    private JsonNode json(MvcResult r) throws Exception {
        return mapper.readTree(r.getResponse().getContentAsString());
    }
}
