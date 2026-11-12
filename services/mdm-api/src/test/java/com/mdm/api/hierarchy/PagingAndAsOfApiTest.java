package com.mdm.api.hierarchy;

import com.jayway.jsonpath.JsonPath;
import com.mdm.api.PostgresIntegrationTest;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.web.servlet.MockMvc;

import java.time.Instant;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * ADR-015 keyset paging and NEW-01 bitemporal reads.
 * PAGE_H: top P0 with children E, C, A, D, B (all sort order 1000, so name breaks the tie), plus FUTURE, placed from
 * 10 days ahead. Node RENAMED was recorded as "Old name" and later corrected to "New name".
 */
class PagingAndAsOfApiTest extends PostgresIntegrationTest {

    static final UUID P0 = id("00");
    static final UUID FUTURE = id("f0");
    static final UUID RENAMED = id("e0");
    static final String USER = "p_viewer";
    static Instant beforeCorrection;

    @Autowired
    MockMvc mvc;

    private static UUID id(String s) {
        return UUID.fromString("00000000-0000-0000-0000-0000000ab0" + s);   // s: two hex digits
    }

    @BeforeEach
    void seed() {
        JdbcClient jdbc = ownerJdbc();
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'PAGE_H'").query(Integer.class).single() == 0) {
            node(jdbc, P0, "Page top", LocalDate.now().minusDays(30));
            jdbc.sql("INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, top_node_id, sort_seq) VALUES ('PAGE_H', 'Paging', :t, 1)")
                    .param("t", P0).update();
            String[] names = {"E", "C", "A", "D", "B"};
            for (int i = 0; i < names.length; i++) {
                UUID child = id("c" + i);
                node(jdbc, child, names[i], LocalDate.now().minusDays(30));
                place(jdbc, child, LocalDate.now().minusDays(30));
            }
            node(jdbc, FUTURE, "Z future", LocalDate.now().minusDays(30));
            place(jdbc, FUTURE, LocalDate.now().plusDays(10));

            node(jdbc, RENAMED, "Old name", LocalDate.now().minusDays(30));
            place(jdbc, RENAMED, LocalDate.now().minusDays(30));
            beforeCorrection = jdbc.sql("SELECT clock_timestamp()").query(Instant.class).single();
            // A correction (bitemporal): close the old belief and record the new one for the same business period.
            jdbc.sql("UPDATE mdm.node_attr SET recorded_period = tstzrange(lower(recorded_period), clock_timestamp()) "
                    + "WHERE node_id = :n AND upper_inf(recorded_period)").param("n", RENAMED).update();
            jdbc.sql("INSERT INTO mdm.node_attr (node_id, node_name, valid_period) VALUES (:n, 'New name', daterange(current_date - 30, NULL))")
                    .param("n", RENAMED).update();
        }
        grant(USER, "VIEWER", null, null);
    }

    private static void node(JdbcClient jdbc, UUID id, String name, LocalDate from) {
        jdbc.sql("INSERT INTO mdm.node (node_id, node_kind) VALUES (:n, 'structural')").param("n", id).update();
        jdbc.sql("INSERT INTO mdm.node_attr (node_id, node_name, valid_period) VALUES (:n, :name, daterange(CAST(:from AS date), NULL))")
                .param("n", id).param("name", name).param("from", from).update();
    }

    private static void place(JdbcClient jdbc, UUID child, LocalDate from) {
        jdbc.sql("""
                INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, sort_order, valid_period)
                SELECT hierarchy_id, :p, :c, 1000, daterange(CAST(:from AS date), NULL) FROM mdm.hierarchy WHERE hierarchy_code = 'PAGE_H'
                """).param("p", P0).param("c", child).param("from", from).update();
    }

    private List<String> childNames(String extraParam, String value) throws Exception {
        List<String> names = new ArrayList<>();
        String cursor = null;
        do {
            var req = get("/api/v1/hierarchies/PAGE_H/children").param("parentId", P0.toString()).param("limit", "2");
            if (cursor != null) {
                req = req.param("cursor", cursor);
            }
            if (extraParam != null) {
                req = req.param(extraParam, value);
            }
            String body = mvc.perform(req.with(asUser(USER))).andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
            names.addAll(JsonPath.read(body, "$.items[*].name"));
            cursor = JsonPath.read(body, "$.nextCursor");
        } while (cursor != null);
        return names;
    }

    @Test
    void childrenPageInNameOrderWhenSortOrdersTie() throws Exception {
        assertThat(childNames(null, null)).containsExactly("A", "B", "C", "D", "E", "New name");
    }

    @Test
    void aMalformedCursorIsABadRequest() throws Exception {
        mvc.perform(get("/api/v1/hierarchies/PAGE_H/children").param("parentId", P0.toString()).param("cursor", "not-a-cursor")
                        .with(asUser(USER)))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.type").value("urn:nexus:problem:invalid-request"));
    }

    @Test
    void theHierarchyListPagesWithoutRepeats() throws Exception {
        List<String> codes = new ArrayList<>();
        String cursor = null;
        do {
            var req = get("/api/v1/hierarchies").param("limit", "1");
            if (cursor != null) {
                req = req.param("cursor", cursor);
            }
            String body = mvc.perform(req.with(asUser(USER))).andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
            codes.addAll(JsonPath.read(body, "$.items[*].code"));
            cursor = JsonPath.read(body, "$.nextCursor");
        } while (cursor != null);
        assertThat(codes).contains("PAGE_H").doesNotHaveDuplicates();
    }

    @Test
    void aFutureDatedPlacementIsVisibleOnlyFromItsDate() throws Exception {
        assertThat(childNames(null, null)).doesNotContain("Z future");
        assertThat(childNames("asOf", LocalDate.now().plusDays(11).toString())).contains("Z future");
    }

    @Test
    void readsAtAnEarlierRecordedTimeShowWhatWasBelievedThen() throws Exception {
        assertThat(childNames(null, null)).contains("New name").doesNotContain("Old name");
        assertThat(childNames("recordedAsOf", beforeCorrection.toString())).contains("Old name").doesNotContain("New name");
        mvc.perform(get("/api/v1/nodes/" + RENAMED).param("recordedAsOf", beforeCorrection.toString()).with(asUser(USER)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.name").value("Old name"));
        mvc.perform(get("/api/v1/nodes/" + RENAMED).with(asUser(USER)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.name").value("New name"));
    }
}
