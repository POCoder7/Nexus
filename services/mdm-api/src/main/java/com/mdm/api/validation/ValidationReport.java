package com.mdm.api.validation;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

/** Result of {@code mdm.validate_change_request} (Phase 1 LLD §3.5). Info findings are reported with the warnings. */
public record ValidationReport(Instant validatedAt, List<Finding> errors, List<Finding> warnings) {

    public record Finding(String ruleCode, UUID nodeId, UUID hierarchyId, String message) {
    }

    public boolean hasErrors() {
        return !errors.isEmpty();
    }
}
