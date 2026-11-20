package com.mdm.api.node;

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

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Node display names and hierarchy descriptions (ADR-046 D1 and D8, Phase 4 LLD §17.2): the code stays the node name
 * (the business key); the display name is written by add_node, update_node and add_hierarchy, and read back by node
 * detail, the children page, in-tree search and search across hierarchies.
 */
class DisplayNameApiTest extends PostgresIntegrationTest {

    static final UUID TOP = UUID.fromString("00000000-0000-0000-0000-0000000d1501");
    static final String EDITOR = "dn_editor";
    static final String APPROVER = "dn_approver";
    static final String ALL_EDITOR = "dn_all_editor";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    @BeforeEach
    void seed() {
        JdbcClient jdbc = ownerJdbc();
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'DN_H'").query(Integer.class).single() == 0) {
            jdbc.sql("INSERT INTO mdm.version (version_name, business_as_of) VALUES ('DN working', current_date)").update();
            jdbc.sql("INSERT INTO mdm.node (node_id, node_kind) VALUES (:t, 'structural')").param("t", TOP).update();
            jdbc.sql("""
                    INSERT INTO mdm.node_attr (node_id, node_name, display_name, allows_children, valid_period)
                    VALUES (:t, 'DNTOP', 'Display name top', true, daterange('2020-01-01', NULL))
                    """).param("t", TOP).update();
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, purpose, top_node_id)
                    VALUES ('DN_H', 'Display names', 'management', :t)
                    """).param("t", TOP).update();
        }
        grant(EDITOR, "EDITOR", "DN_H", null);
        grant(APPROVER, "APPROVER", "DN_H", null);
        grant(APPROVER, "APPROVER", null, null);
        grant(ALL_EDITOR, "EDITOR", null, null);
    }

    @Test
    void aNewNodeKeepsItsCodeAsNameAndShowsItsDisplayNameEverywhere() throws Exception {
        String id = create(EDITOR, "DN add a cost center");
        MvcResult added = addItem(EDITOR, id, "{\"action\":\"add_node\",\"hierarchyCode\":\"DN_H\",\"targetParentId\":\"" + TOP
                + "\",\"payload\":{\"nodeKind\":\"structural\",\"name\":\"91110\",\"displayName\":\"Planning Desk Dn\","
                + "\"description\":\"Cost center\",\"isLeaf\":true}}")
                .andExpect(status().isCreated()).andReturn();
        String node = json(added).get("nodeId").asText();
        submit(EDITOR, id).andExpect(status().isOk());
        decide(APPROVER, id).andExpect(jsonPath("$.status").value("applied"));

        mvc.perform(get("/api/v1/nodes/" + node).param("hierarchy", "DN_H").with(asUser(EDITOR)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.name").value("91110"))
                .andExpect(jsonPath("$.displayName").value("Planning Desk Dn"))
                .andExpect(jsonPath("$.description").value("Cost center"));
        JsonNode child = json(mvc.perform(get("/api/v1/hierarchies/DN_H/children").param("parentId", TOP.toString())
                .with(asUser(EDITOR))).andExpect(status().isOk()).andReturn()).get("items").get(0);
        assertThat(child.get("name").asText()).isEqualTo("91110");
        assertThat(child.get("displayName").asText()).isEqualTo("Planning Desk Dn");

        JsonNode inTree = json(mvc.perform(get("/api/v1/hierarchies/DN_H/search").param("q", "planning desk")
                .with(asUser(EDITOR))).andExpect(status().isOk()).andReturn()).get("items").get(0);
        assertThat(inTree.get("displayName").asText()).isEqualTo("Planning Desk Dn");
        JsonNode hit = json(mvc.perform(get("/api/v1/search").param("q", "planning desk").param("type", "nodes")
                .with(asUser(EDITOR))).andExpect(status().isOk()).andReturn()).get("nodes").get("items").get(0);
        assertThat(hit.get("name").asText()).isEqualTo("91110");
        assertThat(hit.get("displayName").asText()).isEqualTo("Planning Desk Dn");
        assertThat(hit.get("matched").asText()).isEqualTo("displayName");
    }

    @Test
    void updateNodeChangesTheDisplayNameAloneAndAnEmptyUpdateIsRefused() throws Exception {
        String id = create(EDITOR, "DN add then rename");
        String node = json(addItem(EDITOR, id, "{\"action\":\"add_node\",\"hierarchyCode\":\"DN_H\",\"targetParentId\":\"" + TOP
                + "\",\"payload\":{\"nodeKind\":\"structural\",\"name\":\"91120\",\"displayName\":\"Old label\",\"isLeaf\":true}}")
                .andExpect(status().isCreated()).andReturn()).get("nodeId").asText();
        submit(EDITOR, id).andExpect(status().isOk());
        decide(APPROVER, id).andExpect(jsonPath("$.status").value("applied"));

        String rename = create(EDITOR, "DN rename");
        addItem(EDITOR, rename, "{\"action\":\"update_node\",\"hierarchyCode\":\"DN_H\",\"nodeId\":\"" + node + "\",\"payload\":{}}")
                .andExpect(status().isBadRequest());
        MvcResult item = addItem(EDITOR, rename, "{\"action\":\"update_node\",\"hierarchyCode\":\"DN_H\",\"nodeId\":\"" + node
                + "\",\"payload\":{\"displayName\":\"New label\"}}").andExpect(status().isCreated()).andReturn();
        assertThat(json(item).get("payload").get("expected").get("displayName").asText()).isEqualTo("Old label");
        submit(EDITOR, rename).andExpect(status().isOk());
        decide(APPROVER, rename).andExpect(jsonPath("$.status").value("applied"));

        mvc.perform(get("/api/v1/nodes/" + node).param("hierarchy", "DN_H").with(asUser(EDITOR)))
                .andExpect(jsonPath("$.name").value("91120"))
                .andExpect(jsonPath("$.displayName").value("New label"));
    }

    @Test
    void aNewHierarchyKeepsItsDescriptionAndItsTopNodeDisplayName() throws Exception {
        String id = create(ALL_EDITOR, "DN new hierarchy");
        addItem(ALL_EDITOR, id, "{\"action\":\"add_hierarchy\",\"payload\":{\"code\":\"DN_NEW\",\"name\":\"DN new\","
                + "\"description\":\"Alternate view\",\"topNode\":{\"nodeKind\":\"structural\",\"name\":\"DNNEW\","
                + "\"displayName\":\"DN new top\"}}}").andExpect(status().isCreated());
        submit(ALL_EDITOR, id).andExpect(status().isOk());
        // a request that only creates a hierarchy is seen by readers of every hierarchy, not by a one-hierarchy reader
        mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(EDITOR))).andExpect(status().isNotFound());
        decide(APPROVER, id).andExpect(jsonPath("$.status").value("applied"));

        grant(EDITOR, "VIEWER", "DN_NEW", null);
        mvc.perform(get("/api/v1/hierarchies/DN_NEW").with(asUser(EDITOR)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.description").value("Alternate view"))
                .andExpect(jsonPath("$.topNodeName").value("DNNEW"))
                .andExpect(jsonPath("$.topNodeDisplayName").value("DN new top"));
    }

    private String create(String login, String title) throws Exception {
        MvcResult r = mvc.perform(post("/api/v1/change-requests").with(asUser(login)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"versionName\":\"DN working\",\"title\":\"" + title + "\"}"))
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

    private ResultActions decide(String login, String id) throws Exception {
        return mvc.perform(post("/api/v1/change-requests/" + id + "/decision").with(asUser(login)).header("If-Match", etag(login, id))
                .contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"approve\",\"note\":\"DN test\"}"));
    }

    private String etag(String login, String id) throws Exception {
        return mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(login))).andReturn().getResponse().getHeader("ETag");
    }

    private JsonNode json(MvcResult r) throws Exception {
        return mapper.readTree(r.getResponse().getContentAsString());
    }
}
