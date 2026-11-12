package com.mdm.api.node;

import com.mdm.api.PostgresIntegrationTest;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.web.servlet.MockMvc;

import java.util.UUID;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** PRP-01 reads: node detail shows each property's value and where it comes from (S1-R3, D-18). */
class NodePropertiesApiTest extends PostgresIntegrationTest {

    static final UUID TOP = UUID.fromString("00000000-0000-0000-0000-0000000ad001");
    static final UUID CHILD = UUID.fromString("00000000-0000-0000-0000-0000000ad002");
    static final String USER = "n_viewer";

    @Autowired
    MockMvc mvc;

    @BeforeEach
    void seed() {
        JdbcClient jdbc = ownerJdbc();
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'PROP_H'").query(Integer.class).single() == 0) {
            jdbc.sql("INSERT INTO mdm.node (node_id, node_kind) VALUES (:t, 'structural'), (:c, 'legal_entity')")
                    .param("t", TOP).param("c", CHILD).update();
            // Valid from the business day (ADR-018), not the UTC session date the column default uses.
            jdbc.sql("""
                    INSERT INTO mdm.node_attr (node_id, node_name, valid_period)
                    VALUES (:t, 'Prop top', daterange(mdm.business_today(), NULL)),
                           (:c, 'Prop child', daterange(mdm.business_today(), NULL))
                    """)
                    .param("t", TOP).param("c", CHILD).update();
            jdbc.sql("INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, top_node_id) VALUES ('PROP_H', 'Properties', :t)")
                    .param("t", TOP).update();
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, valid_period)
                    SELECT hierarchy_id, :t, :c, daterange(mdm.business_today(), NULL) FROM mdm.hierarchy WHERE hierarchy_code = 'PROP_H'
                    """).param("t", TOP).param("c", CHILD).update();
            jdbc.sql("""
                    INSERT INTO mdm.property_definition (property_code, label, category_code, data_type, scope, inheritance, default_value)
                    VALUES ('NT.Ccy', 'Reporting currency', 'Finance', 'string', 'global', 'inherit_from_ancestor', NULL),
                           ('NT.Seg', 'Segment', 'Finance', 'string', 'global', 'none', '"Unassigned"')
                    """).update();
            jdbc.sql("""
                    INSERT INTO mdm.property_value (node_id, property_id, value, valid_period)
                    SELECT :t, property_id, '"EUR"', daterange(mdm.business_today(), NULL)
                    FROM mdm.property_definition WHERE property_code = 'NT.Ccy'
                    """).param("t", TOP).update();
        }
        grant(USER, "VIEWER", "PROP_H", null);
    }

    @Test
    void childShowsInheritedValueWithItsSourceAndDefaults() throws Exception {
        mvc.perform(get("/api/v1/nodes/" + CHILD).param("hierarchy", "PROP_H").with(asUser(USER)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.properties[?(@.code == 'NT.Ccy')].value").value("EUR"))
                .andExpect(jsonPath("$.properties[?(@.code == 'NT.Ccy')].provenance").value("inherited"))
                .andExpect(jsonPath("$.properties[?(@.code == 'NT.Ccy')].sourceNodeId").value(TOP.toString()))
                .andExpect(jsonPath("$.properties[?(@.code == 'NT.Seg')].provenance").value("default"))
                .andExpect(jsonPath("$.properties[?(@.code == 'NT.Seg')].value").value("Unassigned"));
    }

    @Test
    void topShowsItsOwnStoredValue() throws Exception {
        mvc.perform(get("/api/v1/nodes/" + TOP).param("hierarchy", "PROP_H").with(asUser(USER)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.properties[?(@.code == 'NT.Ccy')].provenance").value("stored"));
    }
}
