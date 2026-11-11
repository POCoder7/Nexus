package com.mdm.api.security;

import java.time.LocalDate;
import java.util.UUID;

/** One current role grant: all hierarchies (hierarchyId null), one hierarchy, or one sub-tree (topNodeId set). */
public record Grant(String roleCode, UUID hierarchyId, String hierarchyCode, UUID topNodeId, LocalDate validFrom, LocalDate validTo) {

    public boolean allHierarchies() {
        return hierarchyId == null;
    }

    public boolean wholeHierarchy() {
        return topNodeId == null;
    }
}
