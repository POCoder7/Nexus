package com.mdm.api.security;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import java.util.Optional;
import java.util.UUID;

/**
 * Development and test identity only (profiles {@code local} and {@code test}): the caller names a synthetic user
 * in the {@value #HEADER} header (a login in {@code mdm.app_user}). In {@code local}, {@code mdm.api.local-user}
 * may supply a default. This bean does not exist in any other profile, and {@link StartupGuard} stops the
 * application if no identity adapter exists, so this can never be how production users are identified.
 */
@Component
@Profile({"local", "test"})
public class LocalDevActor implements CurrentActor {

    public static final String HEADER = "X-Nexus-User";

    private final JdbcClient jdbc;
    private final String defaultLogin;

    public LocalDevActor(JdbcClient jdbc, @Value("${mdm.api.local-user:}") String defaultLogin) {
        this.jdbc = jdbc;
        this.defaultLogin = defaultLogin;
    }

    @Override
    public Optional<Actor> resolve(HttpServletRequest request) {
        String login = request.getHeader(HEADER);
        if (login == null || login.isBlank()) {
            login = defaultLogin;
        }
        if (login == null || login.isBlank()) {
            return Optional.empty();
        }
        return jdbc.sql("""
                SELECT user_id, login, display_name, kind::text AS kind
                FROM mdm.app_user
                WHERE login = :login AND is_active
                """)
                .param("login", login.trim())
                .query((rs, i) -> new Actor(rs.getObject("user_id", UUID.class), rs.getString("login"),
                        rs.getString("display_name"), rs.getString("kind")))
                .optional();
    }
}
