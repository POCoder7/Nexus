package com.mdm.api.common;

import java.util.List;
import java.util.Map;

/** A request body failed validation at the API boundary (400 with field errors, overview §9). */
public class ItemValidationException extends RuntimeException {

    private final List<Map<String, String>> errors;

    public ItemValidationException(String message, List<Map<String, String>> errors) {
        super(message);
        this.errors = List.copyOf(errors);
    }

    public static ItemValidationException field(String field, String message) {
        return new ItemValidationException("The item is not valid: " + message, List.of(Map.of("field", field, "message", message)));
    }

    public List<Map<String, String>> errors() {
        return errors;
    }
}
