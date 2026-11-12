package com.mdm.api.hierarchy;

import java.math.BigDecimal;
import java.util.UUID;

/** One child row for lazy, paged tree loading (the UI virtualises large sibling sets). */
public record ChildNode(
        UUID nodeId,
        String name,
        String description,
        boolean active,
        boolean primary,
        BigDecimal sortOrder,
        boolean hasChildren) {
}
