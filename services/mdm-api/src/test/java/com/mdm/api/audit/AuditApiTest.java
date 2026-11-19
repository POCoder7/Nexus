package com.mdm.api.audit;

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

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Transaction history (AUD-01; Phase 5 LLD §18.3 to §18.5, §18.8): changes made through real requests, then searched.
 * Before → after pairing, superseded rows, a move, filters, paging, the range limit and who sees what.
 */
class AuditApiTest extends PostgresIntegrationTest {

    static final UUID TOP1 = UUID.fromString("00000000-0000-0000-0000-0000000a0d01");
    static final UUID NORTH = UUID.fromString("00000000-0000-0000-0000-0000000a0d02");
    static final UUID SOUTH = UUID.fromString("00000000-0000-0000-0000-0000000a0d03");
    static final UUID LEAF = UUID.fromString("00000000-0000-0000-0000-0000000a0d04");
    static final UUID TOP2 = UUID.fromString("00000000-0000-0000-0000-0000000a0d05");
    static final UUID OTHER = UUID.fromString("00000000-0000-0000-0000-0000000a0d06");
    static final String STEWARD = "au_steward";
    static final String APPROVER = "au_approver";
    static final String VIEWER1 = "au_viewer1";   // reads AU_H1 only
    static final String ADMIN = "au_admin";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    static boolean changed;

    @BeforeEach
    void seed() throws Exception {
        JdbcClient jdbc = ownerJdbc();
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'AU_H1'").query(Integer.class).single() == 0) {
            jdbc.sql("INSERT INTO mdm.version (version_name, business_as_of) VALUES ('AU working', current_date)").update();
            jdbc.sql("""
                    INSERT INTO mdm.node (node_id, node_kind) VALUES (:t1, 'structural'), (:n, 'structural'), (:s, 'structural'),
                                                                     (:l, 'legal_entity'), (:t2, 'structural'), (:o, 'legal_entity')
                    """).param("t1", TOP1).param("n", NORTH).param("s", SOUTH).param("l", LEAF).param("t2", TOP2).param("o", OTHER).update();
            jdbc.sql("""
                    INSERT INTO mdm.node_attr (node_id, node_name, allows_children, valid_period) VALUES
                      (:t1, 'AU top one', true, daterange('2020-01-01', NULL)), (:n, 'AU North', true, daterange('2020-01-01', NULL)),
                      (:s, 'AU South', true, daterange('2020-01-01', NULL)), (:l, 'AU leaf', false, daterange('2020-01-01', NULL)),
                      (:t2, 'AU top two', true, daterange('2020-01-01', NULL)), (:o, 'AU other', false, daterange('2020-01-01', NULL))
                    """).param("t1", TOP1).param("n", NORTH).param("s", SOUTH).param("l", LEAF).param("t2", TOP2).param("o", OTHER).update();
            jdbc.sql("INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, top_node_id) VALUES ('AU_H1', 'Audit one', :t1), ('AU_H2', 'Audit two', :t2)")
                    .param("t1", TOP1).param("t2", TOP2).update();
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, valid_period)
                    SELECT h.hierarchy_id, v.p, v.c, daterange('2020-01-01', NULL)
                    FROM mdm.hierarchy h JOIN (VALUES ('AU_H1', CAST(:t1 AS uuid), CAST(:n AS uuid)), ('AU_H1', :t1, :s), ('AU_H1', :n, :l),
                                                      ('AU_H2', :t2, :o)) AS v(code, p, c) ON v.code = h.hierarchy_code
                    """).param("t1", TOP1).param("n", NORTH).param("s", SOUTH).param("l", LEAF).param("t2", TOP2).param("o", OTHER).update();
            jdbc.sql("INSERT INTO mdm.property_definition (property_code, label, data_type, scope) VALUES ('AU.Segment', 'Segment', 'string', 'global')").update();
        }
        grant(STEWARD, "EDITOR", null, null);
        grant(APPROVER, "APPROVER", null, null);
        grant(VIEWER1, "VIEWER", "AU_H1", null);
        grant(ADMIN, "ADMIN", null, null);
        if (!changed) {
            changed = true;
            applied("AU retail", "{\"action\":\"set_property\",\"hierarchyCode\":\"AU_H1\",\"nodeId\":\"" + LEAF
                    + "\",\"propertyCode\":\"AU.Segment\",\"payload\":{\"value\":\"Retail\"}}");
            applied("AU wholesale", "{\"action\":\"set_property\",\"hierarchyCode\":\"AU_H1\",\"nodeId\":\"" + LEAF
                    + "\",\"propertyCode\":\"AU.Segment\",\"payload\":{\"value\":\"Wholesale\"}}");
            applied("AU move", "{\"action\":\"move_node\",\"hierarchyCode\":\"AU_H1\",\"nodeId\":\"" + LEAF
                    + "\",\"targetParentId\":\"" + SOUTH + "\",\"payload\":{}}");
            applied("AU other hierarchy", "{\"action\":\"update_node\",\"hierarchyCode\":\"AU_H2\",\"nodeId\":\"" + OTHER
                    + "\",\"payload\":{\"name\":\"AU other renamed\"}}");
        }
    }

    @Test
    void aValueChangeReadsBeforeAndAfterWithBothPeople() throws Exception {
        JsonNode items = search(ADMIN, "node=" + LEAF + "&property=AU.Segment").get("items");
        assertThat(items).hasSize(2);
        JsonNode latest = items.get(0);
        assertThat(latest.get("kind").asText()).isEqualTo("stated");
        assertThat(latest.get("before").get("value").asText()).isEqualTo("Retail");
        assertThat(latest.get("after").get("value").asText()).isEqualTo("Wholesale");
        assertThat(latest.get("changedFields").toString()).contains("value");
        assertThat(latest.get("propertyLabel").asText()).isEqualTo("Segment");
        assertThat(latest.get("nodeName").asText()).isEqualTo("AU leaf");
        assertThat(latest.get("changeRequestTitle").asText()).isEqualTo("AU wholesale");
        assertThat(latest.get("requestedBy").asText()).isEqualTo(STEWARD);
        assertThat(latest.get("decidedBy").asText()).isEqualTo(APPROVER);
        assertThat(items.get(1).get("before").isNull()).isTrue();   // the first value was new
        assertThat(items.get(1).get("after").get("value").asText()).isEqualTo("Retail");

        JsonNode all = search(ADMIN, "node=" + LEAF + "&property=AU.Segment&includeSuperseded=true").get("items");
        assertThat(all.findValuesAsText("kind")).contains("superseded");
    }

    @Test
    void aMoveReadsAsTheOldParentAndTheNewOne() throws Exception {
        JsonNode items = search(ADMIN, "node=" + LEAF + "&hierarchy=AU_H1").get("items");
        JsonNode move = null;
        for (JsonNode e : items) {
            if ("hierarchy_relationship".equals(e.get("table").asText())) {
                move = e;
                break;
            }
        }
        assertThat(move).isNotNull();
        assertThat(move.get("before").get("parent_name").asText()).isEqualTo("AU North");
        assertThat(move.get("after").get("parent_name").asText()).isEqualTo("AU South");
        assertThat(move.get("changedFields").toString()).contains("parent_node_id");
    }

    @Test
    void aViewerSeesOnlyTheHierarchiesTheyCanRead() throws Exception {
        List<String> titles = titles(search(VIEWER1, "limit=200"));
        assertThat(titles).contains("AU wholesale", "AU move").doesNotContain("AU other hierarchy");
        assertThat(titles(search(ADMIN, "limit=200"))).contains("AU other hierarchy");
        mvc.perform(get("/api/v1/audit").param("category", "access").with(asUser(VIEWER1)))
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.code").value("entitlement.missing"));
        mvc.perform(get("/api/v1/audit").param("category", "access").with(asUser(ADMIN))).andExpect(status().isOk());
    }

    @Test
    void filtersPagingAndTheRangeLimit() throws Exception {
        assertThat(titles(search(ADMIN, "user=" + APPROVER + "&limit=200"))).contains("AU retail", "AU move")
                .doesNotContain((String) null);
        // version (LLD §18.4): changes made by requests raised in it
        assertThat(titles(search(ADMIN, "version=AU working&limit=200")))
                .contains("AU retail", "AU wholesale", "AU move", "AU other hierarchy");
        ownerJdbc().sql("INSERT INTO mdm.version (version_name, business_as_of) VALUES ('AU empty', current_date) ON CONFLICT DO NOTHING").update();
        assertThat(titles(search(ADMIN, "version=AU empty"))).isEmpty();
        mvc.perform(get("/api/v1/audit").param("version", "AU no such").with(asUser(ADMIN))).andExpect(status().isBadRequest());
        mvc.perform(get("/api/v1/audit").param("user", "au_nobody").with(asUser(ADMIN))).andExpect(status().isBadRequest());   // unknown login
        assertThat(titles(search(ADMIN, "user=" + VIEWER1))).isEmpty();   // a real user who changed nothing

        Set<String> seen = new HashSet<>();
        List<String> order = new ArrayList<>();
        String cursor = null;
        do {
            JsonNode page = search(ADMIN, "hierarchy=AU_H1&limit=1" + (cursor == null ? "" : "&cursor=" + cursor));
            for (JsonNode e : page.get("items")) {
                assertThat(seen.add(e.get("id").asText())).as("no entry twice").isTrue();
                order.add(e.get("occurredAt").asText());
            }
            cursor = page.get("nextCursor").isNull() ? null : page.get("nextCursor").asText();
        } while (cursor != null);
        assertThat(seen.size()).isGreaterThanOrEqualTo(4);
        assertThat(order).isSortedAccordingTo((a, b) -> b.compareTo(a));   // newest first

        LocalDate today = LocalDate.now();
        mvc.perform(get("/api/v1/audit").param("from", today.minusDays(400).toString()).with(asUser(ADMIN)))
                .andExpect(status().isBadRequest());
        mvc.perform(get("/api/v1/audit").param("from", today.minusDays(400).toString()).param("node", LEAF.toString()).with(asUser(ADMIN)))
                .andExpect(status().isOk());
        mvc.perform(get("/api/v1/audit").param("hierarchy", "NO_SUCH").with(asUser(ADMIN))).andExpect(status().isBadRequest());
    }

    @Test
    void aRequestsHistoryListsEverythingInOrderWithWhoDidIt() throws Exception {
        String id = ownerJdbc().sql("SELECT change_request_id FROM mdm.change_request WHERE title = 'AU wholesale'")
                .query(UUID.class).single().toString();
        MvcResult r = mvc.perform(get("/api/v1/change-requests/" + id + "/history").with(asUser(VIEWER1)))
                .andExpect(status().isOk()).andReturn();
        JsonNode items = mapper.readTree(r.getResponse().getContentAsString()).get("items");
        List<String> events = new ArrayList<>();
        for (JsonNode e : items) {
            String type = e.get("type").asText();
            events.add("status".equals(type) ? "status:" + e.get("data").get("to").asText() : type);
        }
        assertThat(events).containsExactly("created", "item_added", "status:submitted", "status:approved", "status:applied");
        assertThat(items.get(0).get("actor").asText()).isEqualTo(STEWARD);
        assertThat(items.get(1).get("data").get("item").get("action").asText()).isEqualTo("set_property");
        assertThat(items.get(1).get("data").get("item").get("propertyCode").asText()).isEqualTo("AU.Segment");
        assertThat(items.get(3).get("actor").asText()).isEqualTo(APPROVER);
        assertThat(items.get(3).get("data").get("note").asText()).isEqualTo("AU");

        grant("au_viewer2", "VIEWER", "AU_H2", null);   // cannot see a request on AU_H1
        mvc.perform(get("/api/v1/change-requests/" + id + "/history").with(asUser("au_viewer2"))).andExpect(status().isNotFound());
        MvcResult paged = mvc.perform(get("/api/v1/change-requests/" + id + "/history").param("limit", "2").with(asUser(VIEWER1)))
                .andExpect(status().isOk()).andReturn();
        JsonNode first = mapper.readTree(paged.getResponse().getContentAsString());
        mvc.perform(get("/api/v1/change-requests/" + id + "/history").param("limit", "2").param("cursor", first.get("nextCursor").asText())
                        .with(asUser(VIEWER1)))
                .andExpect(jsonPath("$.items[0].type").value("status"))
                .andExpect(jsonPath("$.items[0].data.to").value("submitted"));
    }

    // ------------------------------------------------------------------ helpers

    private JsonNode search(String login, String query) throws Exception {
        MvcResult r = mvc.perform(get("/api/v1/audit?" + query).with(asUser(login))).andExpect(status().isOk()).andReturn();
        return mapper.readTree(r.getResponse().getContentAsString());
    }

    private static List<String> titles(JsonNode page) {
        List<String> out = new ArrayList<>();
        page.get("items").forEach(e -> out.add(e.get("changeRequestTitle").isNull() ? null : e.get("changeRequestTitle").asText()));
        return out;
    }

    /** A request by the steward, approved by the approver, applied. */
    private void applied(String title, String item) throws Exception {
        MvcResult r = mvc.perform(post("/api/v1/change-requests").with(asUser(STEWARD)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"versionName\":\"AU working\",\"title\":\"" + title + "\"}"))
                .andExpect(status().isCreated()).andReturn();
        String id = mapper.readTree(r.getResponse().getContentAsString()).get("id").asText();
        perform(post("/api/v1/change-requests/" + id + "/items"), STEWARD, id, item).andExpect(status().isCreated());
        mvc.perform(post("/api/v1/change-requests/" + id + "/submit").with(asUser(STEWARD)).header("If-Match", etag(STEWARD, id)))
                .andExpect(status().isOk());
        perform(post("/api/v1/change-requests/" + id + "/decision"), APPROVER, id, "{\"decision\":\"approve\",\"note\":\"AU\"}")
                .andExpect(jsonPath("$.status").value("applied"));
    }

    private ResultActions perform(org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder b, String login, String id,
                                  String body) throws Exception {
        return mvc.perform(b.with(asUser(login)).header("If-Match", etag(login, id)).contentType(MediaType.APPLICATION_JSON).content(body));
    }

    private String etag(String login, String id) throws Exception {
        return mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(login))).andReturn().getResponse().getHeader("ETag");
    }
}
