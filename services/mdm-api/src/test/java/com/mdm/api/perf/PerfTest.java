package com.mdm.api.perf;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.PostgresIntegrationTest;
import com.mdm.api.apply.ApplyService;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.Callable;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Phase 1 performance targets (LLD §10; defaults from OPEN_DECISIONS, OD-10) on the synthetic {@code PERF_H} hierarchy.
 * Tagged {@code perf}: excluded from the default build, run with {@code ./mvnw -B verify -Dperf}. Results are written to
 * {@code target/perf-results.md} for the phase test report. Measured through the API (MockMvc), so the numbers include
 * request handling, entitlement checks and JSON, not only SQL.
 */
@Tag("perf")
class PerfTest extends PostgresIntegrationTest {

    static final int RUNS = 30;
    static final long P95_CHILDREN_PAGE_MS = 300;
    static final long P95_NODE_DETAIL_MS = 500;
    static final long P95_SUBMIT_MS = 2_000;
    static final long P95_APPLY_MS = 2_000;
    static final String STEWARD = "perf_steward";
    static final String APPROVER = "perf_approver";
    static final List<String> RESULTS = Collections.synchronizedList(new ArrayList<>());

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;
    @Autowired
    ApplyService applyService;

    SyntheticHierarchy.Built data;

    @BeforeEach
    void seed() {
        long t = System.nanoTime();
        data = SyntheticHierarchy.build(ownerJdbc(), SyntheticHierarchy.Shape.phase1());
        long ms = (System.nanoTime() - t) / 1_000_000;
        if (ms > 1_000) {
            RESULTS.add("| Generator: PERF_H (~100 600 nodes, 200 properties) | " + ms + " ms | — | one-off |");
        }
        ownerJdbc().sql("INSERT INTO mdm.version (version_name, business_as_of) VALUES ('PERF working', current_date) "
                + "ON CONFLICT (version_name) DO NOTHING").update();
        grant(STEWARD, "STEWARD", SyntheticHierarchy.CODE, null);
        grant(APPROVER, "APPROVER", SyntheticHierarchy.CODE, null);
    }

    @AfterAll
    static void writeResults() throws IOException {
        List<String> lines = new ArrayList<>(List.of("| Case | p95 | Target | Runs |", "|---|---|---|---|"));
        lines.addAll(RESULTS);
        Files.write(Path.of("target", "perf-results.md"), lines);
    }

    @Test
    void childrenPageAt50000Siblings() throws Exception {
        String firstPage = "/api/v1/hierarchies/" + SyntheticHierarchy.CODE + "/children?limit=200&parentId=" + data.wideParent();
        JsonNode page = json(mvc.perform(get(firstPage).with(asUser(STEWARD))).andExpect(status().isOk()).andReturn());
        for (int i = 0; i < 100; i++) {                         // a cursor deep into the list (page ~100 of 250)
            page = json(mvc.perform(get(firstPage + "&cursor=" + page.get("nextCursor").asText()).with(asUser(STEWARD)))
                    .andReturn());
        }
        String deepPage = firstPage + "&cursor=" + page.get("nextCursor").asText();
        long first = p95(() -> mvc.perform(get(firstPage).with(asUser(STEWARD))).andExpect(status().isOk()));
        long deep = p95(() -> mvc.perform(get(deepPage).with(asUser(STEWARD))).andExpect(status().isOk()));
        record("Children page, first of 50 000 siblings (limit 200)", first, P95_CHILDREN_PAGE_MS, RUNS);
        record("Children page, page ~100 of 50 000 siblings (keyset)", deep, P95_CHILDREN_PAGE_MS, RUNS);
        assertThat(first).isLessThanOrEqualTo(P95_CHILDREN_PAGE_MS);
        assertThat(deep).isLessThanOrEqualTo(P95_CHILDREN_PAGE_MS);
    }

    @Test
    void nodeDetailWith200InheritedPropertiesAtDepth20() throws Exception {
        String url = "/api/v1/nodes/" + data.deepest() + "?hierarchy=" + SyntheticHierarchy.CODE;
        JsonNode detail = json(mvc.perform(get(url).with(asUser(STEWARD))).andExpect(status().isOk()).andReturn());
        assertThat(detail.get("properties").size()).isGreaterThanOrEqualTo(200);
        long p95 = p95(() -> mvc.perform(get(url).with(asUser(STEWARD))).andExpect(status().isOk()));
        record("Node detail, 200 inherited properties, depth 20", p95, P95_NODE_DETAIL_MS, RUNS);
        assertThat(p95).isLessThanOrEqualTo(P95_NODE_DETAIL_MS);
    }

    @Test
    void submitAndApplyOf50ItemsOnA100000NodeHierarchy() throws Exception {
        int runs = 5;
        List<Long> submits = new ArrayList<>();
        List<Long> applies = new ArrayList<>();
        for (int run = 0; run < runs; run++) {
            String id = create("PERF 50 items " + UUID.randomUUID());
            for (int i = 0; i < 25; i++) {
                addItem(id, "{\"action\":\"add_node\",\"hierarchyCode\":\"PERF_H\",\"targetParentId\":\"" + data.firstRegion()
                        + "\",\"payload\":{\"nodeKind\":\"legal_entity\",\"name\":\"PERF new " + UUID.randomUUID() + "\",\"isLeaf\":true}}");
                addItem(id, "{\"action\":\"set_property\",\"hierarchyCode\":\"PERF_H\",\"nodeId\":\"" + leaf(run * 25 + i)
                        + "\",\"propertyCode\":\"PERF.P001\",\"payload\":{\"value\":\"PERF set " + run + "\"}}");
            }
            long t = System.nanoTime();
            mvc.perform(post("/api/v1/change-requests/" + id + "/submit").with(asUser(STEWARD)).header("If-Match", etag(id)))
                    .andExpect(status().isOk());
            submits.add((System.nanoTime() - t) / 1_000_000);
            t = System.nanoTime();
            MvcResult decided = mvc.perform(post("/api/v1/change-requests/" + id + "/decision").with(asUser(APPROVER))
                            .header("If-Match", etag(id)).contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"approve\"}"))
                    .andExpect(status().isOk()).andReturn();
            applies.add((System.nanoTime() - t) / 1_000_000);
            assertThat(json(decided).get("status").asText()).isEqualTo("applied");
        }
        long submit = percentile95(submits);
        long apply = percentile95(applies);
        record("Submit (validate + submit), 50 items", submit, P95_SUBMIT_MS, runs);
        record("Decide + apply, 50 items", apply, P95_APPLY_MS, runs);
        assertThat(submit).isLessThanOrEqualTo(P95_SUBMIT_MS);
        assertThat(apply).isLessThanOrEqualTo(P95_APPLY_MS);
    }

    /** MAX_ITEMS_PER_CHANGE_REQUEST: apply time is recorded; there is no target yet (LLD §10, Phase 4). */
    @Test
    void applyOf5000ItemsIsRecorded() {
        JdbcClient owner = ownerJdbc();
        UUID steward = ensureUser(STEWARD, "human");
        UUID approver = ensureUser(APPROVER, "human");
        UUID cr = owner.sql("""
                INSERT INTO mdm.change_request (version_id, title, requester_id, requester_kind)
                SELECT version_id, 'PERF 5000 items', :s, 'human' FROM mdm.version WHERE version_name = 'PERF working'
                RETURNING change_request_id
                """).param("s", steward).query(UUID.class).single();
        // set-up through the owner (5 000 API calls would measure the item endpoint, not apply)
        owner.sql("""
                INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, property_id, payload)
                SELECT :cr, row_number() OVER (ORDER BY a.node_id), 'set_property', h.hierarchy_id, a.node_id, d.property_id,
                       jsonb_build_object('value', 'PERF bulk')
                FROM mdm.node_attr a, mdm.hierarchy h, mdm.property_definition d
                WHERE a.node_name LIKE 'PERF leaf %' AND h.hierarchy_code = 'PERF_H' AND d.property_code = 'PERF.P002'
                  AND upper_inf(a.recorded_period)
                LIMIT 5000
                """).param("cr", cr).update();
        owner.sql("UPDATE mdm.change_request SET status = 'submitted' WHERE change_request_id = :cr").param("cr", cr).update();
        owner.sql("""
                UPDATE mdm.change_request SET status = 'approved', decided_by = :a, decided_at = now(), decision_basis = 'human_review'
                WHERE change_request_id = :cr
                """).param("a", approver).param("cr", cr).update();
        long t = System.nanoTime();
        ApplyService.ApplyResult result = applyService.apply(approver, cr);
        long ms = (System.nanoTime() - t) / 1_000_000;
        RESULTS.add("| Apply, 5 000 items (MAX_ITEMS_PER_CHANGE_REQUEST) | " + ms + " ms (single run) | none yet (Phase 4) | 1 |");
        assertThat(result.status()).isEqualTo("applied");
    }

    // ------------------------------------------------------------------ helpers

    private UUID leaf(int n) {
        return ownerJdbc().sql("SELECT node_id FROM mdm.node_attr WHERE node_name = :name")
                .param("name", "PERF leaf 0002-" + String.format("%04d", n % 100 + 1)).query(UUID.class).single();
    }

    private String create(String title) throws Exception {
        MvcResult r = mvc.perform(post("/api/v1/change-requests").with(asUser(STEWARD)).contentType(MediaType.APPLICATION_JSON)
                .content("{\"versionName\":\"PERF working\",\"title\":\"" + title + "\"}")).andExpect(status().isCreated()).andReturn();
        return json(r).get("id").asText();
    }

    private void addItem(String id, String body) throws Exception {
        mvc.perform(post("/api/v1/change-requests/" + id + "/items").with(asUser(STEWARD)).header("If-Match", etag(id))
                .contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isCreated());
    }

    private String etag(String id) throws Exception {
        return mvc.perform(get("/api/v1/change-requests/" + id).with(asUser(STEWARD))).andReturn().getResponse().getHeader("ETag");
    }

    private long p95(Callable<?> call) throws Exception {
        for (int i = 0; i < 5; i++) {
            call.call();                                        // warm-up, not measured
        }
        List<Long> ms = new ArrayList<>();
        for (int i = 0; i < RUNS; i++) {
            long t = System.nanoTime();
            call.call();
            ms.add((System.nanoTime() - t) / 1_000_000);
        }
        return percentile95(ms);
    }

    private static long percentile95(List<Long> values) {
        List<Long> sorted = new ArrayList<>(values);
        Collections.sort(sorted);
        return sorted.get((int) Math.ceil(0.95 * sorted.size()) - 1);
    }

    private static void record(String name, long p95, long target, int runs) {
        RESULTS.add("| " + name + " | " + p95 + " ms | " + target + " ms | " + runs + " |");
    }

    private JsonNode json(MvcResult r) throws Exception {
        return mapper.readTree(r.getResponse().getContentAsString());
    }
}
