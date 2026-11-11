package com.mdm.api.security;

import com.mdm.api.PostgresIntegrationTest;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.simple.JdbcClient;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * SEC-02 scopes: a steward scoped to a sub-tree may propose under it and nowhere else.
 * Tree (synthetic):  SCOPE_TOP ── S1 ── S2        OTHER (sibling of S1, outside the scope)
 *                    ROOT ──┴── OTHER ── SHARED  (SHARED is also placed under S1, as a shared node)
 */
class EntitlementServiceTest extends PostgresIntegrationTest {

    static final UUID ROOT = id("f0");
    static final UUID SCOPE_TOP = id("f1");
    static final UUID S1 = id("f2");
    static final UUID S2 = id("f3");
    static final UUID OTHER = id("f4");
    static final UUID SHARED = id("f5");

    @Autowired
    EntitlementService entitlements;

    private static UUID id(String suffix) {
        return UUID.fromString("00000000-0000-0000-0000-0000000e00" + suffix);
    }

    private Actor actor(String login) {
        UUID user = ensureUser(login, "human");
        return new Actor(user, login, login, "human");
    }

    @BeforeEach
    void seed() {
        JdbcClient jdbc = ownerJdbc();
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'SCOPE_H'").query(Integer.class).single() == 0) {
            for (UUID n : new UUID[] {ROOT, SCOPE_TOP, S1, S2, OTHER, SHARED}) {
                jdbc.sql("INSERT INTO mdm.node (node_id, node_kind) VALUES (:n, 'structural')").param("n", n).update();
                jdbc.sql("INSERT INTO mdm.node_attr (node_id, node_name) VALUES (:n, :name)")
                        .param("n", n).param("name", "Scope " + n.toString().substring(32)).update();
            }
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, top_node_id, allow_shared_nodes)
                    VALUES ('SCOPE_H', 'Scope hierarchy', :root, true)
                    """).param("root", ROOT).update();
            String rel = """
                    INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, is_primary, valid_period)
                    SELECT hierarchy_id, :p, :c, :primary, daterange(current_date - 30, NULL) FROM mdm.hierarchy WHERE hierarchy_code = 'SCOPE_H'
                    """;
            jdbc.sql(rel).param("p", ROOT).param("c", SCOPE_TOP).param("primary", true).update();
            jdbc.sql(rel).param("p", SCOPE_TOP).param("c", S1).param("primary", true).update();
            jdbc.sql(rel).param("p", S1).param("c", S2).param("primary", true).update();
            jdbc.sql(rel).param("p", ROOT).param("c", OTHER).param("primary", true).update();
            jdbc.sql(rel).param("p", OTHER).param("c", SHARED).param("primary", true).update();
            jdbc.sql(rel).param("p", S1).param("c", SHARED).param("primary", false).update();
        }
        grant("s_scoped", "STEWARD", "SCOPE_H", SCOPE_TOP);
        grant("s_approver", "APPROVER", "SCOPE_H", null);
    }

    private UUID hierarchy() {
        return ownerJdbc().sql("SELECT hierarchy_id FROM mdm.hierarchy WHERE hierarchy_code = 'SCOPE_H'").query(UUID.class).single();
    }

    @Test
    void stewardMayProposeAtAndUnderTheScopeTop() {
        Actor steward = actor("s_scoped");
        assertThatCode(() -> entitlements.require(steward, Permission.PROPOSE, hierarchy(), SCOPE_TOP)).doesNotThrowAnyException();
        assertThatCode(() -> entitlements.require(steward, Permission.PROPOSE, hierarchy(), S2)).doesNotThrowAnyException();
    }

    @Test
    void aSharedPlacementUnderTheScopeCounts() {
        assertThatCode(() -> entitlements.require(actor("s_scoped"), Permission.PROPOSE, hierarchy(), SHARED)).doesNotThrowAnyException();
    }

    @Test
    void stewardMayNotProposeOutsideTheScope() {
        Actor steward = actor("s_scoped");
        assertThatThrownBy(() -> entitlements.require(steward, Permission.PROPOSE, hierarchy(), OTHER))
                .isInstanceOf(ForbiddenException.class);
        assertThatThrownBy(() -> entitlements.require(steward, Permission.PROPOSE, hierarchy(), ROOT))
                .isInstanceOf(ForbiddenException.class);
    }

    @Test
    void aSubtreeGrantDoesNotCoverTheWholeHierarchy() {
        assertThatThrownBy(() -> entitlements.require(actor("s_scoped"), Permission.PROPOSE, hierarchy(), null))
                .isInstanceOf(ForbiddenException.class);
    }

    @Test
    void aRoleWithoutThePermissionIsRefused() {
        assertThatThrownBy(() -> entitlements.require(actor("s_approver"), Permission.PROPOSE, hierarchy(), S1))
                .isInstanceOf(ForbiddenException.class);
        assertThatCode(() -> entitlements.require(actor("s_approver"), Permission.DECIDE, hierarchy(), S1)).doesNotThrowAnyException();
    }

    @Test
    void anExpiredGrantNoLongerCounts() {
        UUID user = ensureUser("s_expired", "human");
        ownerJdbc().sql("""
                INSERT INTO mdm.user_role (user_id, role_code, hierarchy_id, granted_by, valid_period)
                SELECT :u, 'STEWARD', hierarchy_id, :admin, daterange(current_date - 30, current_date - 5)
                FROM mdm.hierarchy WHERE hierarchy_code = 'SCOPE_H'
                  AND NOT EXISTS (SELECT 1 FROM mdm.user_role WHERE user_id = :u)
                """).param("u", user).param("admin", TEST_ADMIN).update();
        assertThatThrownBy(() -> entitlements.require(actor("s_expired"), Permission.PROPOSE, hierarchy(), S1))
                .isInstanceOf(ForbiddenException.class);
    }
}
