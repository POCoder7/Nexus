package com.mdm.api.security;

import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * DEVELOPMENT AND TEST ONLY (profiles {@code local} and {@code test}, like {@link LocalDevActor}): the logins the UI's
 * development user picker offers, read from the database instead of a fixed list, so the picker shows the users the
 * running database really has (the demo's data set, or the end-to-end seed). Active people and service accounts only:
 * system actors (the loader, the workflow engine) and AI agents cannot sign in. Answered without an actor, because the
 * picker needs it before anyone is chosen (ActorFilter lets {@value #PATH} through); not part of the published API.
 */
@RestController
@Profile({"local", "test"})
public class DevUsersController {

    public static final String PATH = "/api/v1/dev/users";

    public record DevUser(String login, String displayName) {
    }

    private final JdbcClient jdbc;

    public DevUsersController(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    @GetMapping(PATH)
    public List<DevUser> listDevUsers() {
        return jdbc.sql("""
                SELECT login, display_name FROM mdm.app_user
                WHERE is_active AND kind IN ('human', 'service')
                ORDER BY login LIMIT 500
                """).query((rs, i) -> new DevUser(rs.getString(1), rs.getString(2))).list();
    }
}
