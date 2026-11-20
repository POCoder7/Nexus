package com.mdm.api.validation;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.PostgresIntegrationTest;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.ResultActions;

import java.util.HashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * One rule catalogue (ADR-046 D5, Phase 4 LLD §17.5): configured rules and database guards in one list; ADMIN edits a
 * rule, and may only relabel a guard; APPROVER reads; other roles see nothing.
 */
class ValidationRuleApiTest extends PostgresIntegrationTest {

    static final String ADMIN = "vr_admin";
    static final String APPROVER = "vr_approver";
    static final String EDITOR = "vr_editor";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    @BeforeEach
    void users() {
        grant(ADMIN, "ADMIN", null, null);
        grant(APPROVER, "APPROVER", null, null);
        grant(EDITOR, "EDITOR", null, null);
        ownerJdbc().sql("""
                INSERT INTO mdm.validation_rule (rule_code, rule_name, description, level, severity, engine, expression)
                VALUES ('VRT.SAMPLE', 'Sample', 'A synthetic rule', 'node', 'warning', 'sql',
                        'SELECT NULL::uuid, NULL::uuid, NULL::text WHERE false')
                ON CONFLICT (rule_code) DO NOTHING
                """).update();
    }

    @Test
    void theCatalogueListsRulesAndGuardsForAdminsAndApprovers() throws Exception {
        Map<String, JsonNode> all = list(ADMIN);
        assertThat(all.get("NEXUS.HIERARCHY_CYCLE").get("enforcement").asText()).isEqualTo("guard");
        assertThat(all.get("NEXUS.HIERARCHY_CYCLE").get("guardCode").asText()).isEqualTo("N2001");
        assertThat(all.get("NEXUS.PARENT_MISSING").get("guardCode").asText()).isEqualTo("N2007");
        assertThat(all.get("VRT.SAMPLE").get("enforcement").asText()).isEqualTo("rule");
        assertThat(all.get("VRT.SAMPLE").get("mode").asText()).isEqualTo("both");
        assertThat(list(APPROVER)).containsKey("NEXUS.HIERARCHY_CYCLE");
        mvc.perform(get("/api/v1/admin/validation-rules").with(asUser(EDITOR))).andExpect(status().isForbidden());
    }

    @Test
    void aGuardCanBeRelabelledButNeverSwitchedOffOrWeakened() throws Exception {
        edit(ADMIN, "NEXUS.HIERARCHY_CYCLE", "{\"externalCode\":\"VR07\",\"name\":\"NO_CYCLES\"}")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.externalCode").value("VR07"))
                .andExpect(jsonPath("$.name").value("NO_CYCLES"));
        edit(ADMIN, "NEXUS.HIERARCHY_CYCLE", "{\"active\":false}")
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("validation_rule.guard_fixed"));
        edit(ADMIN, "NEXUS.PARENT_IS_LEAF", "{\"severity\":\"warning\"}")
                .andExpect(status().isUnprocessableEntity());
        edit(APPROVER, "NEXUS.HIERARCHY_CYCLE", "{\"name\":\"x\"}").andExpect(status().isForbidden());
    }

    @Test
    void anAdminEditsARuleAndANewExpressionBumpsItsVersion() throws Exception {
        int before = list(ADMIN).get("VRT.SAMPLE").get("version").asInt();
        edit(ADMIN, "VRT.SAMPLE", "{\"mode\":\"import\",\"severity\":\"error\",\"active\":false,"
                + "\"expression\":\"SELECT NULL::uuid, NULL::uuid, 'x'::text WHERE false\"}")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.mode").value("import"))
                .andExpect(jsonPath("$.severity").value("error"))
                .andExpect(jsonPath("$.active").value(false))
                .andExpect(jsonPath("$.version").value(before + 1));
        edit(ADMIN, "VRT.SAMPLE", "{\"mode\":\"sometimes\"}")
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.errors[0].field").value("mode"));
        edit(ADMIN, "VRT.NOPE", "{\"name\":\"x\"}").andExpect(status().isNotFound());
        Integer audited = ownerJdbc().sql("""
                SELECT count(*) FROM mdm.audit_log a JOIN mdm.app_user u ON u.user_id = a.actor_id
                WHERE a.table_name = 'validation_rule' AND a.new_row ->> 'rule_code' = 'VRT.SAMPLE' AND u.login = :l
                """).param("l", ADMIN).query(Integer.class).single();
        assertThat(audited).isPositive();
    }

    private Map<String, JsonNode> list(String login) throws Exception {
        Map<String, JsonNode> byCode = new HashMap<>();
        String cursor = null;
        do {
            var req = get("/api/v1/admin/validation-rules").param("limit", "10").with(asUser(login));
            if (cursor != null) {
                req = req.param("cursor", cursor);
            }
            JsonNode page = mapper.readTree(mvc.perform(req).andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
            page.get("items").forEach(r -> byCode.put(r.get("code").asText(), r));
            cursor = page.hasNonNull("nextCursor") ? page.get("nextCursor").asText() : null;
        } while (cursor != null);
        return byCode;
    }

    private ResultActions edit(String login, String code, String body) throws Exception {
        return mvc.perform(patch("/api/v1/admin/validation-rules/{code}", code).with(asUser(login))
                .contentType(MediaType.APPLICATION_JSON).content(body));
    }
}
