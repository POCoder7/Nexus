package com.mdm.api.ledger;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.PostgresIntegrationTest;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.ResultActions;

import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Ledgers (ADR-046 D4, Phase 4 LLD §17.4): every role reads them, paged; an ADMIN creates, changes and retires them;
 * every change is audited with the ADMIN as actor. Synthetic ledgers only.
 */
class LedgerApiTest extends PostgresIntegrationTest {

    static final String ADMIN = "lg_admin";
    static final String VIEWER = "lg_viewer";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    @BeforeEach
    void users() {
        grant(ADMIN, "ADMIN", null, null);
        grant(VIEWER, "VIEWER", null, null);
    }

    @Test
    void anAdminCreatesChangesAndRetiresALedgerAndEveryoneReadsIt() throws Exception {
        save(ADMIN, "LGA1", "{\"name\":\"Synthetic US ledger\",\"currency\":\"USD\",\"financeCountry\":\"USA\"}")
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.id").value("LGA1"))
                .andExpect(jsonPath("$.active").value(true));
        save(ADMIN, "LGA1", "{\"name\":\"Synthetic US ledger\",\"currency\":\"USD\",\"financeCountry\":\"USA\",\"active\":false}")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.active").value(false));
        save(ADMIN, "LGA2", "{\"name\":\"Synthetic UK ledger\",\"currency\":\"GBP\",\"financeCountry\":\"GBR\"}")
                .andExpect(status().isCreated());

        List<String> ids = new ArrayList<>();
        String cursor = null;
        do {   // one row per page proves the paging
            var req = get("/api/v1/ledgers").param("limit", "1").with(asUser(VIEWER));
            if (cursor != null) {
                req = req.param("cursor", cursor);
            }
            JsonNode page = mapper.readTree(mvc.perform(req).andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
            page.get("items").forEach(l -> ids.add(l.get("id").asText()));
            cursor = page.hasNonNull("nextCursor") ? page.get("nextCursor").asText() : null;
        } while (cursor != null);
        assertThat(ids).containsSubsequence("LGA1", "LGA2");

        Integer audited = ownerJdbc().sql("""
                SELECT count(*) FROM mdm.audit_log a JOIN mdm.app_user u ON u.user_id = a.actor_id
                WHERE a.table_name = 'ledger' AND a.new_row ->> 'ledger_id' = 'LGA1' AND u.login = :login
                """).param("login", ADMIN).query(Integer.class).single();
        assertThat(audited).isEqualTo(2);
    }

    @Test
    void onlyAnAdminChangesLedgersAndBadValuesAreRefusedField() throws Exception {
        save(VIEWER, "LGB1", "{\"name\":\"Synthetic\",\"currency\":\"USD\",\"financeCountry\":\"USA\"}")
                .andExpect(status().isForbidden());
        save(ADMIN, "LGB1", "{\"name\":\"Synthetic\",\"currency\":\"usd\",\"financeCountry\":\"USA\"}")
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.errors[0].field").value("currency"));
        save(ADMIN, "LG B1", "{\"name\":\"Synthetic\",\"currency\":\"USD\",\"financeCountry\":\"USA\"}")
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.errors[0].field").value("id"));
        save(ADMIN, "LGB1", "{\"name\":\" \",\"currency\":\"USD\",\"financeCountry\":\"USA\"}")
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.errors[0].field").value("name"));
    }

    private ResultActions save(String login, String id, String body) throws Exception {
        return mvc.perform(put("/api/v1/admin/ledgers/{id}", id).with(asUser(login)).contentType(MediaType.APPLICATION_JSON).content(body));
    }
}
