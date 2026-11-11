package com.mdm.api.node;

import com.fasterxml.jackson.databind.JsonNode;

import java.util.UUID;

/**
 * A resolved property value as of the requested slice, with its provenance (D-18):
 * {@code stored}, {@code inherited} (then {@code sourceNodeId} is the ancestor it came from), {@code derived},
 * {@code default} or {@code none}. A JSON null value with provenance {@code stored} is an explicit blank.
 */
public record PropertyValue(
        String code,
        String label,
        String dataType,
        String scope,
        JsonNode value,
        String provenance,
        UUID sourceNodeId,
        String category) {
}
