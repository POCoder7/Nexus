package com.mdm.api.common;

import java.util.List;

/** The paging envelope for every list (ADR-015): items plus an opaque cursor for the next page, null on the last page. */
public record Page<T>(List<T> items, String nextCursor) {

    /** Builds a page from {@code limit + 1} fetched rows: the extra row only signals that there is a next page. */
    public static <T> Page<T> of(List<T> fetched, int limit, java.util.function.Function<T, String> cursorOf) {
        if (fetched.size() <= limit) {
            return new Page<>(fetched, null);
        }
        List<T> items = fetched.subList(0, limit);
        return new Page<>(List.copyOf(items), cursorOf.apply(items.get(limit - 1)));
    }
}
