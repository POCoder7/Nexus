package com.mdm.api;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.web.servlet.MockMvc;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.util.UUID;

import static org.hamcrest.Matchers.hasItem;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Runs the real Flyway migrations (V1–V6) against PostgreSQL in a container,
 * then exercises the read API. Requires a running container runtime.
 */
@SpringBootTest
@AutoConfigureMockMvc
@Testcontainers
class HierarchyApiTest {

    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine");

    static final UUID TOP = UUID.fromString("00000000-0000-0000-0000-000000000101");
    static final UUID CHILD_A = UUID.fromString("00000000-0000-0000-0000-000000000102");
    static final UUID CHILD_B = UUID.fromString("00000000-0000-0000-0000-000000000103");
    static final UUID GRANDCHILD = UUID.fromString("00000000-0000-0000-0000-000000000104");

    @Autowired
    MockMvc mvc;

    @Autowired
    JdbcClient jdbc;

    @BeforeEach
    void seed() {
        Integer exists = jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'TEST'")
                .query(Integer.class).single();
        if (exists > 0) {
            return;
        }
        jdbc.sql("""
                INSERT INTO mdm.node (node_id, node_kind) VALUES
                  (:top, 'structural'), (:a, 'legal_entity'), (:b, 'legal_entity'), (:g, 'legal_entity')
                """).param("top", TOP).param("a", CHILD_A).param("b", CHILD_B).param("g", GRANDCHILD).update();
        jdbc.sql("""
                INSERT INTO mdm.node_attr (node_id, node_name, description) VALUES
                  (:top, 'Top', 'Top node'), (:a, 'Child A', 'First child'),
                  (:b, 'Child B', 'Second child'), (:g, 'Grandchild', 'Under A')
                """).param("top", TOP).param("a", CHILD_A).param("b", CHILD_B).param("g", GRANDCHILD).update();
        jdbc.sql("""
                INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, purpose, top_node_id)
                VALUES ('TEST', 'Test hierarchy', 'legal_consolidation', :top)
                """).param("top", TOP).update();
        jdbc.sql("""
                INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, sort_order)
                SELECT h.hierarchy_id, v.parent, v.child, v.sort
                FROM mdm.hierarchy h,
                     (VALUES (CAST(:top AS uuid), CAST(:b AS uuid), 2),
                             (CAST(:top AS uuid), CAST(:a AS uuid), 1),
                             (CAST(:a AS uuid),   CAST(:g AS uuid), 1)) AS v(parent, child, sort)
                WHERE h.hierarchy_code = 'TEST'
                """).param("top", TOP).param("a", CHILD_A).param("b", CHILD_B).param("g", GRANDCHILD).update();
    }

    @Test
    void listsHierarchiesWithTopNode() throws Exception {
        mvc.perform(get("/api/v1/hierarchies"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[?(@.code == 'TEST')].topNodeName").value(hasItem("Top")));
    }

    @Test
    void returnsChildrenInSortOrderWithChildFlags() throws Exception {
        mvc.perform(get("/api/v1/hierarchies/TEST/children").param("parentId", TOP.toString()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.length()").value(2))
                .andExpect(jsonPath("$[0].name").value("Child A"))
                .andExpect(jsonPath("$[0].hasChildren").value(true))
                .andExpect(jsonPath("$[1].name").value("Child B"))
                .andExpect(jsonPath("$[1].hasChildren").value(false));
    }

    @Test
    void pagesChildren() throws Exception {
        mvc.perform(get("/api/v1/hierarchies/TEST/children")
                        .param("parentId", TOP.toString()).param("limit", "1").param("offset", "1"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.length()").value(1))
                .andExpect(jsonPath("$[0].name").value("Child B"));
    }

    @Test
    void rejectsOversizedPages() throws Exception {
        mvc.perform(get("/api/v1/hierarchies/TEST/children")
                        .param("parentId", TOP.toString()).param("limit", "100000"))
                .andExpect(status().isBadRequest());
    }

    @Test
    void returnsNodeDetail() throws Exception {
        mvc.perform(get("/api/v1/nodes/" + CHILD_A).param("hierarchy", "TEST"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.name").value("Child A"))
                .andExpect(jsonPath("$.kind").value("legal_entity"));
    }

    @Test
    void unknownNodeIs404() throws Exception {
        mvc.perform(get("/api/v1/nodes/" + UUID.randomUUID()))
                .andExpect(status().isNotFound());
    }
}
