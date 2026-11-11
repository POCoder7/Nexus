package com.mdm.api.common;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.List;

/**
 * Opaque keyset cursors (ADR-015): base64url of a JSON array holding the last row's sort key. Clients must not
 * build or parse them. A malformed cursor is a 400. Also validates {@code limit} against {@code mdm.api.max-page-size}.
 */
@Component
public class Cursors {

    private final ObjectMapper mapper;
    private final int maxPageSize;

    public Cursors(ObjectMapper mapper, @Value("${mdm.api.max-page-size:1000}") int maxPageSize) {
        this.mapper = mapper;
        this.maxPageSize = maxPageSize;
    }

    public String encode(Object... sortKey) {
        try {
            return Base64.getUrlEncoder().withoutPadding().encodeToString(mapper.writeValueAsBytes(sortKey));
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Cannot encode cursor", e);
        }
    }

    /** The decoded sort key as strings, or null when no cursor was given. */
    public List<String> decode(String cursor, int expectedParts) {
        if (cursor == null || cursor.isBlank()) {
            return null;
        }
        try {
            String json = new String(Base64.getUrlDecoder().decode(cursor), StandardCharsets.UTF_8);
            List<String> parts = mapper.readerForListOf(String.class).readValue(json);
            if (parts.size() != expectedParts) {
                throw new IllegalArgumentException("Invalid cursor");
            }
            return parts;
        } catch (IllegalArgumentException | java.io.IOException e) {
            throw new IllegalArgumentException("Invalid cursor");
        }
    }

    public int checkLimit(int limit) {
        if (limit < 1 || limit > maxPageSize) {
            throw new IllegalArgumentException("limit must be between 1 and " + maxPageSize);
        }
        return limit;
    }
}
