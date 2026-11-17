package com.mdm.api.security;

import java.util.EnumSet;
import java.util.Map;
import java.util.Set;

/**
 * The single role → permission matrix (ADR-022, roles as in ADR-042 D1). Roles are rows in {@code mdm.role}; what each
 * may do is code, so a data change cannot widen a role. Maker-checker and separation of duties are not here: they are
 * database guards, and they bind an ADMIN as much as anyone (two ADMINs satisfy the two-person rules).
 */
public final class RolePermissions {

    private static final Map<String, Set<Permission>> MATRIX = Map.of(
            "VIEWER",   EnumSet.of(Permission.READ),
            "EDITOR",   EnumSet.of(Permission.READ, Permission.PROPOSE),
            "APPROVER", EnumSet.of(Permission.READ, Permission.DECIDE),
            "ADMIN",    EnumSet.complementOf(EnumSet.of(Permission.READ_PUBLISHED)),
            // Service accounts: no READ, so every endpoint but GET /me refuses them until Phase 8 (LLD §19.6)
            "CONSUMER", EnumSet.of(Permission.READ_PUBLISHED));

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
