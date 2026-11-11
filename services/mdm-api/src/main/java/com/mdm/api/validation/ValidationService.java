package com.mdm.api.validation;

import com.mdm.api.validation.ValidationReport.Finding;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;

import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * Runs {@code mdm.validate_change_request}: a trial apply of the request plus the active rules, always rolled back
 * (LLD §7.4). Rules are evaluated in SQL only; this class never evaluates them itself. Findings are stored with the
 * request by the database function, so they are kept when the caller's transaction commits.
 */
@Service
public class ValidationService {

    private final JdbcClient jdbc;

    public ValidationService(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    public ValidationReport run(UUID changeRequestId, LocalDate asOf) {
        record Row(String ruleCode, String severity, UUID nodeId, UUID hierarchyId, String message, Instant at) {
        }
        List<Row> rows = jdbc.sql("""
                SELECT rule_code, severity, node_id, hierarchy_id, message, evaluated_at
                FROM mdm.validate_change_request(:cr, :asOf)
                """).param("cr", changeRequestId).param("asOf", asOf)
                .query((rs, i) -> new Row(rs.getString("rule_code"), rs.getString("severity"),
                        rs.getObject("node_id", UUID.class), rs.getObject("hierarchy_id", UUID.class),
                        rs.getString("message"), instant(rs.getTimestamp("evaluated_at"))))
                .list();
        List<Finding> errors = new ArrayList<>();
        List<Finding> warnings = new ArrayList<>();
        Instant at = null;
        for (Row r : rows) {
            at = r.at();
            Finding f = new Finding(r.ruleCode(), r.nodeId(), r.hierarchyId(), r.message());
            if ("error".equals(r.severity())) {
                errors.add(f);
            } else {
                warnings.add(f);
            }
        }
        return new ValidationReport(at == null ? Instant.now() : at, List.copyOf(errors), List.copyOf(warnings));
    }

    private static Instant instant(Timestamp t) {
        return t == null ? null : t.toInstant();
    }
}
