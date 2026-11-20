package com.mdm.api.validation;

import com.mdm.api.common.NotFoundException;
import com.mdm.api.hierarchy.HierarchyRepository;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/**
 * The rules a hierarchy's nodes are checked against, in words, for anyone who can read the hierarchy (owner, 2026-11-20:
 * show the hierarchy's rules while adding a child). Active node and hierarchy rules of the catalogue (ADR-046 D5) that
 * apply to every hierarchy or to this one; guards are not listed (they refuse a change outright, with their own
 * message). Descriptions only: the rule SQL stays with administrators (/admin/validation-rules). Bounded: the catalogue
 * is small, and at most 200 rules are listed.
 */
@RestController
public class HierarchyRulesController {

    public record HierarchyRule(String code, String name, String description, String severity, boolean thisHierarchyOnly) {
    }

    private final JdbcClient jdbc;
    private final HierarchyRepository hierarchies;
    private final EntitlementService entitlements;

    public HierarchyRulesController(JdbcClient jdbc, HierarchyRepository hierarchies, EntitlementService entitlements) {
        this.jdbc = jdbc;
        this.hierarchies = hierarchies;
        this.entitlements = entitlements;
    }

    @GetMapping("/api/v1/hierarchies/{code}/rules")
    public List<HierarchyRule> listHierarchyRules(Actor actor, @PathVariable String code) {
        UUID hierarchyId = hierarchies.findIdByCode(code).filter(id -> entitlements.canRead(actor, id))
                .orElseThrow(() -> new NotFoundException("Hierarchy " + code + " not found"));
        return jdbc.sql("""
                SELECT r.rule_code, r.rule_name, r.description, r.severity::text AS severity, r.hierarchy_id IS NOT NULL AS own
                FROM mdm.validation_rule r
                WHERE r.is_active AND r.enforcement = 'rule' AND r.level::text IN ('node', 'hierarchy')
                  AND (r.hierarchy_id IS NULL OR r.hierarchy_id = :h)
                ORDER BY r.severity::text, r.rule_code
                LIMIT 200
                """).param("h", hierarchyId)
                .query((rs, i) -> new HierarchyRule(rs.getString("rule_code"), rs.getString("rule_name"), rs.getString("description"),
                        rs.getString("severity"), rs.getBoolean("own")))
                .list();
    }
}
