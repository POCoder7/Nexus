package com.mdm.api.security;

import com.mdm.api.PostgresIntegrationTest;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.web.servlet.MockMvc;

import java.util.UUID;

import static org.hamcrest.Matchers.hasItem;
import static org.hamcrest.Matchers.not;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** SEC-01 / SEC-02 at the API: an actor is required, and reads are limited to hierarchies the actor may read. */
class EntitlementApiTest extends PostgresIntegrationTest {

    static final UUID TOP_A = UUID.fromString("00000000-0000-0000-0000-00000000e0a1");
    static final UUID TOP_B = UUID.fromString("00000000-0000-0000-0000-00000000e0b1");

    @Autowired
    MockMvc mvc;

    @BeforeEach
    void seed() {
        JdbcClient jdbc = ownerJdbc();
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'ENT_A'").query(Integer.class).single() == 0) {
            jdbc.sql("INSERT INTO mdm.node (node_id, node_kind) VALUES (:a, 'structural'), (:b, 'structural')")
                    .param("a", TOP_A).param("b", TOP_B).update();
            jdbc.sql("INSERT INTO mdm.node_attr (node_id, node_name) VALUES (:a, 'Ent A top'), (:b, 'Ent B top')")
                    .param("a", TOP_A).param("b", TOP_B).update();
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, top_node_id)
                    VALUES ('ENT_A', 'Entitlement A', :a), ('ENT_B', 'Entitlement B', :b)
                    """).param("a", TOP_A).param("b", TOP_B).update();
        }
        grant("e_viewer_all", "VIEWER", null, null);
        grant("e_viewer_b", "VIEWER", "ENT_B", null);
        ensureUser("e_no_roles", "human");
        ensureUser("e_inactive", "human");
        jdbc.sql("UPDATE mdm.app_user SET is_active = false WHERE login = 'e_inactive'").update();
    }

    @Test
    void requestsWithoutAnActorAreUnauthenticated() throws Exception {
        mvc.perform(get("/api/v1/hierarchies"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.type").value("urn:nexus:problem:unauthenticated"));
    }

    @Test
    void unknownAndInactiveUsersAreUnauthenticated() throws Exception {
        mvc.perform(get("/api/v1/hierarchies").with(asUser("nobody_here"))).andExpect(status().isUnauthorized());
        mvc.perform(get("/api/v1/hierarchies").with(asUser("e_inactive"))).andExpect(status().isUnauthorized());
    }

    @Test
    void aGlobalViewerSeesEveryHierarchy() throws Exception {
        mvc.perform(get("/api/v1/hierarchies").with(asUser("e_viewer_all")))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items[*].code").value(hasItem("ENT_A")))
                .andExpect(jsonPath("$.items[*].code").value(hasItem("ENT_B")));
    }

    @Test
    void aScopedViewerSeesOnlyTheirHierarchy() throws Exception {
        mvc.perform(get("/api/v1/hierarchies").with(asUser("e_viewer_b")))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items[*].code").value(hasItem("ENT_B")))
                .andExpect(jsonPath("$.items[*].code").value(not(hasItem("ENT_A"))));
        mvc.perform(get("/api/v1/hierarchies/ENT_A").with(asUser("e_viewer_b")))
                .andExpect(status().isNotFound());
        mvc.perform(get("/api/v1/hierarchies/ENT_A/children").param("parentId", TOP_A.toString()).with(asUser("e_viewer_b")))
                .andExpect(status().isNotFound());
        mvc.perform(get("/api/v1/nodes/" + TOP_A).with(asUser("e_viewer_b")))
                .andExpect(status().isNotFound());
        mvc.perform(get("/api/v1/nodes/" + TOP_B).with(asUser("e_viewer_b")))
                .andExpect(status().isOk());
    }

    @Test
    void aUserWithoutRolesSeesNothing() throws Exception {
        mvc.perform(get("/api/v1/hierarchies").with(asUser("e_no_roles")))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items.length()").value(0));
    }

    @Test
    void unknownHierarchyOnNodeDetailIsNotFound() throws Exception {
        mvc.perform(get("/api/v1/nodes/" + TOP_A).param("hierarchy", "NO_SUCH").with(asUser("e_viewer_all")))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.detail").value("Hierarchy NO_SUCH not found"));
    }

    @Test
    void meShowsActorGrantsAndBusinessDay() throws Exception {
        mvc.perform(get("/api/v1/me").with(asUser("e_viewer_b")))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.actor.login").value("e_viewer_b"))
                .andExpect(jsonPath("$.businessTimeZone").value("America/New_York"))
                .andExpect(jsonPath("$.businessToday").isNotEmpty())
                .andExpect(jsonPath("$.grants[0].roleCode").value("VIEWER"))
                .andExpect(jsonPath("$.grants[0].hierarchyCode").value("ENT_B"));
    }
}
