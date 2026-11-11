package com.mdm.api.node;

import java.util.List;
import java.util.UUID;

public record NodeDetail(
        UUID nodeId,
        String kind,
        String name,
        String description,
        boolean active,
        boolean allowsChildren,
        List<PropertyValue> properties) {
}
