package com.mdm.api.search;

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
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Search across hierarchies (QRY-03; Phase 5 LLD §17.6, §17.6.1, §17.13): hierarchies, nodes (substring, several words,
 * identifiers, ranking, shared nodes in several hierarchies) and requests, each limited to what the user can see.
 */
class SearchApiTest extends PostgresIntegrationTest {

    static final UUID TOP1 = UUID.fromString("00000000-0000-0000-0000-0000000f5e01");
    static final UUID TOP2 = UUID.fromString("00000000-0000-0000-0000-0000000f5e02");
    static final UUID TOP3 = UUID.fromString("00000000-0000-0000-0000-0000000f5e03");
    static final UUID ALPHA_NORTH = UUID.fromString("00000000-0000-0000-0000-0000000f5e11");
    static final UUID ALPHA_SHARED = UUID.fromString("00000000-0000-0000-0000-0000000f5e12");
    static final UUID BETA = UUID.fromString("00000000-0000-0000-0000-0000000f5e13");
    static final UUID BETA_TWO = UUID.fromString("00000000-0000-0000-0000-0000000f5e14");
    static final UUID ABOUT = UUID.fromString("00000000-0000-0000-0000-0000000f5e15");
    static final UUID HIDDEN = UUID.fromString("00000000-0000-0000-0000-0000000f5e16");
    static final String VIEWER = "sr_viewer";     // reads SR_H1 and SR_H2
    static final String OUTSIDER = "sr_outsider"; // reads SR_H3 only
    static final String EDITOR = "sr_editor";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    static boolean requested;

    @BeforeEach
    void seed() throws Exception {
        JdbcClient jdbc = ownerJdbc();
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'SR_H1'").query(Integer.class).single() == 0) {
            jdbc.sql("INSERT INTO mdm.version (version_name, business_as_of) VALUES ('SR working', current_date)").update();
            String nodes = """
                    INSERT INTO mdm.node (node_id, node_kind) VALUES (:t1, 'structural'), (:t2, 'structural'), (:t3, 'structural'),
                      (:a, 'legal_entity'), (:s, 'legal_entity'), (:b, 'legal_entity'), (:b2, 'legal_entity'), (:ab, 'legal_entity'),
                      (:h, 'legal_entity')
                    """;
            jdbc.sql(nodes).param("t1", TOP1).param("t2", TOP2).param("t3", TOP3).param("a", ALPHA_NORTH).param("s", ALPHA_SHARED)
                    .param("b", BETA).param("b2", BETA_TWO).param("ab", ABOUT).param("h", HIDDEN).update();
            jdbc.sql("""
                    INSERT INTO mdm.node_attr (node_id, node_name, description, allows_children, valid_period) VALUES
                      (:t1, 'SR top one', NULL, true, daterange('2020-01-01', NULL)), (:t2, 'SR top two', NULL, true, daterange('2020-01-01', NULL)),
                      (:t3, 'SR top three', NULL, true, daterange('2020-01-01', NULL)),
                      (:a, 'Alpha North', 'Synthetic entity', false, daterange('2020-01-01', NULL)),
                      (:s, 'Alpha Shared', 'Synthetic entity', false, daterange('2020-01-01', NULL)),
                      (:b, 'Beta', NULL, false, daterange('2020-01-01', NULL)), (:b2, 'Beta two', NULL, false, daterange('2020-01-01', NULL)),
                      (:ab, 'About things', 'Mentions beta in passing', false, daterange('2020-01-01', NULL)),
                      (:h, 'Alpha hidden', NULL, false, daterange('2020-01-01', NULL))
                    """).param("t1", TOP1).param("t2", TOP2).param("t3", TOP3).param("a", ALPHA_NORTH).param("s", ALPHA_SHARED)
                    .param("b", BETA).param("b2", BETA_TWO).param("ab", ABOUT).param("h", HIDDEN).update();
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, purpose, top_node_id, allow_shared_nodes) VALUES
                      ('SR_H1', 'Search Org One', 'management', :t1, true), ('SR_H2', 'Search Other', 'tax', :t2, false),
                      ('SR_H3', 'Search Hidden', 'other', :t3, false)
                    """).param("t1", TOP1).param("t2", TOP2).param("t3", TOP3).update();
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, is_primary, valid_period)
                    SELECT h.hierarchy_id, v.p, v.c, v.prim, daterange('2020-01-01', NULL)
                    FROM mdm.hierarchy h JOIN (VALUES
                      ('SR_H1', CAST(:t1 AS uuid), CAST(:a AS uuid), true), ('SR_H1', :t1, :s, true), ('SR_H1', :a, :s, false),
                      ('SR_H1', :t1, :b, true), ('SR_H1', :t1, :b2, true), ('SR_H1', :t1, :ab, true),
                      ('SR_H2', :t2, :s, true), ('SR_H3', :t3, :h, true)) AS v(code, p, c, prim) ON v.code = h.hierarchy_code
                    """).param("t1", TOP1).param("t2", TOP2).param("t3", TOP3).param("a", ALPHA_NORTH).param("s", ALPHA_SHARED)
                    .param("b", BETA).param("b2", BETA_TWO).param("ab", ABOUT).param("h", HIDDEN).update();
            jdbc.sql("""
                    INSERT INTO mdm.node_identifier (node_id, scheme_code, identifier_value, source, valid_period)
                    VALUES (:b2, 'UK_CRN', 'SRX00123', 'manual', daterange('2020-01-01', NULL))
                    """).param("b2", BETA_TWO).update();
        }
        grant(VIEWER, "VIEWER", "SR_H1", null);
        grant(VIEWER, "VIEWER", "SR_H2", null);
        grant(OUTSIDER, "VIEWER", "SR_H3", null);
        grant(EDITOR, "EDITOR", "SR_H1", null);
        if (!requested) {
            requested = true;
            MvcResult r = mvc.perform(post("/api/v1/change-requests").with(asUser(EDITOR)).contentType(MediaType.APPLICATION_JSON)
                            .content("{\"versionName\":\"SR working\",\"title\":\"Search request zeta\"}"))
                    .andExpect(status().isCreated()).andReturn();
            String id = mapper.readTree(r.getResponse().getContentAsString()).get("id").asText();
            String etag = mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(EDITOR))).andReturn().getResponse().getHeader("ETag");
            mvc.perform(post("/api/v1/change-requests/" + id + "/items").with(asUser(EDITOR)).header("If-Match", etag)
                    .contentType(MediaType.APPLICATION_JSON)
                    .content("{\"action\":\"update_node\",\"hierarchyCode\":\"SR_H1\",\"nodeId\":\"" + BETA + "\",\"payload\":{\"name\":\"Beta renamed\"}}"))
                    .andExpect(status().isCreated());
            String etag2 = mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(EDITOR))).andReturn().getResponse().getHeader("ETag");
            mvc.perform(post("/api/v1/change-requests/" + id + "/submit").with(asUser(EDITOR)).header("If-Match", etag2))
                    .andExpect(status().isOk());
        }
    }

    @Test
    void nodesAreFoundInEveryReadableHierarchyTheyArePlacedIn() throws Exception {
        JsonNode nodes = search(VIEWER, "q=alpha&type=nodes").get("nodes");
        List<String> hits = new ArrayList<>();
        nodes.get("items").forEach(n -> hits.add(n.get("name").asText() + "@" + n.get("hierarchyCode").asText()));
        assertThat(hits).containsExactly("Alpha North@SR_H1", "Alpha Shared@SR_H1", "Alpha Shared@SR_H2");   // Alpha hidden: SR_H3
        JsonNode sharedInH1 = nodes.get("items").get(1);
        assertThat(sharedInH1.get("shared").asBoolean()).isTrue();
        assertThat(sharedInH1.get("parentName").asText()).isEqualTo("SR top one");
        assertThat(sharedInH1.get("matched").asText()).isEqualTo("name");
    }

    @Test
    void anExactNameRanksFirstThenPrefixesThenTheRest() throws Exception {
        List<String> names = new ArrayList<>();
        search(VIEWER, "q=beta&type=nodes").get("nodes").get("items").forEach(n -> names.add(n.get("name").asText()));
        assertThat(names).containsExactly("Beta", "Beta two", "About things");   // exact, prefix, description
        JsonNode id = search(VIEWER, "q=srx00123&type=nodes").get("nodes").get("items").get(0);
        assertThat(id.get("name").asText()).isEqualTo("Beta two");
        assertThat(id.get("matched").asText()).isEqualTo("identifier");
        List<String> both = new ArrayList<>();
        search(VIEWER, "q=north alpha&type=nodes").get("nodes").get("items").forEach(n -> both.add(n.get("name").asText()));
        assertThat(both).containsExactly("Alpha North");   // several words: every one must appear, in any order
    }

    @Test
    void hierarchiesAndRequestsComeInTheSameAnswer() throws Exception {
        JsonNode all = search(VIEWER, "q=search");
        List<String> codes = new ArrayList<>();
        all.get("hierarchies").forEach(h -> codes.add(h.get("code").asText()));
        assertThat(codes).containsExactlyInAnyOrder("SR_H1", "SR_H2");
        assertThat(search(VIEWER, "q=sr_h2").get("hierarchies").get(0).get("code").asText()).isEqualTo("SR_H2");
        assertThat(search(VIEWER, "q=management").get("hierarchies").get(0).get("code").asText()).isEqualTo("SR_H1");

        JsonNode zeta = search(VIEWER, "q=zeta").get("requests").get("items");
        assertThat(zeta).hasSize(1);
        assertThat(zeta.get(0).get("title").asText()).isEqualTo("Search request zeta");
        assertThat(zeta.get(0).get("status").asText()).isEqualTo("submitted");
        assertThat(search(OUTSIDER, "q=zeta").get("requests").get("items")).isEmpty();   // its hierarchy is not theirs
        assertThat(search(OUTSIDER, "q=search").get("hierarchies").findValuesAsText("code")).containsExactly("SR_H3");
    }

    @Test
    void pagingNeverSkipsOrRepeatsAndBadInputIsRefused() throws Exception {
        Set<String> seen = new HashSet<>();
        String cursor = null;
        int pages = 0;
        do {
            JsonNode page = search(VIEWER, "q=a&type=nodes&limit=1".replace("q=a", "q=al") + (cursor == null ? "" : "&cursor=" + cursor)).get("nodes");
            page.get("items").forEach(n -> assertThat(seen.add(n.get("nodeId").asText() + n.get("hierarchyCode").asText())).isTrue());
            cursor = page.get("nextCursor").isNull() ? null : page.get("nextCursor").asText();
            pages++;
        } while (cursor != null && pages < 20);
        assertThat(seen).hasSize(3);

        mvc.perform(get("/api/v1/search").param("q", "a").with(asUser(VIEWER)))
                .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.code").value("search.query_too_short"));
        mvc.perform(get("/api/v1/search").param("q", "alpha").param("type", "colours").with(asUser(VIEWER)))
                .andExpect(status().isBadRequest());
    }

    private JsonNode search(String login, String query) throws Exception {
        MvcResult r = mvc.perform(get("/api/v1/search?" + query).with(asUser(login)))   // MockMvc encodes the space once
                .andExpect(status().isOk()).andReturn();
        return mapper.readTree(r.getResponse().getContentAsString());
    }
}
