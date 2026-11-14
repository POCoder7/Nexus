package com.mdm.api.sandbox;

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
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * NEW-08 sandbox API (Phase 5 LLD §5, §13): the lifecycle end to end, the overlay equal to the tree after applying the
 * same items, conflicts and rebase, the limits, and owner versus viewer (F-1). Synthetic data only.
 */
class SandboxApiTest extends PostgresIntegrationTest {

    static final String H = "SB_H";
    static final UUID TOP = id(1);
    static final UUID A = id(2);
    static final UUID B = id(3);
    static final UUID C = id(4);
    static final UUID A1 = id(5);
    static final UUID A2 = id(6);
    static final UUID A3 = id(7);
    static final UUID B1 = id(8);
    static final UUID B2 = id(9);
    static final String STEWARD = "sb_steward";
    static final String OTHER = "sb_other";
    static final String APPROVER = "sb_approver";
    static final String VIEWER = "sb_viewer";
    static final String OUTSIDER = "sb_outsider";
    static final String LIMITER = "sb_limiter";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    static UUID id(int n) {
        return UUID.fromString(String.format("00000000-0000-0000-0000-0000005b%04x", n));
    }

    @BeforeEach
    void seed() {
        JdbcClient jdbc = ownerJdbc();
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = :h").param("h", H).query(Integer.class).single() == 0) {
            jdbc.sql("INSERT INTO mdm.version (version_name, business_as_of) VALUES ('SB working', current_date)").update();
            String[][] nodes = {{"1", "SB top"}, {"2", "SB A"}, {"3", "SB B"}, {"4", "SB C"}, {"5", "SB a1"}, {"6", "SB a2"},
                    {"7", "SB a3"}, {"8", "SB b1"}, {"9", "SB b2"}};
            for (String[] n : nodes) {
                UUID node = id(Integer.parseInt(n[0]));
                jdbc.sql("INSERT INTO mdm.node (node_id, node_kind) VALUES (:n, 'structural')").param("n", node).update();
                jdbc.sql("""
                        INSERT INTO mdm.node_attr (node_id, node_name, allows_children, valid_period)
                        VALUES (:n, :name, :kids, daterange('2020-01-01', NULL))
                        """).param("n", node).param("name", n[1]).param("kids", Integer.parseInt(n[0]) <= 4).update();
            }
            jdbc.sql("INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, top_node_id) VALUES (:h, 'Sandbox test', :t)")
                    .param("h", H).param("t", TOP).update();
            UUID[][] links = {{TOP, A}, {TOP, B}, {TOP, C}, {A, A1}, {A, A2}, {A, A3}, {B, B1}, {B, B2}};
            int sort = 1000;
            for (UUID[] l : links) {
                jdbc.sql("""
                        INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, sort_order, valid_period)
                        SELECT hierarchy_id, :p, :c, :s, daterange('2020-01-01', NULL) FROM mdm.hierarchy WHERE hierarchy_code = :h
                        """).param("p", l[0]).param("c", l[1]).param("s", sort).param("h", H).update();
                sort += 1000;
            }
            jdbc.sql("""
                    INSERT INTO mdm.property_definition (property_code, label, data_type, scope, inheritance)
                    VALUES ('SB.Ccy', 'Sandbox currency', 'string', 'global', 'inherit_from_ancestor')
                    """).update();
            jdbc.sql("""
                    INSERT INTO mdm.property_value (node_id, property_id, value, valid_period)
                    SELECT :a, property_id, '"EUR"', daterange('2020-01-01', NULL) FROM mdm.property_definition WHERE property_code = 'SB.Ccy'
                    """).param("a", A).update();
        }
        grant(STEWARD, "STEWARD", H, null);
        grant(OTHER, "STEWARD", H, null);
        grant(APPROVER, "APPROVER", H, null);
        grant(VIEWER, "VIEWER", H, null);
        grant(LIMITER, "STEWARD", H, null);
        ensureUser(OUTSIDER, "human");
    }

    // ------------------------------------------------------------------ lifecycle; overlay equals apply

    @Test
    void theOverlayShowsTheItemsAndEqualsTheTreeAfterApplyingThem() throws Exception {
        String sb = create(STEWARD, "Reorganise");
        String facts = facts();

        // items of five kinds, generated over the fixture: moves, an addition, a removal, a rename, a property
        List<String> items = new ArrayList<>();
        items.add(move(A1, B));
        items.add(move(B2, C));
        items.add("{\"action\":\"add_node\",\"hierarchyCode\":\"" + H + "\",\"targetParentId\":\"" + C
                + "\",\"payload\":{\"nodeKind\":\"structural\",\"name\":\"SB new\",\"isLeaf\":true}}");
        items.add("{\"action\":\"remove_node\",\"hierarchyCode\":\"" + H + "\",\"nodeId\":\"" + A2 + "\"}");
        items.add("{\"action\":\"update_node\",\"hierarchyCode\":\"" + H + "\",\"nodeId\":\"" + A3 + "\",\"payload\":{\"name\":\"SB a3 renamed\"}}");
        items.add("{\"action\":\"set_property\",\"hierarchyCode\":\"" + H + "\",\"nodeId\":\"" + B
                + "\",\"propertyCode\":\"SB.Ccy\",\"payload\":{\"value\":\"USD\"}}");
        UUID added = null;
        int version = 1;
        for (String item : items) {
            MvcResult r = addItem(STEWARD, sb, version, item)
                    .andExpect(status().isCreated())
                    .andExpect(header().string("ETag", "\"" + (version + 1) + "\""))
                    .andExpect(jsonPath("$.failures").isEmpty())
                    .andReturn();
            version++;
            if (json(r).at("/item/action").asText().equals("add_node")) {
                added = UUID.fromString(json(r).at("/item/nodeId").asText());
            }
        }

        // the overlay marks what changes
        JsonNode underB = json(mvc.perform(children(sb, B)).andExpect(status().isOk()).andReturn());
        assertThat(names(underB)).containsExactly("SB b1", "SB a1");
        assertThat(underB.at("/items/1/changed").asBoolean()).isTrue();
        assertThat(underB.at("/items/0/changed").asBoolean()).isFalse();
        JsonNode a1 = json(mvc.perform(get("/api/v1/sandboxes/" + sb + "/nodes/" + A1 + "?hierarchy=" + H).with(asUser(STEWARD)))
                .andExpect(status().isOk()).andReturn());
        assertThat(a1.at("/placements/0/parentId").asText()).isEqualTo(B.toString());
        JsonNode ccy = property(a1, "SB.Ccy");
        assertThat(ccy.get("value").asText()).isEqualTo("USD");
        assertThat(ccy.get("provenance").asText()).isEqualTo("inherited");
        assertThat(ccy.get("changed").asBoolean()).isTrue();
        JsonNode diff = json(mvc.perform(get("/api/v1/sandboxes/" + sb + "/diff").with(asUser(STEWARD))).andExpect(status().isOk()).andReturn());
        assertThat(diff.get("items")).isNotEmpty();
        UUID newNode = added;
        assertThat(diff.get("items")).anyMatch(d -> d.get("fact").asText().equals("attributes") && d.get("side").asText().equals("after")
                && d.get("nodeId").asText().equals(newNode.toString()) && d.at("/values/name").asText().equals("SB new"));
        mvc.perform(get("/api/v1/sandboxes/" + sb + "/conflicts").with(asUser(STEWARD)))
                .andExpect(status().isOk()).andExpect(jsonPath("$.items").isEmpty());
        mvc.perform(get("/api/v1/sandboxes/" + sb).with(asUser(STEWARD)))
                .andExpect(jsonPath("$.itemCount").value(6)).andExpect(jsonPath("$.conflictCount").value(0));

        List<String> overlay = tree(sb, List.of(TOP, A, B, C, newNode));
        assertThat(facts()).as("no fact row changes before apply").isEqualTo(facts);

        // a sandbox is not among the owner's change requests, and is edited only here
        mvc.perform(get("/api/v1/change-requests?mine=true").with(asUser(STEWARD)))
                .andExpect(jsonPath("$.items[?(@.id == '" + sb + "')]").isEmpty());
        mvc.perform(post("/api/v1/change-requests/" + sb + "/items").with(asUser(STEWARD)).header("If-Match", "\"" + version + "\"")
                        .contentType(MediaType.APPLICATION_JSON).content(move(B1, C)))
                .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.code").value("sandbox.use_sandbox_api"));

        // submit, decide, apply: the tree equals what the overlay showed
        mvc.perform(post("/api/v1/sandboxes/" + sb + "/submit").with(asUser(STEWARD)).header("If-Match", "\"" + version + "\""))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("submitted"))
                .andExpect(jsonPath("$.origin").value("sandbox"));
        mvc.perform(get("/api/v1/sandboxes/" + sb).with(asUser(STEWARD))).andExpect(jsonPath("$.kind").value("request"));
        String etag = mvc.perform(get("/api/v1/change-requests/" + sb).with(asUser(APPROVER))).andReturn().getResponse().getHeader("ETag");
        mvc.perform(post("/api/v1/change-requests/" + sb + "/decision").with(asUser(APPROVER)).header("If-Match", etag)
                        .contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"approve\"}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("applied"));
        assertThat(liveTree(List.of(TOP, A, B, C, newNode))).isEqualTo(overlay);
    }

    @Test
    void discardWithdrawsTheSandbox() throws Exception {
        String sb = create(STEWARD, "Throw away");
        addItem(STEWARD, sb, 1, move(B1, C)).andExpect(status().isCreated());
        mvc.perform(post("/api/v1/sandboxes/" + sb + "/discard").with(asUser(STEWARD)).header("If-Match", "\"2\""))
                .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("withdrawn"));
        mvc.perform(get("/api/v1/sandboxes?status=withdrawn").with(asUser(STEWARD)))
                .andExpect(jsonPath("$.items[?(@.id == '" + sb + "')]").isNotEmpty());
        String etag = mvc.perform(get("/api/v1/sandboxes/" + sb).with(asUser(STEWARD))).andReturn().getResponse().getHeader("ETag");
        mvc.perform(post("/api/v1/sandboxes/" + sb + "/items").with(asUser(STEWARD)).header("If-Match", etag)
                        .contentType(MediaType.APPLICATION_JSON).content(move(B1, A)))
                .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.code").value("sandbox.not_draft"));
    }

    // ------------------------------------------------------------------ conflicts and rebase

    @Test
    void aConflictBlocksSubmitUntilTheItemChangesAndRebaseKeepsItFlagged() throws Exception {
        String sb = create(STEWARD, "Conflicting");
        addItem(STEWARD, sb, 1, "{\"action\":\"update_node\",\"hierarchyCode\":\"" + H + "\",\"nodeId\":\"" + C
                + "\",\"payload\":{\"description\":\"from the sandbox\"}}").andExpect(status().isCreated());
        MvcResult clean = addItem(STEWARD, sb, 2, "{\"action\":\"set_property\",\"hierarchyCode\":\"" + H + "\",\"nodeId\":\"" + C
                + "\",\"propertyCode\":\"SB.Ccy\",\"payload\":{\"value\":\"GBP\"}}").andExpect(status().isCreated()).andReturn();

        // meanwhile another steward changes C's description through an ordinary request, which is applied
        String other = otherRequestChangingC();

        JsonNode conflicts = json(mvc.perform(get("/api/v1/sandboxes/" + sb + "/conflicts").with(asUser(STEWARD)))
                .andExpect(status().isOk()).andReturn());
        assertThat(conflicts.get("items")).hasSize(1);
        assertThat(conflicts.at("/items/0/seq").asInt()).isEqualTo(1);
        assertThat(conflicts.at("/items/0/field").asText()).isEqualTo("description");
        assertThat(conflicts.at("/items/0/actual").asText()).isEqualTo("changed by another request");
        assertThat(conflicts.at("/items/0/changedByRequest").asText()).isEqualTo(other);

        mvc.perform(post("/api/v1/sandboxes/" + sb + "/submit").with(asUser(STEWARD)).header("If-Match", "\"3\""))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("sandbox.has_conflicts"))
                .andExpect(jsonPath("$.sqlState").value("N2301"))
                .andExpect(jsonPath("$.conflicts[0].seq").value(1));

        mvc.perform(post("/api/v1/sandboxes/" + sb + "/rebase").with(asUser(STEWARD)).header("If-Match", "\"3\""))
                .andExpect(status().isOk())
                .andExpect(header().string("ETag", "\"4\""))
                .andExpect(jsonPath("$.failures[0].seq").value(1))
                .andExpect(jsonPath("$.failures[0].errorCode").value("N3001"))
                .andExpect(jsonPath("$.failures.length()").value(1));
        mvc.perform(get("/api/v1/sandboxes/" + sb + "/conflicts").with(asUser(STEWARD)))
                .andExpect(jsonPath("$.items.length()").value(1))
                .andExpect(jsonPath("$.items[0].changedByRequest").value(org.hamcrest.Matchers.nullValue()));
        JsonNode c = json(mvc.perform(get("/api/v1/sandboxes/" + sb + "/nodes/" + C).with(asUser(STEWARD))).andReturn());
        assertThat(c.get("description").asText()).as("after rebase the overlay shows the other change").isEqualTo("changed by another request");
        assertThat(property(c, "SB.Ccy").get("value").asText()).as("the clean item still shows").isEqualTo("GBP");

        // the owner drops the stale item; the sandbox then submits
        String firstItem = json(mvc.perform(get("/api/v1/sandboxes/" + sb + "/items").with(asUser(STEWARD))).andReturn()).at("/items/0/id").asText();
        mvc.perform(delete("/api/v1/sandboxes/" + sb + "/items/" + firstItem).with(asUser(STEWARD)).header("If-Match", "\"4\""))
                .andExpect(status().isOk()).andExpect(jsonPath("$.failures").isEmpty());
        mvc.perform(post("/api/v1/sandboxes/" + sb + "/submit").with(asUser(STEWARD)).header("If-Match", "\"5\""))
                .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("submitted"));
        assertThat(clean.getResponse().getStatus()).isEqualTo(201);
    }

    // ------------------------------------------------------------------ limits

    @Test
    void anOwnerHasAtMostFiveOpenSandboxes() throws Exception {
        for (int i = 0; i < 5; i++) {
            create(LIMITER, "Limit " + i);
        }
        mvc.perform(post("/api/v1/sandboxes").with(asUser(LIMITER)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"One too many\",\"versionName\":\"SB working\"}"))
                .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.code").value("sandbox.too_many_active"));
    }

    @Test
    void aSandboxCannotGrowPastItsItemLimit() throws Exception {
        String sb = create(STEWARD, "Too big");
        JdbcClient owner = ownerJdbc();
        String old = owner.sql("SELECT setting_value FROM mdm.system_setting WHERE setting_key = 'sandbox_max_items'").query(String.class).single();
        owner.sql("UPDATE mdm.system_setting SET setting_value = '1' WHERE setting_key = 'sandbox_max_items'").update();
        try {
            addItem(STEWARD, sb, 1, move(B1, C)).andExpect(status().isCreated());
            addItem(STEWARD, sb, 2, move(B2, C))
                    .andExpect(status().isUnprocessableEntity())
                    .andExpect(jsonPath("$.sqlState").value("N2302"));
        } finally {
            owner.sql("UPDATE mdm.system_setting SET setting_value = :v WHERE setting_key = 'sandbox_max_items'").param("v", old).update();
        }
    }

    @Test
    void writesNeedIfMatch() throws Exception {
        String sb = create(STEWARD, "Etags");
        mvc.perform(post("/api/v1/sandboxes/" + sb + "/items").with(asUser(STEWARD)).contentType(MediaType.APPLICATION_JSON).content(move(B1, C)))
                .andExpect(status().is(428));
        addItem(STEWARD, sb, 7, move(B1, C)).andExpect(status().isPreconditionFailed());
    }

    // ------------------------------------------------------------------ owner versus viewer (F-1)

    @Test
    void viewersMayReadButOnlyTheOwnerChangesAndOutsidersSeeNothing() throws Exception {
        String sb = create(STEWARD, "Shared view");
        mvc.perform(get("/api/v1/sandboxes/" + sb).with(asUser(VIEWER))).andExpect(status().isNotFound());   // empty: private
        addItem(STEWARD, sb, 1, move(B1, C)).andExpect(status().isCreated());

        mvc.perform(get("/api/v1/sandboxes/" + sb).with(asUser(VIEWER))).andExpect(status().isOk());
        mvc.perform(get("/api/v1/sandboxes/" + sb + "/hierarchies/" + H + "/children?parentId=" + C).with(asUser(VIEWER)))
                .andExpect(status().isOk()).andExpect(jsonPath("$.items[?(@.name == 'SB b1')].changed").value(true));
        mvc.perform(get("/api/v1/sandboxes/" + sb + "/diff").with(asUser(VIEWER))).andExpect(status().isOk());
        addItem(VIEWER, sb, 2, move(B2, C)).andExpect(status().isForbidden());
        mvc.perform(get("/api/v1/sandboxes/" + sb + "/conflicts").with(asUser(VIEWER))).andExpect(status().isForbidden());
        mvc.perform(post("/api/v1/sandboxes/" + sb + "/rebase").with(asUser(VIEWER)).header("If-Match", "\"2\""))
                .andExpect(status().isForbidden());
        mvc.perform(post("/api/v1/sandboxes/" + sb + "/discard").with(asUser(VIEWER)).header("If-Match", "\"2\""))
                .andExpect(status().isForbidden());

        mvc.perform(get("/api/v1/sandboxes/" + sb).with(asUser(OUTSIDER))).andExpect(status().isNotFound());
        mvc.perform(get("/api/v1/sandboxes/" + sb + "/hierarchies/" + H + "/children?parentId=" + C).with(asUser(OUTSIDER)))
                .andExpect(status().isNotFound());
        mvc.perform(post("/api/v1/sandboxes").with(asUser(VIEWER)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"Viewer's own\",\"versionName\":\"SB working\"}"))
                .andExpect(status().isForbidden());
    }

    // ------------------------------------------------------------------ helpers

    private String create(String login, String name) throws Exception {
        MvcResult r = mvc.perform(post("/api/v1/sandboxes").with(asUser(login)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"" + name + "\",\"versionName\":\"SB working\",\"hierarchyCode\":\"" + H + "\"}"))
                .andExpect(status().isCreated())
                .andExpect(header().string("ETag", "\"1\""))
                .andExpect(jsonPath("$.kind").value("sandbox"))
                .andExpect(jsonPath("$.status").value("draft"))
                .andExpect(jsonPath("$.conflictCount").value(0))
                .andReturn();
        return json(r).get("id").asText();
    }

    private ResultActions addItem(String login, String sb, int etag, String body) throws Exception {
        return mvc.perform(post("/api/v1/sandboxes/" + sb + "/items").with(asUser(login)).header("If-Match", "\"" + etag + "\"")
                .contentType(MediaType.APPLICATION_JSON).content(body));
    }

    private static String move(UUID node, UUID parent) {
        return "{\"action\":\"move_node\",\"hierarchyCode\":\"" + H + "\",\"nodeId\":\"" + node + "\",\"targetParentId\":\"" + parent + "\"}";
    }

    private org.springframework.test.web.servlet.RequestBuilder children(String sb, UUID parent) {
        return get("/api/v1/sandboxes/" + sb + "/hierarchies/" + H + "/children?parentId=" + parent).with(asUser(STEWARD));
    }

    /** Another steward changes C's description through an ordinary request, decided and applied. Returns its id. */
    private String otherRequestChangingC() throws Exception {
        String cr = json(mvc.perform(post("/api/v1/change-requests").with(asUser(OTHER)).contentType(MediaType.APPLICATION_JSON)
                .content("{\"versionName\":\"SB working\",\"title\":\"Describe C\"}")).andReturn()).get("id").asText();
        mvc.perform(post("/api/v1/change-requests/" + cr + "/items").with(asUser(OTHER)).header("If-Match", "\"1\"")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"action\":\"update_node\",\"hierarchyCode\":\"" + H
                                + "\",\"nodeId\":\"" + C + "\",\"payload\":{\"description\":\"changed by another request\"}}"))
                .andExpect(status().isCreated());
        mvc.perform(post("/api/v1/change-requests/" + cr + "/submit").with(asUser(OTHER)).header("If-Match", "\"2\""))
                .andExpect(status().isOk());
        String etag = mvc.perform(get("/api/v1/change-requests/" + cr).with(asUser(APPROVER))).andReturn().getResponse().getHeader("ETag");
        mvc.perform(post("/api/v1/change-requests/" + cr + "/decision").with(asUser(APPROVER)).header("If-Match", etag)
                        .contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"approve\"}"))
                .andExpect(jsonPath("$.status").value("applied"));
        return cr;
    }

    /** The overlay's children of each parent, as comparable rows. */
    private List<String> tree(String sb, List<UUID> parents) throws Exception {
        List<String> rows = new ArrayList<>();
        for (UUID p : parents) {
            for (JsonNode c : json(mvc.perform(children(sb, p)).andExpect(status().isOk()).andReturn()).get("items")) {
                rows.add(row(p, c));
            }
        }
        return rows;
    }

    /** The applied tree, read the Phase 1 way, as the same rows. */
    private List<String> liveTree(List<UUID> parents) throws Exception {
        List<String> rows = new ArrayList<>();
        for (UUID p : parents) {
            for (JsonNode c : json(mvc.perform(get("/api/v1/hierarchies/" + H + "/children?parentId=" + p).with(asUser(STEWARD)))
                    .andExpect(status().isOk()).andReturn()).get("items")) {
                rows.add(row(p, c));
            }
        }
        return rows;
    }

    private static String row(UUID parent, JsonNode c) {
        return String.join("|", parent.toString(), c.get("nodeId").asText(), c.get("name").asText(), c.get("description").asText(),
                c.get("active").asText(), c.get("primary").asText(), c.get("sortOrder").decimalValue().stripTrailingZeros().toPlainString(),
                c.get("hasChildren").asText());
    }

    private static List<String> names(JsonNode page) {
        List<String> names = new ArrayList<>();
        page.get("items").forEach(i -> names.add(i.get("name").asText()));
        return names;
    }

    private static JsonNode property(JsonNode node, String code) {
        for (JsonNode p : node.get("properties")) {
            if (p.get("code").asText().equals(code)) {
                return p;
            }
        }
        throw new AssertionError("no property " + code);
    }

    /** A fingerprint of the fact tables this test touches: any row inserted or closed changes it. */
    private static String facts() {
        return ownerJdbc().sql("""
                SELECT md5(string_agg(x, '|' ORDER BY x)) FROM (
                            SELECT 'r ' || t::text FROM mdm.hierarchy_relationship t
                  UNION ALL SELECT 'a ' || t::text FROM mdm.node_attr t
                  UNION ALL SELECT 'v ' || t::text FROM mdm.property_value t) s(x)
                """).query(String.class).single();
    }

    private JsonNode json(MvcResult r) throws Exception {
        return mapper.readTree(r.getResponse().getContentAsString());
    }
}
