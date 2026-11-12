package com.mdm.api.ui;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.PostgresIntegrationTest;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.web.servlet.MockMvc;

import java.time.LocalDate;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.hasItem;
import static org.hamcrest.Matchers.lessThanOrEqualTo;
import static org.hamcrest.Matchers.not;
import static org.hamcrest.Matchers.nullValue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Phase 3 increment 3-1: backend support for the steward UI (LLD §5.1): {@code /me} extension and preferences, Home,
 * in-tree search and path, the submit form, request detail additions and client error reports. Synthetic data only.
 */
class UiSupportApiTest extends PostgresIntegrationTest {

    static final UUID TOP = UUID.fromString("00000000-0000-0000-0000-000000003b01");
    static final UUID ALPHA = UUID.fromString("00000000-0000-0000-0000-000000003b02");
    static final UUID BETA = UUID.fromString("00000000-0000-0000-0000-000000003b03");
    static final UUID GAMMA = UUID.fromString("00000000-0000-0000-0000-000000003b04");
    static final UUID OUTSIDE = UUID.fromString("00000000-0000-0000-0000-000000003b05");
    static final UUID MODEL = UUID.fromString("00000000-0000-0000-0000-000000003b10");
    static final String STEWARD = "ui_steward";
    static final String VIEWER = "ui_viewer";
    static final String POLICY = "ui_policy_admin";
    static final String STRANGER = "ui_stranger";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    @BeforeEach
    void seed() {
        JdbcClient jdbc = ownerJdbc();
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'UI_H'").query(Integer.class).single() == 0) {
            jdbc.sql("INSERT INTO mdm.version (version_name, business_as_of) VALUES ('UI working', current_date) ON CONFLICT DO NOTHING").update();
            jdbc.sql("INSERT INTO mdm.node (node_id, node_kind) VALUES (:t, 'structural'), (:a, 'structural'), (:b, 'legal_entity'), (:g, 'legal_entity'), (:o, 'legal_entity')")
                    .param("t", TOP).param("a", ALPHA).param("b", BETA).param("g", GAMMA).param("o", OUTSIDE).update();
            jdbc.sql("""
                    INSERT INTO mdm.node_attr (node_id, node_name, description, valid_period) VALUES
                      (:t, 'UI top', 'Synthetic top', daterange('2020-01-01', NULL)),
                      (:a, 'UI Alpha region', 'Synthetic region', daterange('2020-01-01', NULL)),
                      (:b, 'UI Beta desk', 'Under 100% alpha', daterange('2020-01-01', NULL)),
                      (:o, 'UI Alpha outsider', 'Not placed', daterange('2020-01-01', NULL)),
                      (:g, 'UI Gamma new', 'Added today', daterange(mdm.business_today(), NULL))
                    """).param("t", TOP).param("a", ALPHA).param("b", BETA).param("g", GAMMA).param("o", OUTSIDE).update();
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, top_node_id, sort_seq)
                    VALUES ('UI_H', 'UI hierarchy', :t, 1), ('UI_OTHER', 'UI other', :t, 2)
                    """).param("t", TOP).update();
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, valid_period)
                    SELECT h.hierarchy_id, v.p, v.c, v.d
                    FROM mdm.hierarchy h,
                         (VALUES (CAST(:t AS uuid), CAST(:a AS uuid), daterange('2020-01-01', NULL)),
                                 (CAST(:a AS uuid), CAST(:b AS uuid), daterange('2020-01-01', NULL)),
                                 (CAST(:b AS uuid), CAST(:g AS uuid), daterange(mdm.business_today(), NULL))) AS v(p, c, d)
                    WHERE h.hierarchy_code = 'UI_H'
                    """).param("t", TOP).param("a", ALPHA).param("b", BETA).param("g", GAMMA).update();

            // A model whose submit task lets the steward set two properties, one required with a list of values.
            jdbc.sql("""
                    INSERT INTO mdm.property_definition (property_code, label, category_code, data_type, scope)
                    VALUES ('UI.Ccy', 'Reporting currency', 'Finance', 'string', 'global'),
                           ('UI.Note', 'Note', 'Finance', 'string', 'global')
                    """).update();
            jdbc.sql("""
                    INSERT INTO mdm.property_list_value (property_id, list_value)
                    SELECT property_id, v FROM mdm.property_definition, (VALUES ('EUR'), ('USD')) AS l(v) WHERE property_code = 'UI.Ccy'
                    """).update();
            UUID admin = ensureUser("ui_admin", "human");
            jdbc.sql("INSERT INTO wf.user_group (group_code, name) VALUES ('UI_APPROVERS', 'Approvers')").update();
            jdbc.sql("INSERT INTO wf.workflow_task (task_code, label, allowed_actions) VALUES ('UI_SUBMIT', 'Submit', '{add_node,set_property}')").update();
            jdbc.sql("""
                    INSERT INTO wf.task_property (task_id, property_id, is_required, sort_seq)
                    SELECT t.task_id, p.property_id, p.property_code = 'UI.Ccy', CASE p.property_code WHEN 'UI.Ccy' THEN 1 ELSE 2 END
                    FROM wf.workflow_task t, mdm.property_definition p
                    WHERE t.task_code = 'UI_SUBMIT' AND p.property_code IN ('UI.Ccy', 'UI.Note')
                    """).update();
            jdbc.sql("INSERT INTO wf.workflow_model (model_id, model_code, label) VALUES (:m, 'UI_ADD_LEAF', 'Add a leaf')")
                    .param("m", MODEL).update();
            jdbc.sql("""
                    INSERT INTO wf.workflow_stage (model_id, seq, stage_type, label)
                    VALUES (:m, 1, 'submit', 'Submit'), (:m, 2, 'commit', 'Commit')
                    """).param("m", MODEL).update();
            jdbc.sql("INSERT INTO wf.submit_task SELECT :m, task_id FROM wf.workflow_task WHERE task_code = 'UI_SUBMIT'").param("m", MODEL).update();
            jdbc.sql("""
                    INSERT INTO wf.stage_group (stage_id, group_id)
                    SELECT s.stage_id, g.group_id FROM wf.workflow_stage s, wf.user_group g
                    WHERE s.model_id = :m AND s.seq = 2 AND g.group_code = 'UI_APPROVERS'
                    """).param("m", MODEL).update();
            jdbc.sql("UPDATE wf.workflow_model SET status = 'active', activated_by = :a WHERE model_id = :m")
                    .param("a", admin).param("m", MODEL).update();
        }
        grant(STEWARD, "STEWARD", "UI_H", null);
        grant(VIEWER, "VIEWER", "UI_H", null);
        grant(POLICY, "POLICY_ADMIN", null, null);
        ensureUser(STRANGER, "human");
    }

    // ------------------------------------------------------------------ /me and preferences

    @Test
    void meCarriesBusinessTodayDefaultPreferencesAndPermissionsPerHierarchy() throws Exception {
        mvc.perform(get("/api/v1/me").with(asUser(STEWARD)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.businessTimeZone").value("America/New_York"))
                .andExpect(jsonPath("$.businessToday").isNotEmpty())
                .andExpect(jsonPath("$.preferences.startPage").value("home"))
                .andExpect(jsonPath("$.preferences.density").value("compact"))
                .andExpect(jsonPath("$.permissions.UI_H").value(hasItem("PROPOSE")))
                .andExpect(jsonPath("$.permissions.UI_H").value(not(hasItem("DECIDE"))));
        mvc.perform(get("/api/v1/me").with(asUser(POLICY)))
                .andExpect(jsonPath("$.permissions['*']").value(hasItem("ADMIN_POLICY")));
    }

    @Test
    void preferencesAreTheCallersOwnAndValidated() throws Exception {
        mvc.perform(put("/api/v1/me/preferences").with(asUser(VIEWER)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"startPage\":\"worklist\",\"lastHierarchyCode\":\"UI_H\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.startPage").value("worklist"))
                .andExpect(jsonPath("$.lastHierarchyCode").value("UI_H"))
                .andExpect(jsonPath("$.density").value("compact"));
        // a partial update keeps the other values
        mvc.perform(put("/api/v1/me/preferences").with(asUser(VIEWER)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"density\":\"comfortable\"}"))
                .andExpect(jsonPath("$.startPage").value("worklist"))
                .andExpect(jsonPath("$.density").value("comfortable"));
        // another user's preferences are untouched
        mvc.perform(get("/api/v1/me").with(asUser(STEWARD))).andExpect(jsonPath("$.preferences.startPage").value("home"));

        mvc.perform(put("/api/v1/me/preferences").with(asUser(VIEWER)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"startPage\":\"admin\"}"))
                .andExpect(status().isBadRequest());
        // a hierarchy the user cannot read is "not found", not revealed
        mvc.perform(put("/api/v1/me/preferences").with(asUser(VIEWER)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"lastHierarchyCode\":\"UI_OTHER\"}"))
                .andExpect(status().isNotFound());
    }

    // ------------------------------------------------------------------ search and path

    @Test
    void searchFindsPlacedNodesByNameOrDescriptionWithTheirPath() throws Exception {
        String body = mvc.perform(get("/api/v1/hierarchies/UI_H/search").param("q", "alpha").with(asUser(VIEWER)))
                .andExpect(status().isOk())
                .andReturn().getResponse().getContentAsString();
        JsonNode items = mapper.readTree(body).get("items");
        // "UI Alpha region" by name, "UI Beta desk" by description ("100% alpha"); the unplaced outsider is not in UI_H
        assertThat(items).extracting(n -> n.get("name").asText()).containsExactly("UI Alpha region", "UI Beta desk");
        JsonNode betaPath = items.get(1).get("path");
        assertThat(betaPath).extracting(n -> n.get("name").asText()).containsExactly("UI top", "UI Alpha region", "UI Beta desk");

        // wildcards in the text are literal: "100%" matches the description, "%" alone needs two characters anyway
        mvc.perform(get("/api/v1/hierarchies/UI_H/search").param("q", "0%").with(asUser(VIEWER)))
                .andExpect(jsonPath("$.items.length()").value(1));
        mvc.perform(get("/api/v1/hierarchies/UI_H/search").param("q", "_I").with(asUser(VIEWER)))
                .andExpect(jsonPath("$.items.length()").value(0));
    }

    @Test
    void searchHonoursTheAsOfDateAndPagesByName() throws Exception {
        LocalDate today = ownerJdbc().sql("SELECT mdm.business_today()").query(LocalDate.class).single();
        mvc.perform(get("/api/v1/hierarchies/UI_H/search").param("q", "Gamma").with(asUser(VIEWER)))
                .andExpect(jsonPath("$.items.length()").value(1))
                .andExpect(jsonPath("$.items[0].path.length()").value(4));
        mvc.perform(get("/api/v1/hierarchies/UI_H/search").param("q", "Gamma").param("asOf", today.minusDays(1).toString())
                        .with(asUser(VIEWER)))
                .andExpect(jsonPath("$.items.length()").value(0));

        String first = mvc.perform(get("/api/v1/hierarchies/UI_H/search").param("q", "UI").param("limit", "2").with(asUser(VIEWER)))
                .andExpect(jsonPath("$.items.length()").value(2))
                .andExpect(jsonPath("$.nextCursor").isNotEmpty())
                .andReturn().getResponse().getContentAsString();
        String cursor = mapper.readTree(first).get("nextCursor").asText();
        mvc.perform(get("/api/v1/hierarchies/UI_H/search").param("q", "UI").param("limit", "2").param("cursor", cursor)
                        .with(asUser(VIEWER)))
                .andExpect(jsonPath("$.items.length()").value(2))
                .andExpect(jsonPath("$.items[0].name").value("UI Gamma new"))
                .andExpect(jsonPath("$.nextCursor").value(nullValue()));
    }

    @Test
    void searchRefusesShortQueriesLargeLimitsAndUnreadableHierarchies() throws Exception {
        mvc.perform(get("/api/v1/hierarchies/UI_H/search").param("q", " a ").with(asUser(VIEWER)))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("search.query_too_short"));
        mvc.perform(get("/api/v1/hierarchies/UI_H/search").param("q", "alpha").param("limit", "51").with(asUser(VIEWER)))
                .andExpect(status().isBadRequest());
        mvc.perform(get("/api/v1/hierarchies/UI_OTHER/search").param("q", "alpha").with(asUser(VIEWER)))
                .andExpect(status().isNotFound());
    }

    @Test
    void pathIsThePrimaryPlacementFromTheTopAndUnknownNodesAreNotFound() throws Exception {
        mvc.perform(get("/api/v1/hierarchies/UI_H/nodes/{id}/path", BETA).with(asUser(VIEWER)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.path[0].nodeId").value(TOP.toString()))
                .andExpect(jsonPath("$.path[2].nodeId").value(BETA.toString()));
        mvc.perform(get("/api/v1/hierarchies/UI_H/nodes/{id}/path", OUTSIDE).with(asUser(VIEWER)))
                .andExpect(status().isNotFound());
        mvc.perform(get("/api/v1/hierarchies/UI_H/nodes/{id}/path", TOP).with(asUser(VIEWER)))
                .andExpect(jsonPath("$.path.length()").value(1));
    }

    // ------------------------------------------------------------------ Home

    @Test
    void homeIsBoundedAndShowsThePolicyPanelOnlyToPolicyRoles() throws Exception {
        mvc.perform(get("/api/v1/home").with(asUser(STEWARD)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.worklist.top.length()").value(lessThanOrEqualTo(5)))
                .andExpect(jsonPath("$.worklist.counts.assigned").exists())
                .andExpect(jsonPath("$.requests.latest.length()").value(lessThanOrEqualTo(5)))
                .andExpect(jsonPath("$.hierarchies[0].code").value("UI_H"))
                .andExpect(jsonPath("$.hierarchies.length()").value(1))   // UI_OTHER is not readable
                .andExpect(jsonPath("$.policySummary").value(nullValue()));
        mvc.perform(get("/api/v1/home").with(asUser(POLICY)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.policySummary").isArray())
                .andExpect(jsonPath("$.hierarchies.length()").value(lessThanOrEqualTo(10)));
    }

    @Test
    void homeListsTheLastUsedHierarchyFirst() throws Exception {
        grant("ui_reader_all", "VIEWER", null, null);
        mvc.perform(put("/api/v1/me/preferences").with(asUser("ui_reader_all")).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"lastHierarchyCode\":\"UI_OTHER\"}"))
                .andExpect(status().isOk());
        mvc.perform(get("/api/v1/home").with(asUser("ui_reader_all")))
                .andExpect(jsonPath("$.hierarchies[0].code").value("UI_OTHER"))
                .andExpect(jsonPath("$.hierarchies[0].lastUsed").value(true));
    }

    // ------------------------------------------------------------------ submit form

    @Test
    void submitFormListsTheSubmitTasksPropertiesWithRequiredFlags() throws Exception {
        mvc.perform(get("/api/v1/workflow/models/UI_ADD_LEAF/submit-form").param("hierarchy", "UI_H").with(asUser(STEWARD)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.modelVersion").value(1))
                .andExpect(jsonPath("$.allowedActions").value(hasItem("add_node")))
                .andExpect(jsonPath("$.properties[0].code").value("UI.Ccy"))
                .andExpect(jsonPath("$.properties[0].required").value(true))
                .andExpect(jsonPath("$.properties[0].listValues[1]").value("USD"))
                .andExpect(jsonPath("$.properties[1].code").value("UI.Note"))
                .andExpect(jsonPath("$.properties[1].required").value(false));
        mvc.perform(get("/api/v1/workflow/models/UI_ADD_LEAF/submit-form").with(asUser(VIEWER)))
                .andExpect(status().isForbidden());
        mvc.perform(get("/api/v1/workflow/models/UI_NOPE/submit-form").with(asUser(STEWARD)))
                .andExpect(status().isNotFound());
    }

    // ------------------------------------------------------------------ request detail

    @Test
    void requestDetailCarriesTheWorkflowInstanceAndEachItemsBeforeState() throws Exception {
        String created = mvc.perform(post("/api/v1/change-requests").with(asUser(STEWARD)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"versionName\":\"UI working\",\"title\":\"Rename beta\",\"riskTier\":\"low\"}"))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.workflowInstanceId").value(nullValue()))
                .andReturn().getResponse().getContentAsString();
        String id = mapper.readTree(created).get("id").asText();
        mvc.perform(post("/api/v1/change-requests/{id}/items", id).with(asUser(STEWARD)).header("If-Match", "\"1\"")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"action\":\"update_node\",\"hierarchyCode\":\"UI_H\",\"nodeId\":\"" + BETA
                                + "\",\"payload\":{\"name\":\"UI Beta desk renamed\"}}"))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.before.name").value("UI Beta desk"));
        mvc.perform(get("/api/v1/change-requests/{id}/items", id).with(asUser(STEWARD)))
                .andExpect(jsonPath("$.items[0].before.name").value("UI Beta desk"));
    }

    // ------------------------------------------------------------------ client errors

    @Test
    void clientErrorsAreAcceptedAndRateLimitedPerUser() throws Exception {
        String report = "{\"status\":500,\"type\":\"urn:nexus:problem:internal-error\",\"correlationId\":\"abc-123\","
                + "\"route\":\"/hierarchies/UI_H?q=secret\",\"value\":\"must be ignored\"}";
        for (int i = 0; i < 20; i++) {
            mvc.perform(post("/api/v1/client-errors").with(asUser(STRANGER)).contentType(MediaType.APPLICATION_JSON).content(report))
                    .andExpect(status().isAccepted());
        }
        mvc.perform(post("/api/v1/client-errors").with(asUser(STRANGER)).contentType(MediaType.APPLICATION_JSON).content(report))
                .andExpect(status().isTooManyRequests());
        // the limit is per user
        mvc.perform(post("/api/v1/client-errors").with(asUser(VIEWER)).contentType(MediaType.APPLICATION_JSON).content(report))
                .andExpect(status().isAccepted());
    }
}
