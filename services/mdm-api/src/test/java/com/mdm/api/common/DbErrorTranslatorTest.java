package com.mdm.api.common;

import org.junit.jupiter.api.Test;
import org.postgresql.util.PSQLException;
import org.postgresql.util.ServerErrorMessage;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.jdbc.UncategorizedSQLException;

import java.sql.SQLException;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

/** ADR-020: guards raise N1xxx (control), N2xxx (integrity), N3xxx (conflict); constraints map to standard classes. */
class DbErrorTranslatorTest {

    private final DbErrorTranslator translator = new DbErrorTranslator();

    private static UncategorizedSQLException wrap(SQLException e) {
        return new UncategorizedSQLException("test", "SELECT 1", e);
    }

    private static PSQLException guard(String sqlState, String message, String hint) {
        String raw = "SERROR\0C" + sqlState + "\0M" + message + "\0H" + hint + "\0";
        return new PSQLException(new ServerErrorMessage(raw));
    }

    @Test
    void controlViolationIsForbiddenWithHintAsCode() {
        Optional<ProblemDetail> p = translator.translate(wrap(guard("N1001",
                "Maker-checker violation: requester cannot decide their own change request", "maker_checker.self_decision")));
        assertThat(p).isPresent();
        assertThat(p.get().getStatus()).isEqualTo(HttpStatus.FORBIDDEN.value());
        assertThat(p.get().getType().toString()).isEqualTo("urn:nexus:problem:forbidden");
        assertThat(p.get().getProperties()).containsEntry("code", "maker_checker.self_decision");
        assertThat(p.get().getDetail()).contains("requester cannot decide");
    }

    @Test
    void integrityRuleIsUnprocessable() {
        ProblemDetail p = translator.translate(wrap(guard("N2001", "Cycle detected: …", "hierarchy.cycle"))).orElseThrow();
        assertThat(p.getStatus()).isEqualTo(422);
        assertThat(p.getType().toString()).isEqualTo("urn:nexus:problem:rule-violation");
        assertThat(p.getProperties()).containsEntry("code", "hierarchy.cycle");
    }

    @Test
    void staleBaseIsConflict() {
        ProblemDetail p = translator.translate(wrap(guard("N3001", "Value changed since drafting", "stale_base"))).orElseThrow();
        assertThat(p.getStatus()).isEqualTo(409);
        assertThat(p.getType().toString()).isEqualTo("urn:nexus:problem:conflict-stale-base");
    }

    @Test
    void exclusionAndUniqueViolationsAreConflicts() {
        assertThat(translator.translate(wrap(new SQLException("overlap", "23P01"))).orElseThrow().getStatus()).isEqualTo(409);
        assertThat(translator.translate(wrap(new SQLException("duplicate", "23505"))).orElseThrow().getStatus()).isEqualTo(409);
    }

    @Test
    void checkAndReferenceViolationsAreUnprocessable() {
        for (String state : new String[] {"23514", "23503", "22P02"}) {
            ProblemDetail p = translator.translate(wrap(new SQLException("bad", state))).orElseThrow();
            assertThat(p.getStatus()).as(state).isEqualTo(422);
            assertThat(p.getType().toString()).isEqualTo("urn:nexus:problem:constraint-violation");
        }
    }

    @Test
    void serializationFailureIsRetryLater() {
        ProblemDetail p = translator.translate(wrap(new SQLException("could not serialize", "40001"))).orElseThrow();
        assertThat(p.getStatus()).isEqualTo(503);
        assertThat(p.getType().toString()).isEqualTo("urn:nexus:problem:retry-later");
    }

    @Test
    void unknownStatesAreNotTranslated() {
        assertThat(translator.translate(wrap(new SQLException("boom", "XX000")))).isEmpty();
    }

    @Test
    void constraintDetailsDoNotLeakServerText() {
        ProblemDetail p = translator.translate(wrap(new SQLException("Key (node_name)=(Secret Name) already exists", "23505"))).orElseThrow();
        assertThat(p.getDetail()).doesNotContain("Secret Name");
    }
}
