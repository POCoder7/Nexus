package com.mdm.api;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.test.web.servlet.MockMvc;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Keeps the committed API description, {@code docs/api/openapi.json}, equal to what the code serves. If the API changes,
 * regenerate it with {@code ./mvnw -B verify -Dopenapi.update=true} and commit the file with the change.
 */
class OpenApiDocumentTest extends PostgresIntegrationTest {

    static final Path COMMITTED = Path.of("..", "..", "docs", "api", "openapi.json");

    @Autowired
    MockMvc mvc;

    @Test
    void theCommittedApiDescriptionMatchesTheCode() throws Exception {
        String served = mvc.perform(get("/v3/api-docs")).andExpect(status().isOk()).andReturn().getResponse()
                .getContentAsString(StandardCharsets.UTF_8);
        String normalised = normalise(served);
        assertThat(normalised).contains("/api/v1/change-requests/{id}/decision", "/api/v1/hierarchies/{code}/children");
        // the Actor comes from the identity adapter, never from the request: no operation may list it as a parameter
        new ObjectMapper().readTree(served).path("paths").forEach(path -> path.forEach(operation ->
                operation.path("parameters").forEach(p -> assertThat(p.path("name").asText())
                        .isNotIn("actor", "userId", "login", "displayName", "kind"))));

        // operation ids name the generated client's methods (ADR-025): a clash makes springdoc rename one ("decide_1")
        new ObjectMapper().readTree(served).path("paths").forEach(path -> path.forEach(operation ->
                assertThat(operation.path("operationId").asText()).as("operation ids must be unique")
                        .doesNotMatch(".*_\\d+$")));

        if (Boolean.getBoolean("openapi.update")) {
            Files.createDirectories(COMMITTED.getParent());
            Files.writeString(COMMITTED, normalised, StandardCharsets.UTF_8);
        }
        assertThat(Files.exists(COMMITTED)).as("docs/api/openapi.json exists (run with -Dopenapi.update=true)").isTrue();
        assertThat(Files.readString(COMMITTED, StandardCharsets.UTF_8))
                .as("docs/api/openapi.json is out of date: run ./mvnw -B verify -Dopenapi.update=true and commit it")
                .isEqualTo(normalised);
    }

    /** Sorted keys and pretty printing, so the committed file is stable and diffs are readable. */
    private static String normalise(String json) throws Exception {
        ObjectMapper mapper = new ObjectMapper().enable(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS)
                .enable(SerializationFeature.INDENT_OUTPUT);
        JsonNode tree = mapper.readTree(json);
        Object plain = mapper.treeToValue(tree, Object.class);
        return mapper.writeValueAsString(plain).replace("\r\n", "\n") + "\n";
    }
}
