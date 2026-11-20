package com.mdm.api.security;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.PostgresIntegrationTest;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.test.web.servlet.MockMvc;

import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** The development user picker's list (local and test profiles): answered without an actor; people and services only. */
class DevUsersControllerTest extends PostgresIntegrationTest {

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    @Test
    void listsActivePeopleAndServiceAccountsWithoutASignedInUser() throws Exception {
        ensureUser("du_person", "human");
        ensureUser("du_feed", "service");
        ensureUser("du_system", "system_feed");
        ensureUser("du_gone", "human");
        ownerJdbc().sql("UPDATE mdm.app_user SET is_active = false WHERE login = 'du_gone'").update();

        JsonNode users = mapper.readTree(mvc.perform(get(DevUsersController.PATH)).andExpect(status().isOk())
                .andReturn().getResponse().getContentAsString());
        List<String> logins = new ArrayList<>();
        users.forEach(u -> logins.add(u.get("login").asText()));
        assertThat(logins).contains("du_person", "du_feed").doesNotContain("du_system", "du_gone");
    }

    @Test
    void everyOtherApiCallStillNeedsAUser() throws Exception {
        mvc.perform(get("/api/v1/me")).andExpect(status().isUnauthorized());
    }
}
