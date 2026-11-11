package com.mdm.api.hierarchy;

import java.util.UUID;

public record HierarchySummary(
        String code,
        String name,
        String purpose,
        String group,
        UUID topNodeId,
        String topNodeName,
        UUID hierarchyId) {
}
