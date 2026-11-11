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

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** HIE-02 / PRP-01 drafting: create, edit, items with expected values, ETag, idempotency, withdraw (LLD §5.2, §7.3). */
class ChangeRequestApiTest extends PostgresIntegrationTest {

    static final UUID TOP = UUID.fromString("00000000-0000-0000-0000-0000000ac001");
    static final UUID EUROPE = UUID.fromString("00000000-0000-0000-0000-0000000ac002");
    static final UUID AMERICAS = UUID.fromString("00000000-0000-0000-0000-0000000ac003");
    static final UUID ENTITY = UUID.fromString("00000000-0000-0000-0000-0000000ac004");
    static final String STEWARD = "cr_steward";
    static final String SCOPED = "cr_scoped";
    static final String VIEWER = "cr_viewer";
    static final String OTHER = "cr_other";
    static final String APPROVER = "cr_approver";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    @BeforeEach
    void seed() {
        JdbcClient jdbc = ownerJdbc();
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'CR_H'").query(Integer.class).single() == 0) {
            jdbc.sql("INSERT INTO mdm.version (version_name, business_as_of) VALUES ('CR working', current_date)").update();
            jdbc.sql("""
                    INSERT INTO mdm.node (node_id, node_kind)
                    VALUES (:t, 'structural'), (:e, 'structural'), (:a, 'structural'), (:x, 'legal_entity')
                    """).param("t", TOP).param("e", EUROPE).param("a", AMERICAS).param("x", ENTITY).update();
            jdbc.sql("""
                    INSERT INTO mdm.node_attr (node_id, node_name, allows_children, valid_period)
                    VALUES (:t, 'CR group', true, daterange('2020-01-01', NULL)), (:e, 'CR Europe', true, daterange('2020-01-01', NULL)),
                           (:a, 'CR Americas', true, daterange('2020-01-01', NULL)), (:x, 'CR Entity 1', false, daterange('2020-01-01', NULL))
                    """).param("t", TOP).param("e", EUROPE).param("a", AMERICAS).param("x", ENTITY).update();
            jdbc.sql("INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, top_node_id) VALUES ('CR_H', 'CR test', :t)")
                    .param("t", TOP).update();
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, valid_period)
                    SELECT hierarchy_id, p, c, daterange('2020-01-01', NULL)
                    FROM mdm.hierarchy, (VALUES (CAST(:t AS uuid), CAST(:e AS uuid)), (:t, :a), (:e, :x)) AS v(p, c)
                    WHERE hierarchy_code = 'CR_H'
                    """).param("t", TOP).param("e", EUROPE).param("a", AMERICAS).param("x", ENTITY).update();
            jdbc.sql("""
                    INSERT INTO mdm.property_definition (property_code, label, data_type, scope)
                    VALUES ('CR.Ccy', 'Currency', 'string', 'global')
                    """).update();
            jdbc.sql("""
                    INSERT INTO mdm.property_value (node_id, property_id, value, valid_period)
                    SELECT :x, property_id, '"EUR"', daterange('2020-01-01', NULL) FROM mdm.property_definition WHERE property_code = 'CR.Ccy'
                    """).param("x", ENTITY).update();
        }
        if (jdbc.sql("SELECT count(*) FROM mdm.validation_rule WHERE rule_code = 'CR.NO_BAD'").query(Integer.class).single() == 0) {
            jdbc.sql("""
                    INSERT INTO mdm.validation_rule (rule_code, description, level, severity, engine, expression, hierarchy_id)
                    SELECT 'CR.NO_BAD', 'Names must not contain BAD (test rule)', 'node', 'error', 'sql',
                           'SELECT a.node_id, NULL::uuid, ''Name contains BAD'' FROM mdm.node_attr a
                            WHERE a.valid_period @> $1 AND a.recorded_period @> $2 AND a.node_name LIKE ''%BAD%''',
                           hierarchy_id
                    FROM mdm.hierarchy WHERE hierarchy_code = 'CR_H'
                    """).update();
        }
        grant(STEWARD, "STEWARD", "CR_H", null);
        grant(APPROVER, "APPROVER", "CR_H", null);
        grant(SCOPED, "STEWARD", "CR_H", AMERICAS);
        grant(VIEWER, "VIEWER", "CR_H", null);
        grant(OTHER, "VIEWER", "CR_H", null);
    }

    // ------------------------------------------------------------------ create, read, edit

    @Test
    void createReturns201WithEtagAndLocation() throws Exception {
        MvcResult r = mvc.perform(post("/api/v1/change-requests").with(asUser(STEWARD)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"versionName\":\"CR working\",\"title\":\"Reorganise Europe\"}"))
                .andExpect(status().isCreated())
                .andExpect(header().string("ETag", "\"1\""))
                .andExpect(header().exists("Location"))
                .andExpect(jsonPath("$.status").value("draft"))
                .andExpect(jsonPath("$.riskTier").value("medium"))
                .andExpect(jsonPath("$.effectiveFrom").exists())
                .andReturn();
        String id = json(r).get("id").asText();
        mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(STEWARD)))
                .andExpect(status().isOk()).andExpect(header().string("ETag", "\"1\""));
    }

    @Test
    void viewerCannotCreate() throws Exception {
        mvc.perform(post("/api/v1/change-requests").with(asUser(VIEWER)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"versionName\":\"CR working\",\"title\":\"Nope\"}"))
                .andExpect(status().isForbidden());
    }

    @Test
    void patchNeedsIfMatchAndRefusesStaleEtag() throws Exception {
        String id = create(STEWARD, "Edit me");
        mvc.perform(patch("/api/v1/change-requests/" + id).with(asUser(STEWARD)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"title\":\"Edited\"}"))
                .andExpect(status().is(428));
        mvc.perform(patch("/api/v1/change-requests/" + id).with(asUser(STEWARD)).header("If-Match", "\"7\"")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"title\":\"Edited\"}"))
                .andExpect(status().isPreconditionFailed());
        mvc.perform(patch("/api/v1/change-requests/" + id).with(asUser(STEWARD)).header("If-Match", "\"1\"")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"title\":\"Edited\",\"riskTier\":\"low\"}"))
                .andExpect(status().isOk())
                .andExpect(header().string("ETag", "\"2\""))
                .andExpect(jsonPath("$.title").value("Edited"))
                .andExpect(jsonPath("$.riskTier").value("low"));
    }

    @Test
    void othersCannotSeeAnEmptyDraftOrEditIt() throws Exception {
        String id = create(STEWARD, "Private draft");
        mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(OTHER))).andExpect(status().isNotFound());
        mvc.perform(patch("/api/v1/change-requests/" + id).with(asUser(OTHER)).header("If-Match", "\"1\"")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"title\":\"Hijack\"}"))
                .andExpect(status().isNotFound());
    }

    @Test
    void readersOfItsHierarchiesCanSeeButNotEditARequestWithItems() throws Exception {
        String id = create(STEWARD, "Visible draft");
        addItem(STEWARD, id, 1, "{\"action\":\"update_node\",\"hierarchyCode\":\"CR_H\",\"nodeId\":\"" + ENTITY
                + "\",\"payload\":{\"description\":\"Updated\"}}").andExpect(status().isCreated());
        mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(OTHER))).andExpect(status().isOk());
        addItem(OTHER, id, 2, "{\"action\":\"delete_node\",\"hierarchyCode\":\"CR_H\",\"nodeId\":\"" + ENTITY + "\"}")
                .andExpect(status().isForbidden());
    }

    @Test
    void mineListsOwnRequestsNewestFirstWithCursor() throws Exception {
        String login = "cr_lister";
        grant(login, "STEWARD", "CR_H", null);
        String first = create(login, "First");
        String second = create(login, "Second");
        MvcResult page1 = mvc.perform(get("/api/v1/change-requests").param("limit", "1").with(asUser(login)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items[0].id").value(second))
                .andExpect(jsonPath("$.nextCursor").exists())
                .andReturn();
        mvc.perform(get("/api/v1/change-requests").param("limit", "1").param("cursor", json(page1).get("nextCursor").asText())
                        .with(asUser(login)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items[0].id").value(first));
    }

    // ------------------------------------------------------------------ items

    @Test
    void addNodeAllocatesTheNodeAndBumpsTheEtag() throws Exception {
        String id = create(STEWARD, "Add a node");
        MvcResult r = addItem(STEWARD, id, 1, "{\"action\":\"add_node\",\"hierarchyCode\":\"CR_H\",\"targetParentId\":\"" + EUROPE
                + "\",\"payload\":{\"nodeKind\":\"legal_entity\",\"name\":\"CR New entity\",\"isLeaf\":true}}")
                .andExpect(status().isCreated())
                .andExpect(header().string("ETag", "\"2\""))
                .andExpect(jsonPath("$.seq").value(1))
                .andExpect(jsonPath("$.nodeId").exists())
                .andReturn();
        UUID node = UUID.fromString(json(r).get("nodeId").asText());
        assertThat(ownerJdbc().sql("SELECT node_kind::text FROM mdm.node WHERE node_id = :n").param("n", node)
                .query(String.class).single()).isEqualTo("legal_entity");
    }

    @Test
    void addItemNeedsIfMatchAndCurrentEtag() throws Exception {
        String id = create(STEWARD, "Etag items");
        String body = "{\"action\":\"delete_node\",\"hierarchyCode\":\"CR_H\",\"nodeId\":\"" + ENTITY + "\"}";
        mvc.perform(post("/api/v1/change-requests/" + id + "/items").with(asUser(STEWARD))
                        .contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().is(428));
        addItem(STEWARD, id, 5, body).andExpect(status().isPreconditionFailed());
    }

    @Test
    void scopedStewardCannotProposeOutsideTheirSubtree() throws Exception {
        String id = create(SCOPED, "Scoped");
        addItem(SCOPED, id, 1, "{\"action\":\"add_node\",\"hierarchyCode\":\"CR_H\",\"targetParentId\":\"" + EUROPE
                + "\",\"payload\":{\"nodeKind\":\"structural\",\"name\":\"CR Outside\"}}")
                .andExpect(status().isForbidden());
        addItem(SCOPED, id, 1, "{\"action\":\"add_node\",\"hierarchyCode\":\"CR_H\",\"targetParentId\":\"" + AMERICAS
                + "\",\"payload\":{\"nodeKind\":\"structural\",\"name\":\"CR Inside\"}}")
                .andExpect(status().isCreated());
    }

    @Test
    void scopedStewardCanAddUnderANodeAddedEarlierInTheSameRequest() throws Exception {
        String id = create(SCOPED, "Nested");
        MvcResult parent = addItem(SCOPED, id, 1, "{\"action\":\"add_node\",\"hierarchyCode\":\"CR_H\",\"targetParentId\":\"" + AMERICAS
                + "\",\"payload\":{\"nodeKind\":\"structural\",\"name\":\"CR New region\",\"isLeaf\":false}}")
                .andExpect(status().isCreated()).andReturn();
        addItem(SCOPED, id, 2, "{\"action\":\"add_node\",\"hierarchyCode\":\"CR_H\",\"targetParentId\":\"" + json(parent).get("nodeId").asText()
                + "\",\"payload\":{\"nodeKind\":\"legal_entity\",\"name\":\"CR New child\"}}")
                .andExpect(status().isCreated());
    }

    @Test
    void expectedValuesFollowEarlierItemsOfTheRequest() throws Exception {
        String id = create(STEWARD, "Expected values");
        addItem(STEWARD, id, 1, "{\"action\":\"move_node\",\"hierarchyCode\":\"CR_H\",\"nodeId\":\"" + ENTITY
                + "\",\"targetParentId\":\"" + AMERICAS + "\"}")
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.payload.expected.parentId").value(EUROPE.toString()));
        addItem(STEWARD, id, 2, "{\"action\":\"move_node\",\"hierarchyCode\":\"CR_H\",\"nodeId\":\"" + ENTITY
                + "\",\"targetParentId\":\"" + EUROPE + "\"}")
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.payload.expected.parentId").value(AMERICAS.toString()));
        addItem(STEWARD, id, 3, "{\"action\":\"set_property\",\"hierarchyCode\":\"CR_H\",\"nodeId\":\"" + ENTITY
                + "\",\"propertyCode\":\"CR.Ccy\",\"payload\":{\"value\":\"USD\"}}")
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.payload.expected.present").value(true))
                .andExpect(jsonPath("$.payload.expected.value").value("EUR"));
        addItem(STEWARD, id, 4, "{\"action\":\"clear_property\",\"hierarchyCode\":\"CR_H\",\"nodeId\":\"" + ENTITY
                + "\",\"propertyCode\":\"CR.Ccy\"}")
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.payload.expected.value").value("USD"));
        mvc.perform(get("/api/v1/change-requests/" + id + "/items").with(asUser(STEWARD)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items.length()").value(4));
    }

    @Test
    void pendingActionIsRefused() throws Exception {
        String id = create(STEWARD, "Pending action");
        addItem(STEWARD, id, 1, "{\"action\":\"inactivate_node\",\"hierarchyCode\":\"CR_H\",\"nodeId\":\"" + ENTITY + "\"}")
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("change_item.action_not_available"));
    }

    @Test
    void invalidPayloadIsA400WithFieldErrors() throws Exception {
        String id = create(STEWARD, "Bad payload");
        addItem(STEWARD, id, 1, "{\"action\":\"add_node\",\"hierarchyCode\":\"CR_H\",\"targetParentId\":\"" + EUROPE
                + "\",\"payload\":{\"nodeKind\":\"legal_entity\",\"name\":\"X\",\"colour\":\"red\"}}")
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.errors[0].field").value("payload.colour"));
        addItem(STEWARD, id, 1, "{\"action\":\"add_node\",\"hierarchyCode\":\"CR_H\",\"targetParentId\":\"" + ENTITY
                + "\",\"payload\":{\"nodeKind\":\"legal_entity\",\"name\":\"Under a leaf\"}}")
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("change_item.parent_is_leaf"));
    }

    @Test
    void addHierarchyNeedsAnAllHierarchiesGrantAndAValidPurpose() throws Exception {
        String admin = "cr_all_steward";
        grant(admin, "STEWARD", null, null);
        String body = "{\"action\":\"add_hierarchy\",\"payload\":{\"code\":\"CR_NEW\",\"name\":\"CR new\",\"purpose\":\"%s\","
                + "\"topNode\":{\"nodeKind\":\"structural\",\"name\":\"CR new top\"}}}";
        String scoped = create(STEWARD, "Hierarchy, scoped steward");
        addItem(STEWARD, scoped, 1, body.formatted("management")).andExpect(status().isForbidden());
        String id = create(admin, "Hierarchy");
        addItem(admin, id, 1, body.formatted("bookkeeping"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.errors[0].field").value("payload.purpose"));
        addItem(admin, id, 1, body.formatted("management"))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.nodeId").exists());
    }

    @Test
    void deleteItemNeedsIfMatchAndBumpsTheEtag() throws Exception {
        String id = create(STEWARD, "Delete item");
        MvcResult r = addItem(STEWARD, id, 1, "{\"action\":\"delete_node\",\"hierarchyCode\":\"CR_H\",\"nodeId\":\"" + ENTITY + "\"}")
                .andExpect(status().isCreated()).andReturn();
        String itemId = json(r).get("id").asText();
        mvc.perform(delete("/api/v1/change-requests/" + id + "/items/" + itemId).with(asUser(STEWARD)))
                .andExpect(status().is(428));
        mvc.perform(delete("/api/v1/change-requests/" + id + "/items/" + itemId).with(asUser(STEWARD)).header("If-Match", "\"2\""))
                .andExpect(status().isNoContent())
                .andExpect(header().string("ETag", "\"3\""));
        mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(STEWARD))).andExpect(jsonPath("$.itemCount").value(0));
    }

    // ------------------------------------------------------------------ idempotency, withdraw

    @Test
    void idempotentCreateReplaysAndRefusesADifferentBody() throws Exception {
        String key = "cr-key-" + UUID.randomUUID();
        MvcResult first = mvc.perform(post("/api/v1/change-requests").with(asUser(STEWARD)).header("Idempotency-Key", key)
                        .contentType(MediaType.APPLICATION_JSON).content("{\"versionName\":\"CR working\",\"title\":\"Once\"}"))
                .andExpect(status().isCreated()).andReturn();
        mvc.perform(post("/api/v1/change-requests").with(asUser(STEWARD)).header("Idempotency-Key", key)
                        .contentType(MediaType.APPLICATION_JSON).content("{\"versionName\":\"CR working\",\"title\":\"Once\"}"))
                .andExpect(status().isCreated())
                .andExpect(header().string("Idempotent-Replayed", "true"))
                .andExpect(header().string("ETag", "\"1\""))
                .andExpect(jsonPath("$.id").value(json(first).get("id").asText()));
        mvc.perform(post("/api/v1/change-requests").with(asUser(STEWARD)).header("Idempotency-Key", key)
                        .contentType(MediaType.APPLICATION_JSON).content("{\"versionName\":\"CR working\",\"title\":\"Twice\"}"))
                .andExpect(status().isUnprocessableEntity());
        assertThat(ownerJdbc().sql("SELECT count(*) FROM mdm.change_request WHERE title = 'Once'").query(Integer.class).single())
                .isEqualTo(1);
    }

    @Test
    void withdrawEndsTheDraftAndItCanNoLongerBeEdited() throws Exception {
        String id = create(STEWARD, "Withdraw me");
        mvc.perform(post("/api/v1/change-requests/" + id + "/withdraw").with(asUser(OTHER)).header("If-Match", "\"1\""))
                .andExpect(status().isNotFound());
        MvcResult r = mvc.perform(post("/api/v1/change-requests/" + id + "/withdraw").with(asUser(STEWARD)).header("If-Match", "\"1\""))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("withdrawn"))
                .andReturn();
        String etag = r.getResponse().getHeader("ETag").replace("\"", "");
        addItem(STEWARD, id, Integer.parseInt(etag), "{\"action\":\"delete_node\",\"hierarchyCode\":\"CR_H\",\"nodeId\":\"" + ENTITY + "\"}")
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("change_request.not_draft"));
    }

    // ------------------------------------------------------------------ validate, submit

    @Test
    void submitValidatesThenSubmitsAndFreezesTheDraft() throws Exception {
        String id = create(STEWARD, "Submit me");
        addItem(STEWARD, id, 1, "{\"action\":\"add_node\",\"hierarchyCode\":\"CR_H\",\"targetParentId\":\"" + EUROPE
                + "\",\"payload\":{\"nodeKind\":\"legal_entity\",\"name\":\"CR Submitted entity\"}}")
                .andExpect(status().isCreated());
        mvc.perform(post("/api/v1/change-requests/" + id + "/submit").with(asUser(STEWARD)))
                .andExpect(status().is(428));
        MvcResult r = mvc.perform(post("/api/v1/change-requests/" + id + "/submit").with(asUser(STEWARD)).header("If-Match", "\"2\""))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("submitted"))
                .andExpect(jsonPath("$.submittedAt").exists())
                .andReturn();
        int etag = Integer.parseInt(r.getResponse().getHeader("ETag").replace("\"", ""));
        assertThat(etag).isGreaterThan(2);
        addItem(STEWARD, id, etag, "{\"action\":\"delete_node\",\"hierarchyCode\":\"CR_H\",\"nodeId\":\"" + ENTITY + "\"}")
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("change_request.not_draft"));
        assertThat(ownerJdbc().sql("SELECT count(*) FROM mdm.node_attr WHERE node_name = 'CR Submitted entity'")
                .query(Integer.class).single()).isZero();
    }

    @Test
    void submitWithValidationErrorsIs422KeepsTheDraftAndStoresTheFindings() throws Exception {
        String id = create(STEWARD, "Bad name");
        addItem(STEWARD, id, 1, "{\"action\":\"add_node\",\"hierarchyCode\":\"CR_H\",\"targetParentId\":\"" + EUROPE
                + "\",\"payload\":{\"nodeKind\":\"legal_entity\",\"name\":\"CR BAD entity\"}}")
                .andExpect(status().isCreated());
        mvc.perform(post("/api/v1/change-requests/" + id + "/submit").with(asUser(STEWARD)).header("If-Match", "\"2\""))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.type").value("urn:nexus:problem:validation-failed"))
                .andExpect(jsonPath("$.code").value("change_request.validation_failed"))
                .andExpect(jsonPath("$.errors[0].ruleCode").value("CR.NO_BAD"))
                .andExpect(jsonPath("$.errors[0].nodeId").exists());
        mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(STEWARD)))
                .andExpect(jsonPath("$.status").value("draft"));
        assertThat(ownerJdbc().sql("SELECT count(*) FROM mdm.validation_result WHERE change_request_id = CAST(:id AS uuid)")
                .param("id", id).query(Integer.class).single()).isPositive();
    }

    @Test
    void anEmptyRequestCannotBeSubmitted() throws Exception {
        String id = create(STEWARD, "Empty");
        mvc.perform(post("/api/v1/change-requests/" + id + "/submit").with(asUser(STEWARD)).header("If-Match", "\"1\""))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("change_request.empty"));
    }

    @Test
    void validateIsForTheRequesterOrADeciderInScope() throws Exception {
        String id = create(STEWARD, "Validate me");
        addItem(STEWARD, id, 1, "{\"action\":\"update_node\",\"hierarchyCode\":\"CR_H\",\"nodeId\":\"" + ENTITY
                + "\",\"payload\":{\"description\":\"Checked\"}}").andExpect(status().isCreated());
        mvc.perform(post("/api/v1/change-requests/" + id + "/validate").with(asUser(STEWARD)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.errors.length()").value(0))
                .andExpect(jsonPath("$.validatedAt").exists());
        mvc.perform(post("/api/v1/change-requests/" + id + "/validate").with(asUser(OTHER)))
                .andExpect(status().isForbidden());
        mvc.perform(post("/api/v1/change-requests/" + id + "/validate").with(asUser(APPROVER)))
                .andExpect(status().isOk());
    }

    // ------------------------------------------------------------------ helpers

    private String create(String login, String title) throws Exception {
        MvcResult r = mvc.perform(post("/api/v1/change-requests").with(asUser(login)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"versionName\":\"CR working\",\"title\":\"" + title + "\"}"))
                .andExpect(status().isCreated()).andReturn();
        return json(r).get("id").asText();
    }

    private org.springframework.test.web.servlet.ResultActions addItem(String login, String id, int etag, String body) throws Exception {
        return mvc.perform(post("/api/v1/change-requests/" + id + "/items").with(asUser(login)).header("If-Match", "\"" + etag + "\"")
                .contentType(MediaType.APPLICATION_JSON).content(body));
    }

    private JsonNode json(MvcResult r) throws Exception {
        return mapper.readTree(r.getResponse().getContentAsString());
    }
}
