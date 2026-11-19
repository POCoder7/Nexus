package com.mdm.api.compare;

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

import java.time.Instant;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Compares through the API (QRY-02, VER-04; Phase 5 LLD §17.4, §17.13): a change made through a real request, then the
 * slice before it compared with the slice after it; reuse of frozen runs, paging, read scope, bad input and baselines.
 */
class CompareApiTest extends PostgresIntegrationTest {

    static final UUID TOP = UUID.fromString("00000000-0000-0000-0000-0000000c0e01");
    static final UUID LEAF = UUID.fromString("00000000-0000-0000-0000-0000000c0e02");
    static final UUID OTHER_TOP = UUID.fromString("00000000-0000-0000-0000-0000000c0e03");
    static final String EDITOR = "cp_editor";
    static final String APPROVER = "cp_approver";
    static final String OUTSIDER = "cp_outsider";   // reads CP_OTHER only
    static final String ADMIN = "cp_admin";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    static Instant before;
    static Instant after;

    @BeforeEach
    void seed() throws Exception {
        JdbcClient jdbc = ownerJdbc();
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'CP_H'").query(Integer.class).single() == 0) {
            jdbc.sql("INSERT INTO mdm.version (version_name, business_as_of) VALUES ('CP working', current_date)").update();
            jdbc.sql("INSERT INTO mdm.node (node_id, node_kind) VALUES (:t, 'structural'), (:l, 'legal_entity'), (:o, 'structural')")
                    .param("t", TOP).param("l", LEAF).param("o", OTHER_TOP).update();
            jdbc.sql("""
                    INSERT INTO mdm.node_attr (node_id, node_name, allows_children, valid_period) VALUES
                      (:t, 'CP top', true, daterange('2020-01-01', NULL)), (:l, 'CP leaf', false, daterange('2020-01-01', NULL)),
                      (:o, 'CP other top', true, daterange('2020-01-01', NULL))
                    """).param("t", TOP).param("l", LEAF).param("o", OTHER_TOP).update();
            jdbc.sql("INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, top_node_id) VALUES ('CP_H', 'Compare', :t), ('CP_OTHER', 'Other', :o)")
                    .param("t", TOP).param("o", OTHER_TOP).update();
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, valid_period)
                    SELECT hierarchy_id, :t, :l, daterange('2020-01-01', NULL) FROM mdm.hierarchy WHERE hierarchy_code = 'CP_H'
                    """).param("t", TOP).param("l", LEAF).update();
            jdbc.sql("INSERT INTO mdm.property_definition (property_code, label, data_type, scope) VALUES ('CP.Code', 'Code', 'string', 'global')").update();
        }
        grant(EDITOR, "EDITOR", "CP_H", null);
        grant(APPROVER, "APPROVER", "CP_H", null);
        grant(OUTSIDER, "VIEWER", "CP_OTHER", null);
        grant(ADMIN, "ADMIN", null, null);
        if (before == null) {
            before = Instant.now();
            Thread.sleep(20);
            applied("{\"action\":\"update_node\",\"hierarchyCode\":\"CP_H\",\"nodeId\":\"" + LEAF + "\",\"payload\":{\"name\":\"CP leaf renamed\"}}");
            applied("{\"action\":\"set_property\",\"hierarchyCode\":\"CP_H\",\"nodeId\":\"" + LEAF
                    + "\",\"propertyCode\":\"CP.Code\",\"payload\":{\"value\":\"C-1\"}}");
            Thread.sleep(20);
            after = Instant.now();
        }
    }

    @Test
    void beforeAndAfterAChangeDifferByExactlyThatChange() throws Exception {
        JsonNode run = done(start(EDITOR, side("CP_H", null, before), side("CP_H", null, null)));
        assertThat(run.get("counts").get("rename").asInt()).isEqualTo(1);
        assertThat(run.get("counts").get("property").asInt()).isEqualTo(1);
        assertThat(run.get("counts").get("structure").asInt()).isZero();
        assertThat(run.get("frozen").asBoolean()).isFalse();   // the right side is "now"

        JsonNode rename = rows(EDITOR, run.get("id").asText(), "rename").get("items").get(0);
        assertThat(rename.get("detail").get("leftName").asText()).isEqualTo("CP leaf");
        assertThat(rename.get("detail").get("rightName").asText()).isEqualTo("CP leaf renamed");
        JsonNode property = rows(EDITOR, run.get("id").asText(), "property").get("items").get(0);
        assertThat(property.get("detail").get("propertyCode").asText()).isEqualTo("CP.Code");
        assertThat(property.get("detail").get("leftValue").isNull()).isTrue();
        assertThat(property.get("detail").get("rightValue").asText()).isEqualTo("C-1");
        assertThat(property.get("detail").get("rightProvenance").asText()).isEqualTo("stored");

        JsonNode page = rows(EDITOR, run.get("id").asText() + "/rows?limit=1", null);
        assertThat(page.get("items")).hasSize(1);
        assertThat(page.get("nextCursor").isNull()).isFalse();
    }

    @Test
    void aFrozenCompareIsReusedForAnyoneWhoCanReadIt() throws Exception {
        JsonNode first = done(start(EDITOR, side("CP_H", null, before), side("CP_H", null, after)));
        assertThat(first.get("frozen").asBoolean()).isTrue();
        JsonNode second = start(APPROVER, side("CP_H", null, before), side("CP_H", null, after));
        assertThat(second.get("reused").asBoolean()).isTrue();
        assertThat(second.get("id").asText()).isEqualTo(first.get("id").asText());

        mvc.perform(get("/api/v1/compares/" + first.get("id").asText()).with(asUser(OUTSIDER))).andExpect(status().isNotFound());
        mvc.perform(post("/api/v1/compares").with(asUser(OUTSIDER)).contentType(MediaType.APPLICATION_JSON)
                        .content(body(side("CP_H", null, null), side("CP_H", null, null))))
                .andExpect(status().isForbidden());
    }

    @Test
    void badSidesAreRefusedInWords() throws Exception {
        String unknownVersion = "{\"left\":{\"hierarchyCode\":\"CP_H\",\"version\":\"CP nope\"},\"right\":{\"hierarchyCode\":\"CP_H\"}}";
        mvc.perform(post("/api/v1/compares").with(asUser(EDITOR)).contentType(MediaType.APPLICATION_JSON).content(unknownVersion))
                .andExpect(status().isBadRequest());
        String both = "{\"left\":{\"hierarchyCode\":\"CP_H\",\"version\":\"CP working\",\"asOf\":\"2024-01-01\"},\"right\":{\"hierarchyCode\":\"CP_H\"}}";
        mvc.perform(post("/api/v1/compares").with(asUser(EDITOR)).contentType(MediaType.APPLICATION_JSON).content(both))
                .andExpect(status().isBadRequest());
        String badKind = "{\"left\":{\"hierarchyCode\":\"CP_H\"},\"right\":{\"hierarchyCode\":\"CP_H\"},\"kinds\":[\"colour\"]}";
        mvc.perform(post("/api/v1/compares").with(asUser(EDITOR)).contentType(MediaType.APPLICATION_JSON).content(badKind))
                .andExpect(status().isBadRequest());
        JsonNode version = done(start(EDITOR, "{\"hierarchyCode\":\"CP_H\",\"version\":\"CP working\"}", side("CP_H", null, null)));
        assertThat(version.get("left").get("version").asText()).isEqualTo("CP working");
    }

    @Test
    void aBaselineIsAVersionTypeAndCanBeListedByIt() throws Exception {
        String name = "CP baseline " + UUID.randomUUID().toString().substring(0, 8);
        mvc.perform(post("/api/v1/versions").with(asUser(ADMIN)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"" + name + "\",\"businessAsOf\":\"2026-01-01\",\"versionType\":\"baseline\"}"))
                .andExpect(status().isCreated()).andExpect(jsonPath("$.versionType").value("baseline"));
        MvcResult r = mvc.perform(get("/api/v1/versions").param("type", "baseline").param("limit", "200").with(asUser(EDITOR)))
                .andExpect(status().isOk()).andReturn();
        JsonNode items = mapper.readTree(r.getResponse().getContentAsString()).get("items");
        assertThat(items.findValuesAsText("name")).contains(name).doesNotContain("CP working");
        mvc.perform(post("/api/v1/versions").with(asUser(ADMIN)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"CP bad type\",\"businessAsOf\":\"2026-01-01\",\"versionType\":\"weird\"}"))
                .andExpect(status().isBadRequest());
    }

    // ------------------------------------------------------------------ helpers

    private static String side(String hierarchy, String asOf, Instant recordedAsOf) {
        return "{\"hierarchyCode\":\"" + hierarchy + "\"" + (asOf == null ? "" : ",\"asOf\":\"" + asOf + "\"")
                + (recordedAsOf == null ? "" : ",\"recordedAsOf\":\"" + recordedAsOf + "\"") + "}";
    }

    private static String body(String left, String right) {
        return "{\"left\":" + left + ",\"right\":" + right + "}";
    }

    private JsonNode start(String login, String left, String right) throws Exception {
        MvcResult r = mvc.perform(post("/api/v1/compares").with(asUser(login)).contentType(MediaType.APPLICATION_JSON).content(body(left, right)))
                .andExpect(status().isAccepted()).andReturn();
        return mapper.readTree(r.getResponse().getContentAsString());
    }

    /** Polls the run until it is no longer running (the executor fills it in the background). */
    private JsonNode done(JsonNode run) throws Exception {
        for (int i = 0; i < 100 && "running".equals(run.get("status").asText()); i++) {
            Thread.sleep(100);
            MvcResult r = mvc.perform(get("/api/v1/compares/" + run.get("id").asText()).with(asUser(EDITOR))).andReturn();
            run = mapper.readTree(r.getResponse().getContentAsString());
        }
        assertThat(run.get("status").asText()).as("compare %s: %s", run.get("id"), run.get("error")).isEqualTo("done");
        return run;
    }

    private JsonNode rows(String login, String idAndPath, String kind) throws Exception {
        String url = "/api/v1/compares/" + (idAndPath.contains("/rows") ? idAndPath : idAndPath + "/rows" + (kind == null ? "" : "?type=" + kind));
        MvcResult r = mvc.perform(get(url).with(asUser(login))).andExpect(status().isOk()).andReturn();
        return mapper.readTree(r.getResponse().getContentAsString());
    }

    /** A request by the editor, approved by the approver, applied. */
    private void applied(String item) throws Exception {
        MvcResult r = mvc.perform(post("/api/v1/change-requests").with(asUser(EDITOR)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"versionName\":\"CP working\",\"title\":\"CP change\"}"))
                .andExpect(status().isCreated()).andReturn();
        String id = mapper.readTree(r.getResponse().getContentAsString()).get("id").asText();
        mvc.perform(post("/api/v1/change-requests/" + id + "/items").with(asUser(EDITOR)).header("If-Match", etag(EDITOR, id))
                .contentType(MediaType.APPLICATION_JSON).content(item)).andExpect(status().isCreated());
        mvc.perform(post("/api/v1/change-requests/" + id + "/submit").with(asUser(EDITOR)).header("If-Match", etag(EDITOR, id)))
                .andExpect(status().isOk());
        mvc.perform(post("/api/v1/change-requests/" + id + "/decision").with(asUser(APPROVER)).header("If-Match", etag(APPROVER, id))
                        .contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"approve\"}"))
                .andExpect(jsonPath("$.status").value("applied"));
    }

    private String etag(String login, String id) throws Exception {
        return mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(login))).andReturn().getResponse().getHeader("ETag");
    }
}
