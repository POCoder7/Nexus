package com.mdm.api.security;

import java.util.EnumSet;
import java.util.Map;
import java.util.Set;

/**
 * The single role → permission matrix (ADR-022). Roles are rows in {@code mdm.role}; what each may do is code,
 * so a data change cannot widen a role. Maker-checker and separation of duties are not here: they are database guards.
 */
public final class RolePermissions {

    private static final Map<String, Set<Permission>> MATRIX = Map.of(
            "VIEWER",         EnumSet.of(Permission.READ),
            "STEWARD",        EnumSet.of(Permission.READ, Permission.PROPOSE),
            "APPROVER",       EnumSet.of(Permission.READ, Permission.DECIDE),
            "WORKFLOW_ADMIN", EnumSet.of(Permission.READ, Permission.ADMIN_WORKFLOW),
            "POLICY_ADMIN",   EnumSet.of(Permission.READ, Permission.ADMIN_POLICY),
            "SYSTEM_ADMIN",   EnumSet.of(Permission.READ, Permission.ADMIN_SYSTEM),
            "VERSION_ADMIN",  EnumSet.of(Permission.READ, Permission.ADMIN_VERSION));

    private RolePermissions() {
    }

    public static boolean allows(String roleCode, Permission permission) {
        return MATRIX.getOrDefault(roleCode, Set.of()).contains(permission);
    }

    public static Set<String> rolesWith(Permission permission) {
        return MATRIX.entrySet().stream().filter(e -> e.getValue().contains(permission)).map(Map.Entry::getKey)
                .collect(java.util.stream.Collectors.toUnmodifiableSet());
    }
}
