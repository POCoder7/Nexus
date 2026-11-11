package com.mdm.api;

import com.mdm.api.security.LocalDevActor;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

import java.util.UUID;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;

/**
 * Base for API tests against real PostgreSQL with the real migrations (V1…) and production privileges:
 * <ul>
 *   <li>Flyway runs as the container's owner account and also applies {@code db/testroles}, which creates
 *       the login {@code nexus_api_test} in role {@code nexus_api};</li>
 *   <li>the application datasource uses that login, so every request runs with the API's least privileges (ADR-014);</li>
 *   <li>{@link #ownerJdbc()} is for test setup only (seeding facts the API itself may not write).</li>
 * </ul>
 * One container per JVM (started once, removed by Testcontainers when the JVM exits), so cached Spring
 * contexts never point at a stopped database.
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
public abstract class PostgresIntegrationTest {

    /** Synthetic administrator who grants roles in test setup (a grant needs a granter other than the grantee). */
    protected static final UUID TEST_ADMIN = UUID.fromString("00000000-0000-0000-0000-00000000a000");

    /** Sends the request as the named synthetic user (LocalDevActor, profile "test"). */
    protected static RequestPostProcessor asUser(String login) {
        return request -> {
            request.addHeader(LocalDevActor.HEADER, login);
            return request;
        };
    }

    /** Creates a synthetic user if missing and returns its id (owner connection; test setup only). */
    protected static UUID ensureUser(String login, String kind) {
        JdbcClient jdbc = ownerJdbc();
        jdbc.sql("""
                INSERT INTO mdm.app_user (user_id, login, display_name, kind)
                VALUES (:admin, 't_admin', 'Test admin', 'human') ON CONFLICT (login) DO NOTHING
                """).param("admin", TEST_ADMIN).update();
        jdbc.sql("""
                INSERT INTO mdm.app_user (login, display_name, kind)
                VALUES (:login, :login, CAST(:kind AS mdm.requester_kind)) ON CONFLICT (login) DO NOTHING
                """).param("login", login).param("kind", kind).update();
        return jdbc.sql("SELECT user_id FROM mdm.app_user WHERE login = :login").param("login", login).query(UUID.class).single();
    }

    /** Grants a role from yesterday onwards (owner connection; test setup only). Null hierarchy = all hierarchies. */
    protected static void grant(String login, String role, String hierarchyCode, UUID topNodeId) {
        UUID user = ensureUser(login, "human");
        ownerJdbc().sql("""
                INSERT INTO mdm.user_role (user_id, role_code, hierarchy_id, top_node_id, granted_by, valid_period)
                SELECT :user, :role, (SELECT hierarchy_id FROM mdm.hierarchy WHERE hierarchy_code = :code), CAST(:top AS uuid), :admin,
                       daterange(current_date - 1, NULL)
                WHERE NOT EXISTS (SELECT 1 FROM mdm.user_role ur
                                  WHERE ur.user_id = :user AND ur.role_code = :role AND upper_inf(ur.recorded_period)
                                    AND ur.hierarchy_id IS NOT DISTINCT FROM (SELECT hierarchy_id FROM mdm.hierarchy WHERE hierarchy_code = :code)
                                    AND ur.top_node_id IS NOT DISTINCT FROM CAST(:top AS uuid))
                """)
                .param("user", user).param("role", role).param("code", hierarchyCode).param("top", topNodeId)
                .param("admin", TEST_ADMIN).update();
    }

    protected static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");

    static {
        POSTGRES.start();
    }

    @DynamicPropertySource
    static void databaseProperties(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", () -> "nexus_api_test");
        registry.add("spring.datasource.password", () -> "nexus_api_test");
        registry.add("spring.flyway.url", POSTGRES::getJdbcUrl);
        registry.add("spring.flyway.user", POSTGRES::getUsername);
        registry.add("spring.flyway.password", POSTGRES::getPassword);
        registry.add("spring.flyway.locations", () -> "classpath:db/migration,classpath:db/testroles");
    }

    /** Owner connection for test setup only. Never use it for the behaviour under test. */
    protected static JdbcClient ownerJdbc() {
        return JdbcClient.create(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
    }
}
