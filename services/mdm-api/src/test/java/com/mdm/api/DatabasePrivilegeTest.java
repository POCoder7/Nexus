package com.mdm.api;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.core.NestedExceptionUtils;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.simple.JdbcClient;

import java.sql.SQLException;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.catchThrowableOfType;

/** The application connects with the least-privilege API login, not the owner (ADR-014, D-04). */
class DatabasePrivilegeTest extends PostgresIntegrationTest {

    @Autowired
    JdbcClient jdbc;

    @Test
    void applicationRunsAsTheApiLogin() {
        String user = jdbc.sql("SELECT current_user").query(String.class).single();
        Boolean inApiRole = jdbc.sql("SELECT pg_has_role(current_user, 'nexus_api', 'MEMBER')").query(Boolean.class).single();
        assertThat(user).isEqualTo("nexus_api_test");
        assertThat(inApiRole).isTrue();
    }

    @Test
    void applicationCannotWriteFactsDirectly() {
        DataAccessException ex = catchThrowableOfType(DataAccessException.class, () -> jdbc.sql("""
                INSERT INTO mdm.node_attr (node_id, node_name)
                VALUES ('00000000-0000-0000-0000-0000000009f1', 'NOT_ALLOWED')
                """).update());
        assertThat(ex).isNotNull();
        Throwable cause = NestedExceptionUtils.getMostSpecificCause(ex);
        assertThat(cause).isInstanceOf(SQLException.class);
        assertThat(((SQLException) cause).getSQLState()).isEqualTo("42501");
    }

    @Test
    void applicationCannotWriteDecisionColumns() {
        DataAccessException ex = catchThrowableOfType(DataAccessException.class, () -> jdbc.sql("""
                UPDATE mdm.change_request SET decision_basis = 'approved_policy'
                """).update());
        assertThat(ex).isNotNull();
        assertThat(((SQLException) NestedExceptionUtils.getMostSpecificCause(ex)).getSQLState()).isEqualTo("42501");
    }
}
