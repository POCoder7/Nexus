package com.mdm.api.security;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * One current role grant: all hierarchies (hierarchyId null), one hierarchy, or one sub-tree (topNodeId set).
 * {@code categoryCodes}: the property categories it covers for property edits (ADR-036); null = every category.
 * {@code sourceGroup}: the group it comes from (the group's role × one of its scopes, ADR-042 D2); null for a direct grant.
 */
public record Grant(String roleCode, UUID hierarchyId, String hierarchyCode, UUID topNodeId, LocalDate validFrom, LocalDate validTo,
                    List<String> categoryCodes, String sourceGroup) {

    public boolean allHierarchies() {
        return hierarchyId == null;
    }

    public boolean wholeHierarchy() {
        return topNodeId == null;
    }

    /** True if this grant may edit properties of the category (a property without a category needs an unlimited grant). */
    public boolean coversCategory(String categoryCode) {
        return categoryCodes == null || (categoryCode != null && categoryCodes.contains(categoryCode));
    }
}
