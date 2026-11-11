package com.mdm.api;

import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
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
public abstract class PostgresIntegrationTest {

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
