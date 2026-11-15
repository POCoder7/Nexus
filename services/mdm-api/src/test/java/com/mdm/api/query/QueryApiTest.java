package com.mdm.api.query;

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

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * QRY-01 property queries (Phase 5 LLD §17.5, §17.13; increment 5-13a): groups, attributes and columns with provenance;
 * paging, and the scan budget with continuation (the union of the pages is the full answer); refusals; saved queries,
 * shared and private, and their limit. Read scope is by hierarchy until 5-5 (ADR-041). Synthetic data only.
 */
class QueryApiTest extends PostgresIntegrationTest {

    static final String H = "QA_H";
    static final UUID TOP = id(1);
    static final UUID R1 = id(2);
    static final UUID R2 = id(3);
    static final String READER = "qa_reader";
    static final String READER2 = "qa_reader2";
    static final String OUTSIDER = "qa_outsider";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    static UUID id(int n) {
        return UUID.fromString(String.format("00000000-0000-0000-0000-0000005a%04x", n));
    }

    /** Leaf n (1 to 20): leaves 1 to 10 under region 1, 11 to 20 under region 2. */
    static UUID leaf(int n) {
        return id(100 + n);
    }

    @BeforeEach
    void seed() {
        JdbcClient jdbc = ownerJdbc();
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = :h").param("h", H).query(Integer.class).single() == 0) {
            node(jdbc, TOP, "QA Top", true);
            node(jdbc, R1, "QA Region 1", true);
            node(jdbc, R2, "QA Region 2", true);
            for (int n = 1; n <= 20; n++) {
                node(jdbc, leaf(n), String.format("QA Leaf %02d", n), false);
            }
            jdbc.sql("INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, top_node_id) VALUES (:h, 'Query test', :t)")
                    .param("h", H).param("t", TOP).update();
            link(jdbc, TOP, R1);
            link(jdbc, TOP, R2);
            for (int n = 1; n <= 20; n++) {
                link(jdbc, n <= 10 ? R1 : R2, leaf(n));
            }
            jdbc.sql("""
                    INSERT INTO mdm.property_definition (property_code, label, data_type, scope, inheritance) VALUES
                      ('QA.Ccy', 'Currency', 'string', 'global', 'inherit_from_ancestor'),
                      ('QA.Code', 'Code', 'string', 'global', 'none'),
                      ('QA.Amt', 'Amount', 'integer', 'global', 'none')
                    """).update();
            value(jdbc, TOP, "QA.Ccy", "\"EUR\"");
            value(jdbc, R1, "QA.Ccy", "\"USD\"");
            for (int n = 1; n <= 20; n++) {
                value(jdbc, leaf(n), "QA.Amt", String.valueOf(n));
                if (n % 2 == 1) {
                    value(jdbc, leaf(n), "QA.Code", "\"Z" + n + "\"");
                }
            }
        }
        grant(READER, "VIEWER", H, null);
        grant(READER2, "VIEWER", H, null);
        ensureUser(OUTSIDER, "human");
    }

    private static void node(JdbcClient jdbc, UUID id, String name, boolean limb) {
        jdbc.sql("INSERT INTO mdm.node (node_id, node_kind) VALUES (:n, 'structural')").param("n", id).update();
        jdbc.sql("""
                INSERT INTO mdm.node_attr (node_id, node_name, allows_children, valid_period)
                VALUES (:n, :name, :limb, daterange('2020-01-01', NULL))
                """).param("n", id).param("name", name).param("limb", limb).update();
    }

    private static void link(JdbcClient jdbc, UUID parent, UUID child) {
        jdbc.sql("""
                INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, valid_period)
                SELECT hierarchy_id, :p, :c, daterange('2020-01-01', NULL) FROM mdm.hierarchy WHERE hierarchy_code = :h
                """).param("p", parent).param("c", child).param("h", H).update();
    }

    private static void value(JdbcClient jdbc, UUID node, String code, String json) {
        jdbc.sql("""
                INSERT INTO mdm.property_value (node_id, property_id, value, valid_period)
                SELECT :n, property_id, CAST(:v AS jsonb), daterange('2020-01-01', NULL) FROM mdm.property_definition
                WHERE property_code = :c
                """).param("n", node).param("v", json).param("c", code).update();
    }

    // ------------------------------------------------------------------ running

    @Test
    void groupsAttributesAndColumnsWithProvenance() throws Exception {
        // leaves whose currency is EUR (inherited from the top, through region 2) or whose code starts with Z (odd leaves)
        String where = """
                {"all": [{"attribute": "isLeaf", "op": "=", "value": true},
                         {"any": [{"property": "QA.Ccy", "op": "=", "value": "EUR"},
                                  {"property": "QA.Code", "op": "starts_with", "value": "Z"}]}]}""";
        JsonNode page = json(run(READER, where, "\"QA.Ccy\", \"QA.Code\"", 100, null).andExpect(status().isOk()).andReturn());
        List<String> expected = new ArrayList<>();
        for (int n = 1; n <= 20; n++) {
            if (n > 10 || n % 2 == 1) {
                expected.add(String.format("QA Leaf %02d", n));
            }
        }
        assertThat(names(page)).containsExactlyElementsOf(expected);   // (name, id) order
        assertThat(page.get("partial").asBoolean()).isFalse();
        assertThat(page.get("nextCursor").isNull()).isTrue();
        JsonNode leaf1 = page.get("items").get(0);
        assertThat(leaf1.get("parentName").asText()).isEqualTo("QA Region 1");
        assertThat(leaf1.at("/columns/0/value").asText()).isEqualTo("USD");
        assertThat(leaf1.at("/columns/0/provenance").asText()).isEqualTo("inherited");
        assertThat(leaf1.at("/columns/0/sourceNodeId").asText()).isEqualTo(R1.toString());
        assertThat(leaf1.at("/columns/1/value").asText()).isEqualTo("Z1");
        assertThat(leaf1.at("/columns/1/provenance").asText()).isEqualTo("stored");
    }

    @Test
    void numbersCompareAsNumbersAndTextCanIgnoreCase() throws Exception {
        assertThat(names(json(run(READER, "{\"property\": \"QA.Amt\", \"op\": \"between\", \"value\": [9, 11]}", "", 100, null).andReturn())))
                .containsExactly("QA Leaf 09", "QA Leaf 10", "QA Leaf 11");
        assertThat(names(json(run(READER, "{\"property\": \"QA.Amt\", \"op\": \"gt\", \"value\": 18}", "", 100, null).andReturn())))
                .containsExactly("QA Leaf 19", "QA Leaf 20");
        assertThat(names(json(run(READER, "{\"attribute\": \"name\", \"op\": \"contains\", \"value\": \"REGION\", \"ci\": true}", "", 100, null)
                .andReturn()))).containsExactly("QA Region 1", "QA Region 2");
        assertThat(names(json(run(READER, "{\"attribute\": \"level\", \"op\": \"=\", \"value\": 1}", "", 100, null).andReturn())))
                .containsExactly("QA Top");
    }

    @Test
    void pagesAreKeysetPagesWhoseUnionIsTheFullAnswer() throws Exception {
        String where = "{\"attribute\": \"isLeaf\", \"op\": \"=\", \"value\": true}";
        List<String> all = names(json(run(READER, where, "", 100, null).andReturn()));
        assertThat(all).hasSize(20);
        List<String> paged = new ArrayList<>();
        String cursor = null;
        int pages = 0;
        do {
            JsonNode page = json(run(READER, where, "", 6, cursor).andExpect(status().isOk()).andReturn());
            paged.addAll(names(page));
            assertThat(page.get("partial").asBoolean()).isFalse();
            cursor = page.get("nextCursor").isNull() ? null : page.get("nextCursor").asText();
            pages++;
        } while (cursor != null);
        assertThat(pages).isEqualTo(4);
        assertThat(paged).containsExactlyElementsOf(all);
    }

    @Test
    void theScanBudgetGivesPartialPagesThatContinueToTheFullAnswer() throws Exception {
        JdbcClient owner = ownerJdbc();
        owner.sql("UPDATE mdm.system_setting SET setting_value = '7' WHERE setting_key = 'query_scan_max'").update();
        try {
            String where = "{\"property\": \"QA.Code\", \"op\": \"not_null\"}";   // the 10 odd leaves, among 23 nodes
            List<String> paged = new ArrayList<>();
            String cursor = null;
            boolean sawPartial = false;
            int guard = 0;
            do {
                JsonNode page = json(run(READER, where, "", 100, cursor).andExpect(status().isOk()).andReturn());
                assertThat(page.get("scanned").asLong()).isLessThanOrEqualTo(7);
                sawPartial |= page.get("partial").asBoolean();
                paged.addAll(names(page));
                cursor = page.get("nextCursor").isNull() ? null : page.get("nextCursor").asText();
            } while (cursor != null && ++guard < 20);
            assertThat(sawPartial).as("a page stopped at the budget and said so").isTrue();
            List<String> expected = new ArrayList<>();
            for (int n = 1; n <= 20; n += 2) {
                expected.add(String.format("QA Leaf %02d", n));
            }
            assertThat(paged).containsExactlyElementsOf(expected);
        } finally {
            owner.sql("UPDATE mdm.system_setting SET setting_value = '50000' WHERE setting_key = 'query_scan_max'").update();
        }
    }

    @Test
    void aPastDateSeesThePastAndSubTreesNarrowTheSearch() throws Exception {
        mvc.perform(post("/api/v1/queries/run?asOf=2019-06-01").with(asUser(READER)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"definition\": {\"hierarchyCode\": \"" + H + "\"}}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.items").isEmpty());
        String body = "{\"definition\": {\"hierarchyCode\": \"" + H + "\", \"rootNodeId\": \"" + R1 + "\", \"include\": \"leaves\"}}";
        JsonNode page = json(mvc.perform(post("/api/v1/queries/run").with(asUser(READER)).contentType(MediaType.APPLICATION_JSON)
                .content(body)).andExpect(status().isOk()).andReturn());
        assertThat(names(page)).hasSize(10).allMatch(n -> n.compareTo("QA Leaf 11") < 0);
    }

    @Test
    void invalidQueriesAreRefusedWithTheirCodes() throws Exception {
        run(READER, "{\"property\": \"QA.Code\", \"op\": \"regex\", \"value\": \"x\"}", "", 10, null)
                .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.sqlState").value("N2604"));
        run(READER, "{\"property\": \"QA.Nope\", \"op\": \"is_null\"}", "", 10, null)
                .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.sqlState").value("N2605"));
        run(READER, "{\"all\": [{\"all\": [{\"all\": [{\"all\": [{\"all\": [{\"all\": [{\"attribute\": \"isLeaf\", \"op\": \"is_null\"}]}]}]}]}]}]}",
                "", 10, null)
                .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.sqlState").value("N2807"));
        run(READER, "{\"all\": []}", "\"QA.Nope\"", 10, null)
                .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.code").value("query.unknown_column"));
        run(OUTSIDER, "{\"all\": []}", "", 10, null).andExpect(status().isNotFound());
    }

    // ------------------------------------------------------------------ saved queries

    @Test
    void savedQueriesAreTheOwnersAndSharingNeverSharesMoreThanTheReaderCanSee() throws Exception {
        String definition = "{\"hierarchyCode\": \"" + H + "\", \"include\": \"leaves\", \"where\": {\"property\": \"QA.Amt\", \"op\": \"le\", \"value\": 2}}";
        MvcResult created = mvc.perform(post("/api/v1/queries").with(asUser(READER)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\": \"Small amounts " + UUID.randomUUID() + "\", \"definition\": " + definition + "}"))
                .andExpect(status().isCreated()).andExpect(header().string("ETag", "\"1\""))
                .andExpect(jsonPath("$.visibility").value("private")).andExpect(jsonPath("$.mine").value(true))
                .andReturn();
        String id = json(created).get("id").asText();
        mvc.perform(post("/api/v1/queries/" + id + "/run").with(asUser(READER)))
                .andExpect(status().isOk()).andExpect(jsonPath("$.items.length()").value(2));
        mvc.perform(get("/api/v1/queries/" + id).with(asUser(READER2))).andExpect(status().isNotFound());   // private

        String shared = "{\"name\": \"Shared small amounts " + UUID.randomUUID() + "\", \"visibility\": \"shared\", \"definition\": " + definition + "}";
        mvc.perform(put("/api/v1/queries/" + id).with(asUser(READER)).header("If-Match", "\"9\"")
                .contentType(MediaType.APPLICATION_JSON).content(shared)).andExpect(status().isPreconditionFailed());
        mvc.perform(put("/api/v1/queries/" + id).with(asUser(READER)).header("If-Match", "\"1\"")
                        .contentType(MediaType.APPLICATION_JSON).content(shared))
                .andExpect(status().isOk()).andExpect(header().string("ETag", "\"2\""));

        mvc.perform(get("/api/v1/queries").with(asUser(READER2)))
                .andExpect(jsonPath("$.items[?(@.id == '" + id + "')].mine").value(false));
        mvc.perform(post("/api/v1/queries/" + id + "/run").with(asUser(READER2)))
                .andExpect(status().isOk()).andExpect(jsonPath("$.items.length()").value(2));
        mvc.perform(put("/api/v1/queries/" + id).with(asUser(READER2)).header("If-Match", "\"2\"")
                .contentType(MediaType.APPLICATION_JSON).content(shared)).andExpect(status().isForbidden());
        mvc.perform(get("/api/v1/queries/" + id).with(asUser(OUTSIDER))).andExpect(status().isNotFound());
        mvc.perform(post("/api/v1/queries/" + id + "/run").with(asUser(OUTSIDER))).andExpect(status().isNotFound());

        mvc.perform(delete("/api/v1/queries/" + id).with(asUser(READER)).header("If-Match", "\"2\"")).andExpect(status().isNoContent());
        mvc.perform(get("/api/v1/queries/" + id).with(asUser(READER))).andExpect(status().isNotFound());
    }

    @Test
    void aSavedQueryIsCheckedLikeARunAndEachPersonHasALimit() throws Exception {
        mvc.perform(post("/api/v1/queries").with(asUser(READER2)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\": \"Broken\", \"definition\": {\"hierarchyCode\": \"" + H + "\", \"where\": {\"property\": \"QA.Nope\", \"op\": \"is_null\"}}}"))
                .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.sqlState").value("N2605"));

        JdbcClient owner = ownerJdbc();
        assertThat(owner.sql("SELECT setting_value FROM mdm.system_setting WHERE setting_key = 'saved_query_max_per_user'")
                .query(String.class).single()).isEqualTo("200");
        String limiter = "qa_limiter";
        grant(limiter, "VIEWER", H, null);
        owner.sql("UPDATE mdm.system_setting SET setting_value = '2' WHERE setting_key = 'saved_query_max_per_user'").update();
        try {
            for (int i = 0; i < 2; i++) {
                save(limiter, "Mine " + i).andExpect(status().isCreated());
            }
            save(limiter, "One too many").andExpect(status().isUnprocessableEntity())
                    .andExpect(jsonPath("$.code").value("query.too_many_saved"));
        } finally {
            owner.sql("UPDATE mdm.system_setting SET setting_value = '200' WHERE setting_key = 'saved_query_max_per_user'").update();
        }
    }

    @Test
    void propertyDefinitionsAreListedForThePickerButNotToPeopleWithoutAccess() throws Exception {
        mvc.perform(get("/api/v1/property-definitions?limit=1000").with(asUser(READER)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items[?(@.code == 'QA.Amt')].dataType").value("integer"))
                .andExpect(jsonPath("$.items[?(@.code == 'QA.Ccy')].inheritance").value("inherit_from_ancestor"));
        mvc.perform(get("/api/v1/property-definitions?origin=derived&limit=1000").with(asUser(READER)))
                .andExpect(status().isOk()).andExpect(jsonPath("$.items[?(@.code == 'QA.Amt')]").isEmpty());
        mvc.perform(get("/api/v1/property-definitions").with(asUser(OUTSIDER))).andExpect(status().isForbidden());
    }

    // ------------------------------------------------------------------ helpers

    private ResultActions run(String login, String where, String columns, int limit, String cursor) throws Exception {
        String body = "{\"definition\": {\"hierarchyCode\": \"" + H + "\", \"where\": " + where + ", \"columns\": [" + columns + "]}}";
        return mvc.perform(post("/api/v1/queries/run?limit=" + limit + (cursor == null ? "" : "&cursor=" + cursor))
                .with(asUser(login)).contentType(MediaType.APPLICATION_JSON).content(body));
    }

    private ResultActions save(String login, String name) throws Exception {
        return mvc.perform(post("/api/v1/queries").with(asUser(login)).contentType(MediaType.APPLICATION_JSON)
                .content("{\"name\": \"" + name + " " + UUID.randomUUID() + "\", \"definition\": {\"hierarchyCode\": \"" + H + "\"}}"));
    }

    private static List<String> names(JsonNode page) {
        List<String> names = new ArrayList<>();
        page.get("items").forEach(i -> names.add(i.get("name").asText()));
        return names;
    }

    private JsonNode json(MvcResult r) throws Exception {
        return mapper.readTree(r.getResponse().getContentAsString());
    }
}
