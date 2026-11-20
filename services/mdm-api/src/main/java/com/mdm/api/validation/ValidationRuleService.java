package com.mdm.api.validation;

import com.mdm.api.common.ItemValidationException;
import com.mdm.api.common.NotFoundException;
import com.mdm.api.security.Actor;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Set;

/**
 * The one rule catalogue (ADR-046 D5, Phase 4 LLD §17.5): configured rules and the database guards in
 * mdm.validation_rule. An ADMIN edits a configured rule; a guard row can only be relabelled, which the database itself
 * enforces (trg_validation_rule_guard, N2811), so this class does not repeat that rule. Every edit is audited with the
 * ADMIN as actor.
 */
@Service
public class ValidationRuleService {

    private static final Set<String> SEVERITIES = Set.of("error", "warning", "info");
    private static final Set<String> MODES = Set.of("real_time", "import", "both");

    /** A catalogue row. {@code guardCode} names the guard (SQLSTATE or constraint) for {@code enforcement = guard}. */
    public record ValidationRuleView(String code, String name, String description, String externalCode, String level,
                                     String severity, String mode, String enforcement, String guardCode, String engine,
                                     String expression, String hierarchyCode, boolean active, int version) {
    }

    /** {@code PATCH} body: every field is optional; {@code hierarchyCode} "" clears it (the rule applies everywhere). */
    public record ValidationRuleEdit(String name, String description, String externalCode, Boolean active, String severity,
                                     String mode, String expression, String hierarchyCode) {
    }

    private static final String SELECT = """
            SELECT vr.rule_code, vr.rule_name, vr.description, vr.external_code, vr.level::text AS level,
                   vr.severity::text AS severity, vr.mode, vr.enforcement, vr.guard_code, vr.engine, vr.expression,
                   h.hierarchy_code, vr.is_active, vr.rule_version
            FROM mdm.validation_rule vr LEFT JOIN mdm.hierarchy h ON h.hierarchy_id = vr.hierarchy_id
            """;

    private static final RowMapper<ValidationRuleView> ROW = (rs, i) -> new ValidationRuleView(rs.getString("rule_code"),
            rs.getString("rule_name"), rs.getString("description"), rs.getString("external_code"), rs.getString("level"),
            rs.getString("severity"), rs.getString("mode"), rs.getString("enforcement"), rs.getString("guard_code"),
            rs.getString("engine"), rs.getString("expression"), rs.getString("hierarchy_code"), rs.getBoolean("is_active"),
            rs.getInt("rule_version"));

    private final JdbcClient jdbc;

    public ValidationRuleService(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    /** One keyset page by rule code ({@code limit + 1} rows), optionally of one enforcement. */
    public List<ValidationRuleView> page(String enforcement, String afterCode, int limit) {
        return jdbc.sql(SELECT + """
                WHERE (CAST(:enf AS text) IS NULL OR vr.enforcement = CAST(:enf AS text))
                  AND (CAST(:after AS text) IS NULL OR vr.rule_code COLLATE "C" > CAST(:after AS text) COLLATE "C")
                ORDER BY vr.rule_code COLLATE "C" LIMIT :limit
                """).param("enf", enforcement).param("after", afterCode).param("limit", limit + 1).query(ROW).list();
    }

    @Transactional
    public ValidationRuleView edit(Actor actor, String code, ValidationRuleEdit e) {
        ValidationRuleView current = jdbc.sql(SELECT + " WHERE vr.rule_code = :c FOR UPDATE OF vr").param("c", code)
                .query(ROW).optional().orElseThrow(() -> new NotFoundException("Validation rule " + code + " not found"));
        if (e.severity() != null && !SEVERITIES.contains(e.severity())) {
            throw ItemValidationException.field("severity", "must be one of error, warning, info");
        }
        if (e.mode() != null && !MODES.contains(e.mode())) {
            throw ItemValidationException.field("mode", "must be one of real_time, import, both");
        }
        if (e.expression() != null && e.expression().isBlank()) {
            throw ItemValidationException.field("expression", "must not be blank");
        }
        String hierarchyCode = e.hierarchyCode() == null ? current.hierarchyCode()
                : e.hierarchyCode().isBlank() ? null : e.hierarchyCode();
        if (hierarchyCode != null && jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = :h")
                .param("h", hierarchyCode).query(Integer.class).single() == 0) {
            throw ItemValidationException.field("hierarchyCode", "no hierarchy " + hierarchyCode);
        }
        boolean newExpression = e.expression() != null && !e.expression().equals(current.expression());
        jdbc.sql("SELECT set_config('mdm.actor_id', :a, true)").param("a", actor.userId().toString()).query(String.class).single();
        jdbc.sql("""
                UPDATE mdm.validation_rule SET
                  rule_name = :name, description = :description, external_code = :ext, is_active = :active,
                  severity = CAST(:severity AS mdm.validation_severity), mode = :mode, expression = :expression,
                  hierarchy_id = (SELECT hierarchy_id FROM mdm.hierarchy WHERE hierarchy_code = CAST(:h AS text)),
                  rule_version = rule_version + CASE WHEN :bump THEN 1 ELSE 0 END
                WHERE rule_code = :code
                """)
                .param("name", pick(e.name(), current.name()))
                .param("description", pick(e.description(), current.description()))
                .param("ext", e.externalCode() == null ? current.externalCode() : e.externalCode().isBlank() ? null : e.externalCode())
                .param("active", e.active() == null ? current.active() : e.active())
                .param("severity", pick(e.severity(), current.severity()))
                .param("mode", pick(e.mode(), current.mode()))
                .param("expression", pick(e.expression(), current.expression()))
                .param("h", hierarchyCode)
                .param("bump", newExpression)
                .param("code", code)
                .update();
        return jdbc.sql(SELECT + " WHERE vr.rule_code = :c").param("c", code).query(ROW).single();
    }

    private static String pick(String value, String fallback) {
        return value == null ? fallback : value;
    }
}
