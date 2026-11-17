package com.mdm.api.security;

import org.junit.jupiter.api.Test;

import java.util.EnumSet;

import static org.assertj.core.api.Assertions.assertThat;

/** The role → permission matrix (Phase 1 LLD §3.1; the five roles of ADR-042 D1, Phase 5 LLD §19.2). */
class RolePermissionsTest {

    @Test
    void everyHumanRoleCanRead() {
        for (String role : new String[] {"VIEWER", "EDITOR", "APPROVER", "ADMIN"}) {
            assertThat(RolePermissions.allows(role, Permission.READ)).as(role).isTrue();
        }
    }

    @Test
    void editorsAndAdminsPropose() {
        assertThat(RolePermissions.allows("EDITOR", Permission.PROPOSE)).isTrue();
        assertThat(RolePermissions.allows("ADMIN", Permission.PROPOSE)).isTrue();
        assertThat(RolePermissions.allows("VIEWER", Permission.PROPOSE)).isFalse();
        assertThat(RolePermissions.allows("APPROVER", Permission.PROPOSE)).isFalse();
    }

    @Test
    void approversAndAdminsDecide() {
        assertThat(RolePermissions.allows("APPROVER", Permission.DECIDE)).isTrue();
        assertThat(RolePermissions.allows("ADMIN", Permission.DECIDE)).isTrue();
        assertThat(RolePermissions.allows("EDITOR", Permission.DECIDE)).isFalse();
        assertThat(RolePermissions.allows("VIEWER", Permission.DECIDE)).isFalse();
    }

    @Test
    void adminHoldsEveryPermissionButReadPublished() {
        for (Permission p : EnumSet.complementOf(EnumSet.of(Permission.READ_PUBLISHED))) {
            assertThat(RolePermissions.allows("ADMIN", p)).as(p.name()).isTrue();
        }
        assertThat(RolePermissions.allows("ADMIN", Permission.READ_PUBLISHED)).isFalse();
    }

    @Test
    void onlyAdminAdministersOverridesOrPublishes() {
        for (Permission p : EnumSet.of(Permission.ADMIN_WORKFLOW, Permission.ADMIN_POLICY, Permission.ADMIN_SYSTEM,
                Permission.ADMIN_VERSION, Permission.OVERRIDE_WORKFLOW, Permission.PUBLISH)) {
            assertThat(RolePermissions.rolesWith(p)).as(p.name()).containsExactly("ADMIN");
        }
    }

    @Test
    void consumerReadsPublishedOutputOnly() {
        assertThat(RolePermissions.rolesWith(Permission.READ_PUBLISHED)).containsExactly("CONSUMER");
        for (Permission p : EnumSet.complementOf(EnumSet.of(Permission.READ_PUBLISHED))) {
            assertThat(RolePermissions.allows("CONSUMER", p)).as(p.name()).isFalse();
        }
    }

    @Test
    void retiredAndUnknownRolesAllowNothing() {
        for (String role : new String[] {"ROOT", "STEWARD", "WORKFLOW_ADMIN", "POLICY_ADMIN", "SYSTEM_ADMIN", "VERSION_ADMIN"}) {
            for (Permission p : Permission.values()) {
                assertThat(RolePermissions.allows(role, p)).as(role + " " + p).isFalse();
            }
        }
    }
}
