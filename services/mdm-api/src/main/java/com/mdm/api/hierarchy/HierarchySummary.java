package com.mdm.api.hierarchy;

import com.fasterxml.jackson.annotation.JsonIgnore;

import java.util.UUID;

public record HierarchySummary(
        String code,
        String name,
        String purpose,
        String group,
        UUID topNodeId,
        String topNodeName,
        String topNodeDisplayName,   // ADR-046 D1
        String description,         // ADR-046 D8
        UUID hierarchyId,
        @JsonIgnore int sortKey) {
}
