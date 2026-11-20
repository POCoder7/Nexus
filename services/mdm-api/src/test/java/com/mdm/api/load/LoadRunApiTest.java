package com.mdm.api.load;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.PostgresIntegrationTest;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockMultipartHttpServletRequestBuilder;

import java.io.InputStream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.multipart;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * The whole hackathon load through the API (ADR-046; Phase 4 LLD §17.6 to §17.8; increment H-6): upload, prepare by one
 * ADMIN, approve by another, apply by the approver, then the data, the configuration, access and versions in Nexus.
 * Synthetic sample from src/test/resources/load/hackathon.
 */
class LoadRunApiTest extends PostgresIntegrationTest {

    static final String PREPARER = "lr_admin_one";
    static final String APPROVER = "lr_admin_two";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    @AfterAll
    static void switchOffTheLoadedRules() {
        // the data set's rules apply to every hierarchy; other test classes share this database
        ownerJdbc().sql("UPDATE mdm.validation_rule SET is_active = false WHERE enforcement = 'rule' AND external_code LIKE 'VR%'").update();
    }

    @Test
    void theSampleLoadsThroughTwoAdminsAndLandsWhereTheFilesSay() throws Exception {
        grant(PREPARER, "ADMIN", null, null);
        grant(APPROVER, "ADMIN", null, null);

        JsonNode staged = json(mvc.perform(upload(PREPARER)).andExpect(status().isCreated()).andReturn());
        assertThat(staged.get("errors").asInt()).isZero();
        String id = staged.get("loadId").asText();

        JsonNode prepared = json(mvc.perform(post("/api/v1/admin/load-runs/" + id + "/prepare").with(asUser(PREPARER))
                .contentType(MediaType.APPLICATION_JSON).content("{}")).andExpect(status().isOk()).andReturn());
        assertThat(prepared.get("status").asText()).isEqualTo("prepared");
        assertThat(prepared.get("targetVersion").asText()).isEqualTo("FY 2026-27 Working");
        assertThat(prepared.get("plan").get("counts").get("nodes").asInt()).isEqualTo(59);
        assertThat(prepared.get("plan").get("skipped")).hasSize(5);
        String manifest = prepared.get("manifestSha256").asText();

        approve(PREPARER, id, manifest).andExpect(status().isForbidden());                     // nobody approves their own load
        approve(APPROVER, id, "0".repeat(64)).andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("load.manifest_mismatch"));
        approve(APPROVER, id, manifest).andExpect(status().isOk()).andExpect(jsonPath("$.status").value("approved"));
        mvc.perform(post("/api/v1/admin/load-runs/" + id + "/apply").with(asUser(PREPARER)))
                .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.code").value("load.not_approver"));

        JsonNode applied = json(mvc.perform(post("/api/v1/admin/load-runs/" + id + "/apply").with(asUser(APPROVER)))
                .andExpect(status().isOk()).andReturn());
        assertThat(applied.get("error").isNull()).as("error: %s", applied.get("error")).isTrue();
        assertThat(applied.get("status").asText()).isEqualTo("applied");
        assertThat(applied.get("report").get("reconciliation").get("clean").asBoolean()).isTrue();
        assertThat(applied.get("requests")).hasSize(7).allSatisfy(r -> assertThat(r.get("status").asText()).isEqualTo("applied"));

        JdbcClient db = ownerJdbc();
        assertThat(one(db, """
                SELECT a.display_name || '/' || a.is_active FROM mdm.node_attr a WHERE a.node_name = '10110' AND upper_inf(a.recorded_period)
                """)).isEqualTo("FP and A Group/true");
        assertThat(one(db, "SELECT is_active::text FROM mdm.node_attr WHERE node_name = '30220' AND upper_inf(recorded_period)")).isEqualTo("false");
        assertThat(one(db, """
                SELECT v.value #>> '{}' FROM mdm.property_value v JOIN mdm.property_definition p ON p.property_id = v.property_id
                JOIN mdm.node_attr a ON a.node_id = v.node_id AND upper_inf(a.recorded_period)
                WHERE p.property_code = 'GL_COMPANY' AND a.node_name = '10110' AND upper_inf(v.recorded_period)
                """)).isEqualTo("1000");
        assertThat(one(db, "SELECT count(*)::text FROM mdm.property_hierarchy ph JOIN mdm.property_definition p USING (property_id) WHERE p.property_code = 'GL_COMPANY'"))
                .isEqualTo("3");
        assertThat(one(db, "SELECT external_code FROM mdm.validation_rule WHERE rule_code = 'NEXUS.HIERARCHY_CYCLE'")).isEqualTo("VR07");
        assertThat(one(db, "SELECT is_active::text || '/' || mode FROM mdm.validation_rule WHERE rule_code = 'VR17'")).isEqualTo("true/both");
        assertThat(one(db, "SELECT currency_code FROM mdm.ledger WHERE ledger_id = 'L200'")).isEqualTo("GBP");
        assertThat(one(db, """
                SELECT string_agg(u.login, ',' ORDER BY u.login) FROM mdm.user_group_member m JOIN mdm.user_group g USING (group_id)
                JOIN mdm.app_user u USING (user_id) WHERE g.group_code = 'ORG_EDITORS' AND upper_inf(m.recorded_period)
                """)).isEqualTo("u_editor1,u_editor3");
        assertThat(one(db, "SELECT string_agg(version_name || ':' || status, ',' ORDER BY version_name) FROM mdm.version WHERE version_name LIKE 'FY 202%'"))
                .isEqualTo("FY 2024-25 Final:expired,FY 2025-26 Final:finalized,FY 2026-27 Q2 Close:finalized,FY 2026-27 Working:working");

        // the same files again collide with what is now in Nexus
        String again = json(mvc.perform(upload(PREPARER)).andExpect(status().isCreated()).andReturn()).get("loadId").asText();
        mvc.perform(post("/api/v1/admin/load-runs/" + again + "/prepare").with(asUser(PREPARER)).contentType(MediaType.APPLICATION_JSON).content("{}"))
                .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.code").value("load.has_errors"));
        mvc.perform(get("/api/v1/admin/load-runs/" + again + "/findings").with(asUser(PREPARER)))
                .andExpect(status().isOk()).andExpect(jsonPath("$[0].kind").value("exists"));
    }

    @Test
    void aZipUploadIsUnpackedAndTheLoadAppliesInTheBackground() throws Exception {
        grant(PREPARER, "ADMIN", null, null);
        grant(APPROVER, "ADMIN", null, null);
        java.io.ByteArrayOutputStream zip = new java.io.ByteArrayOutputStream();
        try (java.util.zip.ZipOutputStream z = new java.util.zip.ZipOutputStream(zip)) {
            for (String[] f : new String[][] {
                    {"set/hierarchies.csv", "hierarchy_code,hierarchy_name,top_node_code,description\nZIPH,Zip hierarchy,ZIPT,Synthetic\n"},
                    {"set/nodes.csv", "node_code,node_name,description,node_type,status\nZIPT,Zip top,,LIMB,active\n77001,Zip leaf,,LEAF,active\n"},
                    {"set/relationships.csv", "hierarchy_code,parent_code,child_code,sort_order\nZIPH,,ZIPT,1\nZIPH,ZIPT,77001,1\n"},
                    {"set/versions.csv", "version_code,version_name,status,description\nZIPW,ZIP working,working,Synthetic\n"}}) {
                z.putNextEntry(new java.util.zip.ZipEntry(f[0]));
                z.write(f[1].getBytes(java.nio.charset.StandardCharsets.UTF_8));
                z.closeEntry();
            }
        }
        JsonNode staged = json(mvc.perform(multipart("/api/v1/admin/load-runs/uploads")
                .file(new MockMultipartFile("files", "set.zip", "application/zip", zip.toByteArray())).with(asUser(PREPARER)))
                .andExpect(status().isCreated()).andReturn());
        assertThat(staged.get("staged")).hasSize(4);
        assertThat(staged.get("errors").asInt()).isZero();
        String id = staged.get("loadId").asText();
        String manifest = json(mvc.perform(post("/api/v1/admin/load-runs/" + id + "/prepare").with(asUser(PREPARER))
                .contentType(MediaType.APPLICATION_JSON).content("{}")).andExpect(status().isOk()).andReturn()).get("manifestSha256").asText();
        approve(APPROVER, id, manifest).andExpect(status().isOk());

        mvc.perform(post("/api/v1/admin/load-runs/" + id + "/apply").param("wait", "false").with(asUser(APPROVER)))
                .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("applying"));
        mvc.perform(post("/api/v1/admin/load-runs/" + id + "/apply").param("wait", "false").with(asUser(APPROVER)))
                .andExpect(status().isUnprocessableEntity());                                       // once only
        String state = "applying";
        for (int i = 0; i < 120 && "applying".equals(state); i++) {
            Thread.sleep(500);
            state = json(mvc.perform(get("/api/v1/admin/load-runs/" + id).with(asUser(APPROVER))).andReturn()).get("status").asText();
        }
        assertThat(state).isEqualTo("applied");
        assertThat(one(ownerJdbc(), "SELECT count(*)::text FROM mdm.node_attr WHERE node_name IN ('ZIPT', '77001') AND upper_inf(recorded_period)"))
                .isEqualTo("2");
    }

    @Test
    void onlyAnAdminLoadsData() throws Exception {
        grant("lr_editor", "EDITOR", null, null);
        mvc.perform(upload("lr_editor")).andExpect(status().isForbidden());
    }

    private MockMultipartHttpServletRequestBuilder upload(String login) throws Exception {
        MockMultipartHttpServletRequestBuilder b = multipart("/api/v1/admin/load-runs/uploads");
        for (String f : HackathonIntakeTest.FILES) {
            try (InputStream in = getClass().getResourceAsStream("/load/hackathon/" + f)) {
                b.file(new MockMultipartFile("files", f, "text/csv", in.readAllBytes()));
            }
        }
        b.with(asUser(login));
        return b;
    }

    private org.springframework.test.web.servlet.ResultActions approve(String login, String id, String sha) throws Exception {
        return mvc.perform(post("/api/v1/admin/load-runs/" + id + "/approve").with(asUser(login))
                .contentType(MediaType.APPLICATION_JSON).content("{\"manifestSha256\":\"" + sha + "\"}"));
    }

    private static String one(JdbcClient db, String sql) {
        return db.sql(sql).query(String.class).single();
    }

    private JsonNode json(MvcResult r) throws Exception {
        return mapper.readTree(r.getResponse().getContentAsString());
    }
}
