package com.mdm.api.common;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.FilterType;
import org.springframework.context.annotation.Import;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import static org.hamcrest.Matchers.matchesPattern;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** Problem Details carry a stable type URN and the request's correlation id (overview §9, ADR-015). */
// IdempotencyFilter needs the database; this slice has none and does not exercise POST idempotency.
@WebMvcTest(controllers = ProblemShapeTest.ThrowingController.class,
        excludeFilters = @ComponentScan.Filter(type = FilterType.ASSIGNABLE_TYPE, classes = IdempotencyFilter.class))
@Import({ApiExceptionHandler.class, DbErrorTranslator.class, CorrelationIdFilter.class, ProblemShapeTest.ThrowingController.class})
class ProblemShapeTest {

    @RestController
    static class ThrowingController {
        @GetMapping("/test/not-found")
        String notFound() { throw new NotFoundException("Node x not found"); }

        @GetMapping("/test/bad")
        String bad() { throw new IllegalArgumentException("limit must be between 1 and 1000"); }
    }

    @Autowired
    MockMvc mvc;

    @Test
    void notFoundHasTypeAndGeneratedCorrelationId() throws Exception {
        mvc.perform(get("/test/not-found"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.type").value("urn:nexus:problem:not-found"))
                .andExpect(jsonPath("$.correlationId").value(matchesPattern("[0-9a-f-]{36}")))
                .andExpect(header().string(CorrelationIdFilter.HEADER, matchesPattern("[0-9a-f-]{36}")));
    }

    @Test
    void badRequestEchoesAValidIncomingCorrelationId() throws Exception {
        mvc.perform(get("/test/bad").header(CorrelationIdFilter.HEADER, "abc-123"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.type").value("urn:nexus:problem:invalid-request"))
                .andExpect(jsonPath("$.correlationId").value("abc-123"));
    }

    @Test
    void invalidIncomingCorrelationIdIsReplaced() throws Exception {
        mvc.perform(get("/test/bad").header(CorrelationIdFilter.HEADER, "<script>"))
                .andExpect(jsonPath("$.correlationId").value(matchesPattern("[0-9a-f-]{36}")));
    }
}
