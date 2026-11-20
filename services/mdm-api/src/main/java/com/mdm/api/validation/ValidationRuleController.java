package com.mdm.api.validation;

import com.mdm.api.common.Cursors;
import com.mdm.api.common.Page;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import com.mdm.api.security.ForbiddenException;
import com.mdm.api.security.Permission;
import com.mdm.api.validation.ValidationRuleService.ValidationRuleEdit;
import com.mdm.api.validation.ValidationRuleService.ValidationRuleView;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Set;

/** The rule catalogue (ADR-046 D5, C-3): ADMIN and APPROVER read it; ADMIN edits rules and relabels guards. */
@RestController
@RequestMapping("/api/v1/admin/validation-rules")
public class ValidationRuleController {

    private static final Set<String> ENFORCEMENTS = Set.of("rule", "guard");

    private final ValidationRuleService rules;
    private final EntitlementService entitlements;
    private final Cursors cursors;

    public ValidationRuleController(ValidationRuleService rules, EntitlementService entitlements, Cursors cursors) {
        this.rules = rules;
        this.entitlements = entitlements;
        this.cursors = cursors;
    }

    @GetMapping
    public Page<ValidationRuleView> listValidationRules(Actor actor, @RequestParam(required = false) String enforcement,
                                                        @RequestParam(defaultValue = "200") int limit,
                                                        @RequestParam(required = false) String cursor) {
        if (!entitlements.hasAny(actor, Permission.ADMIN_SYSTEM) && !entitlements.hasAny(actor, Permission.DECIDE)) {
            throw new ForbiddenException("entitlement.missing", "Only administrators and approvers can see the validation rules.");
        }
        cursors.checkLimit(limit);
        if (enforcement != null && !ENFORCEMENTS.contains(enforcement)) {
            throw new IllegalArgumentException("enforcement must be rule or guard");
        }
        List<String> after = cursors.decode(cursor, 1);
        return Page.of(rules.page(enforcement, after == null ? null : after.get(0), limit), limit, r -> cursors.encode(r.code()));
    }

    /** Edits a rule; a guard row accepts only name, description and external code (else 422, validation_rule.guard_fixed). */
    @PatchMapping("/{code}")
    public ValidationRuleView editValidationRule(Actor actor, @PathVariable String code, @RequestBody ValidationRuleEdit body) {
        if (!entitlements.hasAny(actor, Permission.ADMIN_SYSTEM)) {
            throw new ForbiddenException("entitlement.missing", "Only an administrator can change validation rules.");
        }
        return rules.edit(actor, code, body);
    }
}
