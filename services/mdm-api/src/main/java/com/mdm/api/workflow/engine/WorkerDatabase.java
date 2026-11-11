package com.mdm.api.workflow.engine;

import com.zaxxer.hikari.HikariDataSource;
import jakarta.annotation.PreDestroy;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;

/**
 * The worker's database connection (ADR-014, ADR-035): the workflow steps and the relay run as a login in role
 * {@code nexus_wf}, never as the API's login. In the worker process the main datasource already is that login and
 * {@code mdm.worker.datasource.url} stays empty; when API and worker share a JVM (tests, local runs) the property names a
 * separate login. Deliberately not a {@link JdbcClient} bean, so Spring's own JdbcClient is not replaced.
 */
@Component
public class WorkerDatabase {

    private final JdbcClient jdbc;
    private final HikariDataSource own;

    public WorkerDatabase(DataSource primary,
                          @Value("${mdm.worker.datasource.url:}") String url,
                          @Value("${mdm.worker.datasource.username:}") String username,
                          @Value("${mdm.worker.datasource.password:}") String password) {
        if (url == null || url.isBlank()) {
            this.own = null;
            this.jdbc = JdbcClient.create(primary);
        } else {
            HikariDataSource ds = new HikariDataSource();
            ds.setPoolName("worker");
            ds.setJdbcUrl(url);
            ds.setUsername(username);
            ds.setPassword(password);
            ds.setMaximumPoolSize(4);
            ds.setConnectionInitSql("SET TIME ZONE 'UTC'");   // recorded time is UTC everywhere (ADR-018)
            this.own = ds;
            this.jdbc = JdbcClient.create(ds);
        }
    }

    public JdbcClient jdbc() {
        return jdbc;
    }

    @PreDestroy
    void close() {
        if (own != null) {
            own.close();
        }
    }
}
