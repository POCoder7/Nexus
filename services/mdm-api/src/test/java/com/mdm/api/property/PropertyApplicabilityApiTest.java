package com.mdm.api.property;

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
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.containsString;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Property applicability (ADR-046 D2, Phase 4 LLD §17.3): a property lists the hierarchies it applies to and the kind of
 * node; the definitions API shows both, the property grid offers only applicable properties, and a value where the
 * property does not apply is refused on validation (N2025).
 */
class PropertyApplicabilityApiTest extends PostgresIntegrationTest {

    static final UUID TOP = UUID.fromString("00000000-0000-0000-0000-0000000a9901");
    static final UUID LEAF = UUID.fromString("00000000-0000-0000-0000-0000000a9902");
    static final UUID TOP2 = UUID.fromString("00000000-0000-0000-0000-0000000a9903");
    static final String EDITOR = "pa_editor";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    @BeforeEach
    void seed() {
        JdbcClient jdbc = ownerJdbc();
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'PA_H'").query(Integer.class).single() == 0) {
            jdbc.sql("INSERT INTO mdm.version (version_name, business_as_of) VALUES ('PA working', current_date)").update();
            jdbc.sql("INSERT INTO mdm.node (node_id, node_kind) VALUES (:t, 'structural'), (:l, 'structural'), (:t2, 'structural')")
                    .param("t", TOP).param("l", LEAF).param("t2", TOP2).update();
            jdbc.sql("""
                    INSERT INTO mdm.node_attr (node_id, node_name, allows_children, valid_period) VALUES
                      (:t, 'PA top', true, daterange('2020-01-01', NULL)), (:l, 'PA leaf', false, daterange('2020-01-01', NULL)),
                      (:t2, 'PA top two', true, daterange('2020-01-01', NULL))
                    """).param("t", TOP).param("l", LEAF).param("t2", TOP2).update();
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, purpose, top_node_id) VALUES
                      ('PA_H', 'Applicability', 'management', :t), ('PA_H2', 'Applicability two', 'management', :t2)
                    """).param("t", TOP).param("t2", TOP2).update();
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, is_primary, valid_period)
                    SELECT hierarchy_id, :t, :l, true, daterange('2020-01-01', NULL) FROM mdm.hierarchy WHERE hierarchy_code = 'PA_H'
                    """).param("t", TOP).param("l", LEAF).update();
            jdbc.sql("""
                    INSERT INTO mdm.property_definition (property_code, label, data_type, scope, node_filter) VALUES
                      ('PA.LeafOnly', 'Leaf only', 'string', 'global', 'leaf'),
                      ('PA.OnlyTwo', 'Only in PA_H2', 'string', 'global', 'any'),
                      ('PA.Anywhere', 'Anywhere', 'string', 'global', 'any')
                    """).update();
            jdbc.sql("""
                    INSERT INTO mdm.property_hierarchy (property_id, hierarchy_id)
                    SELECT pd.property_id, h.hierarchy_id FROM mdm.property_definition pd, mdm.hierarchy h
                    WHERE pd.property_code = 'PA.OnlyTwo' AND h.hierarchy_code = 'PA_H2'
                    """).update();
        }
        grant(EDITOR, "EDITOR", "PA_H", null);
    }

    @Test
    void theDefinitionsShowWhereEachPropertyApplies() throws Exception {
        JsonNode items = json(mvc.perform(get("/api/v1/property-definitions").with(asUser(EDITOR)))
                .andExpect(status().isOk()).andReturn()).get("items");
        JsonNode leafOnly = find(items, "PA.LeafOnly");
        JsonNode onlyTwo = find(items, "PA.OnlyTwo");
        assertThat(leafOnly.get("nodeFilter").asText()).isEqualTo("leaf");
        assertThat(leafOnly.get("appliesTo")).isEmpty();
        assertThat(onlyTwo.get("nodeFilter").asText()).isEqualTo("any");
        assertThat(onlyTwo.get("appliesTo").get(0).asText()).isEqualTo("PA_H2");
    }

    @Test
    void thePropertyGridOffersOnlyApplicableProperties() throws Exception {
        assertThat(codes(LEAF)).contains("PA.LeafOnly", "PA.Anywhere").doesNotContain("PA.OnlyTwo");
        assertThat(codes(TOP)).contains("PA.Anywhere").doesNotContain("PA.LeafOnly", "PA.OnlyTwo");
    }

    @Test
    void aValueWhereThePropertyDoesNotApplyFailsValidation() throws Exception {
        MvcResult r = mvc.perform(post("/api/v1/change-requests").with(asUser(EDITOR)).contentType(MediaType.APPLICATION_JSON)
                .content("{\"versionName\":\"PA working\",\"title\":\"PA leaf-only on the top\"}")).andExpect(status().isCreated()).andReturn();
        String id = json(r).get("id").asText();
        mvc.perform(post("/api/v1/change-requests/" + id + "/items").with(asUser(EDITOR)).header("If-Match", "\"1\"")
                .contentType(MediaType.APPLICATION_JSON).content("{\"action\":\"set_property\",\"hierarchyCode\":\"PA_H\",\"nodeId\":\""
                        + TOP + "\",\"propertyCode\":\"PA.LeafOnly\",\"payload\":{\"value\":\"x\"}}"))
                .andExpect(status().isCreated());
        mvc.perform(post("/api/v1/change-requests/" + id + "/submit").with(asUser(EDITOR)).header("If-Match", "\"2\""))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("change_request.validation_failed"))
                .andExpect(jsonPath("$.errors[0].message").value(containsString("N2025")));
    }

    private List<String> codes(UUID node) throws Exception {
        List<String> codes = new ArrayList<>();
        json(mvc.perform(get("/api/v1/nodes/" + node).param("hierarchy", "PA_H").with(asUser(EDITOR)))
                .andExpect(status().isOk()).andReturn()).get("properties").forEach(p -> codes.add(p.get("code").asText()));
        return codes;
    }

    private static JsonNode find(JsonNode items, String code) {
        for (JsonNode n : items) {
            if (code.equals(n.get("code").asText())) {
                return n;
            }
        }
        throw new AssertionError("no definition " + code);
    }

    private JsonNode json(MvcResult r) throws Exception {
        return mapper.readTree(r.getResponse().getContentAsString());
    }
}
