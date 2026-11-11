package com.mdm.api.node;

import com.fasterxml.jackson.databind.JsonNode;

/** A resolved property value: stored, inherited or default, as of the requested date. */
public record PropertyValue(
        String code,
        String label,
        String dataType,
        String scope,
        JsonNode value) {
}
