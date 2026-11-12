package com.mdm.api;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.web.servlet.MockMvc;

import java.util.UUID;

import static org.hamcrest.Matchers.hasItem;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Runs the real Flyway migrations against PostgreSQL in a container, then exercises the read API with the
 * application's least-privilege login (see {@link PostgresIntegrationTest}). Requires a running container runtime.
 * Requests are made as a synthetic viewer of TEST (Phase 1: every request needs an actor and READ on the hierarchy).
 */
class HierarchyApiTest extends PostgresIntegrationTest {

    static final UUID TOP = UUID.fromString("00000000-0000-0000-0000-000000000101");
    static final UUID CHILD_A = UUID.fromString("00000000-0000-0000-0000-000000000102");
    static final UUID CHILD_B = UUID.fromString("00000000-0000-0000-0000-000000000103");
    static final UUID GRANDCHILD = UUID.fromString("00000000-0000-0000-0000-000000000104");

    static final String VIEWER = "t_viewer";

    @Autowired
    MockMvc mvc;

    @BeforeEach
    void seed() {
        // Seeding writes facts directly, which the API login may not do (ADR-014): use the owner connection.
        JdbcClient jdbc = ownerJdbc();
        Integer exists = jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'TEST'")
                .query(Integer.class).single();
        if (exists > 0) {
            grant(VIEWER, "VIEWER", "TEST", null);
            return;
        }
        jdbc.sql("""
                INSERT INTO mdm.node (node_id, node_kind) VALUES
                  (:top, 'structural'), (:a, 'legal_entity'), (:b, 'legal_entity'), (:g, 'legal_entity')
                """).param("top", TOP).param("a", CHILD_A).param("b", CHILD_B).param("g", GRANDCHILD).update();
        jdbc.sql("""
                INSERT INTO mdm.node_attr (node_id, node_name, description, valid_period)
                SELECT v.id, v.name, v.descr, daterange(mdm.business_today(), NULL)
                FROM (VALUES (CAST(:top AS uuid), 'Top', 'Top node'), (CAST(:a AS uuid), 'Child A', 'First child'),
                             (CAST(:b AS uuid), 'Child B', 'Second child'), (CAST(:g AS uuid), 'Grandchild', 'Under A'))
                     AS v(id, name, descr)
                """).param("top", TOP).param("a", CHILD_A).param("b", CHILD_B).param("g", GRANDCHILD).update();
        jdbc.sql("""
                INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, purpose, top_node_id)
                VALUES ('TEST', 'Test hierarchy', 'legal_consolidation', :top)
                """).param("top", TOP).update();
        jdbc.sql("""
                INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, sort_order, valid_period)
                SELECT h.hierarchy_id, v.parent, v.child, v.sort, daterange(mdm.business_today(), NULL)
                FROM mdm.hierarchy h,
                     (VALUES (CAST(:top AS uuid), CAST(:b AS uuid), 2),
                             (CAST(:top AS uuid), CAST(:a AS uuid), 1),
                             (CAST(:a AS uuid),   CAST(:g AS uuid), 1)) AS v(parent, child, sort)
                WHERE h.hierarchy_code = 'TEST'
                """).param("top", TOP).param("a", CHILD_A).param("b", CHILD_B).param("g", GRANDCHILD).update();
        grant(VIEWER, "VIEWER", "TEST", null);
    }

    @Test
    void listsHierarchiesWithTopNode() throws Exception {
        mvc.perform(get("/api/v1/hierarchies").with(asUser(VIEWER)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items[?(@.code == 'TEST')].topNodeName").value(hasItem("Top")));
    }

    @Test
    void returnsChildrenInSortOrderWithChildFlags() throws Exception {
        mvc.perform(get("/api/v1/hierarchies/TEST/children").param("parentId", TOP.toString()).with(asUser(VIEWER)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items.length()").value(2))
                .andExpect(jsonPath("$.items[0].name").value("Child A"))
                .andExpect(jsonPath("$.items[0].hasChildren").value(true))
                .andExpect(jsonPath("$.items[1].name").value("Child B"))
                .andExpect(jsonPath("$.items[1].hasChildren").value(false));
    }

    @Test
    void pagesChildren() throws Exception {
        // ADR-015: keyset cursor instead of offset. Same assertion as before: the second page of size 1 is Child B.
        String body = mvc.perform(get("/api/v1/hierarchies/TEST/children")
                        .param("parentId", TOP.toString()).param("limit", "1").with(asUser(VIEWER)))
                .andExpect(status().isOk())
                .andReturn().getResponse().getContentAsString();
        String cursor = com.jayway.jsonpath.JsonPath.read(body, "$.nextCursor");
        mvc.perform(get("/api/v1/hierarchies/TEST/children")
                        .param("parentId", TOP.toString()).param("limit", "1").param("cursor", cursor).with(asUser(VIEWER)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items.length()").value(1))
                .andExpect(jsonPath("$.items[0].name").value("Child B"));
    }

    @Test
    void rejectsOversizedPages() throws Exception {
        mvc.perform(get("/api/v1/hierarchies/TEST/children")
                        .param("parentId", TOP.toString()).param("limit", "100000").with(asUser(VIEWER)))
                .andExpect(status().isBadRequest());
    }

    @Test
    void returnsNodeDetail() throws Exception {
        mvc.perform(get("/api/v1/nodes/" + CHILD_A).param("hierarchy", "TEST").with(asUser(VIEWER)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.name").value("Child A"))
                .andExpect(jsonPath("$.kind").value("legal_entity"));
    }

    @Test
    void unknownNodeIs404() throws Exception {
        mvc.perform(get("/api/v1/nodes/" + UUID.randomUUID()).with(asUser(VIEWER)))
                .andExpect(status().isNotFound());
    }
}
