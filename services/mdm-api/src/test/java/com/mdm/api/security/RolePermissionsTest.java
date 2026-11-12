package com.mdm.api.security;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/** The Phase 1 role → permission matrix (Phase 1 LLD §3.1, CONSISTENCY_REVIEW §4). */
class RolePermissionsTest {

    @Test
    void everyRoleCanRead() {
        for (String role : new String[] {"VIEWER", "STEWARD", "APPROVER", "WORKFLOW_ADMIN", "POLICY_ADMIN", "SYSTEM_ADMIN", "VERSION_ADMIN"}) {
            assertThat(RolePermissions.allows(role, Permission.READ)).as(role).isTrue();
        }
    }

    @Test
    void onlyStewardsPropose() {
        assertThat(RolePermissions.allows("STEWARD", Permission.PROPOSE)).isTrue();
        assertThat(RolePermissions.allows("VIEWER", Permission.PROPOSE)).isFalse();
        assertThat(RolePermissions.allows("APPROVER", Permission.PROPOSE)).isFalse();
        assertThat(RolePermissions.allows("SYSTEM_ADMIN", Permission.PROPOSE)).isFalse();
    }

    @Test
    void onlyApproversDecide() {
        assertThat(RolePermissions.allows("APPROVER", Permission.DECIDE)).isTrue();
        assertThat(RolePermissions.allows("STEWARD", Permission.DECIDE)).isFalse();
        assertThat(RolePermissions.allows("SYSTEM_ADMIN", Permission.DECIDE)).isFalse();
    }

    @Test
    void adminRolesHaveOnlyTheirAdminPermission() {
        assertThat(RolePermissions.allows("WORKFLOW_ADMIN", Permission.ADMIN_WORKFLOW)).isTrue();
        assertThat(RolePermissions.allows("POLICY_ADMIN", Permission.ADMIN_POLICY)).isTrue();
        assertThat(RolePermissions.allows("SYSTEM_ADMIN", Permission.ADMIN_SYSTEM)).isTrue();
        assertThat(RolePermissions.allows("WORKFLOW_ADMIN", Permission.ADMIN_SYSTEM)).isFalse();
        assertThat(RolePermissions.allows("VERSION_ADMIN", Permission.ADMIN_VERSION)).isTrue();
        assertThat(RolePermissions.allows("VERSION_ADMIN", Permission.PROPOSE)).isFalse();
        assertThat(RolePermissions.allows("SYSTEM_ADMIN", Permission.ADMIN_VERSION)).isFalse();
    }

    @Test
    void unknownRolesAllowNothing() {
        assertThat(RolePermissions.allows("ROOT", Permission.READ)).isFalse();
    }
}
