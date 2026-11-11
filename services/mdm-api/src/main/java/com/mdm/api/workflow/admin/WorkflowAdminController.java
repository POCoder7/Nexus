package com.mdm.api.workflow.admin;

import com.fasterxml.jackson.databind.JsonNode;
import com.mdm.api.common.Cursors;
import com.mdm.api.common.ItemValidationException;
import com.mdm.api.common.Page;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import com.mdm.api.security.Permission;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.*;

import java.net.URI;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

/**
 * GOV-01 and GOV-12 administration (Phase 2 LLD §5.1): workflow models (load, activate) and commit policies (propose,
 * submit, approve, kill switch). Role pre-checks here; the four-eyes rules, membership and limits are database guards
 * (N1014 self-activation, N1001 self-approval, N1020 approver not in POLICY_APPROVERS, N2225 activation not allowed).
 */
@RestController
@RequestMapping("/api/v1/admin")
public class WorkflowAdminController {

    public record ModelSummary(UUID modelId, String code, int version, String label, String status, UUID createdBy,
                               UUID activatedBy, Instant activatedAt) {
    }

    public record PolicySummary(UUID policyId, String code, int version, String mode, String status, boolean killSwitch,
                                UUID proposedBy, UUID approvedBy, java.time.LocalDate reviewDue) {
    }

    public record ProposePolicy(String code, String description, String rationale, String mode, List<String> allowedActions,
                                JsonNode itemConditions, Integer maxItemsPerRequest, Integer maxAutoCommitsPerDay,
                                String ownerGroupCode, List<String> modelCodes) {
    }

    public record ApprovePolicy(String note, Integer reviewMonths) {
    }

    public record KillSwitch(String reason) {
    }

    public record Created(UUID id) {
    }

    private final ModelDefinitionLoader models;
    private final EntitlementService entitlements;
    private final JdbcClient jdbc;
    private final Cursors cursors;

    public WorkflowAdminController(ModelDefinitionLoader models, EntitlementService entitlements, JdbcClient jdbc, Cursors cursors) {
        this.models = models;
        this.entitlements = entitlements;
        this.jdbc = jdbc;
        this.cursors = cursors;
    }

    // ------------------------------------------------------------------ models (GOV-01)

    @GetMapping("/workflow-models")
    public Page<ModelSummary> listWorkflowModels(Actor actor, @RequestParam(defaultValue = "100") int limit,
                                                 @RequestParam(required = false) String cursor) {
        entitlements.require(actor, Permission.ADMIN_WORKFLOW, null, null);
        cursors.checkLimit(limit);
        List<String> after = cursors.decode(cursor, 2);
        List<ModelSummary> rows = jdbc.sql("""
                SELECT model_id, model_code, model_version, label, status, created_by, activated_by, activated_at
                FROM wf.workflow_model
                WHERE CAST(:c AS text) IS NULL OR (model_code, model_version) > (CAST(:c AS text), CAST(:v AS int))
                ORDER BY model_code, model_version LIMIT :limit
                """).param("c", after == null ? null : after.get(0)).param("v", after == null ? null : Integer.valueOf(after.get(1)))
                .param("limit", limit + 1)
                .query((rs, i) -> new ModelSummary(rs.getObject(1, UUID.class), rs.getString(2), rs.getInt(3), rs.getString(4),
                        rs.getString(5), rs.getObject(6, UUID.class), rs.getObject(7, UUID.class), instant(rs.getTimestamp(8))))
                .list();
        return Page.of(rows, limit, m -> cursors.encode(m.code(), String.valueOf(m.version())));
    }

    /** Loads a definition (the JSON body) as the next draft version. */
    @PostMapping("/workflow-models")
    public ResponseEntity<Created> loadWorkflowModel(Actor actor, @RequestBody JsonNode definition) {
        entitlements.require(actor, Permission.ADMIN_WORKFLOW, null, null);
        UUID id = models.load(definition, actor);
        return ResponseEntity.created(URI.create("/api/v1/admin/workflow-models/" + id)).body(new Created(id));
    }

    @PostMapping("/workflow-models/{modelId}/activate")
    public ResponseEntity<Void> activateWorkflowModel(Actor actor, @PathVariable UUID modelId) {
        entitlements.require(actor, Permission.ADMIN_WORKFLOW, null, null);
        models.activate(modelId, actor);
        return ResponseEntity.noContent().build();
    }

    // ------------------------------------------------------------------ commit policies (GOV-12)

    @GetMapping("/commit-policies")
    public Page<PolicySummary> listCommitPolicies(Actor actor, @RequestParam(defaultValue = "100") int limit,
                                                  @RequestParam(required = false) String cursor) {
        if (!entitlements.hasAny(actor, Permission.ADMIN_POLICY) && !entitlements.hasAny(actor, Permission.DECIDE)) {
            entitlements.require(actor, Permission.ADMIN_POLICY, null, null);   // 403 with the usual explanation
        }
        cursors.checkLimit(limit);
        List<String> after = cursors.decode(cursor, 2);
        List<PolicySummary> rows = jdbc.sql("""
                SELECT policy_id, policy_code, policy_version, mode::text, status::text, kill_switch, proposed_by, approved_by, review_due
                FROM wf.commit_policy
                WHERE CAST(:c AS text) IS NULL OR (policy_code, policy_version) > (CAST(:c AS text), CAST(:v AS int))
                ORDER BY policy_code, policy_version LIMIT :limit
                """).param("c", after == null ? null : after.get(0)).param("v", after == null ? null : Integer.valueOf(after.get(1)))
                .param("limit", limit + 1)
                .query((rs, i) -> new PolicySummary(rs.getObject(1, UUID.class), rs.getString(2), rs.getInt(3), rs.getString(4),
                        rs.getString(5), rs.getBoolean(6), rs.getObject(7, UUID.class), rs.getObject(8, UUID.class),
                        rs.getObject(9, java.time.LocalDate.class)))
                .list();
        return Page.of(rows, limit, p -> cursors.encode(p.code(), String.valueOf(p.version())));
    }

    @PostMapping("/commit-policies")
    public ResponseEntity<Created> proposeCommitPolicy(Actor actor, @RequestBody ProposePolicy body) {
        entitlements.require(actor, Permission.ADMIN_POLICY, null, null);
        if (body == null || blank(body.code()) || blank(body.description()) || blank(body.rationale())
                || body.allowedActions() == null || body.allowedActions().isEmpty() || blank(body.ownerGroupCode())) {
            throw ItemValidationException.field("policy", "needs code, description, rationale, allowedActions and ownerGroupCode");
        }
        UUID id = jdbc.sql("""
                SELECT wf.propose_commit_policy(:code, :description, :rationale, CAST(:mode AS wf.policy_mode),
                                                CAST(:actions AS mdm.change_action[]), CAST(:conditions AS jsonb),
                                                :maxItems, :maxPerDay, :owner, CAST(:models AS text[]), :actor)
                """)
                .param("code", body.code()).param("description", body.description()).param("rationale", body.rationale())
                .param("mode", body.mode()).param("actions", "{" + String.join(",", body.allowedActions()) + "}")
                .param("conditions", body.itemConditions() == null ? null : body.itemConditions().toString())
                .param("maxItems", body.maxItemsPerRequest()).param("maxPerDay", body.maxAutoCommitsPerDay())
                .param("owner", body.ownerGroupCode())
                .param("models", "{" + String.join(",", body.modelCodes() == null ? List.of() : body.modelCodes()) + "}")
                .param("actor", actor.userId())
                .query(UUID.class).single();
        return ResponseEntity.status(HttpStatus.CREATED).location(URI.create("/api/v1/admin/commit-policies/" + id)).body(new Created(id));
    }

    @PostMapping("/commit-policies/{policyId}/submit")
    public ResponseEntity<Void> submitCommitPolicy(Actor actor, @PathVariable UUID policyId) {
        entitlements.require(actor, Permission.ADMIN_POLICY, null, null);
        call("SELECT wf.submit_commit_policy(:p, :a)", policyId, actor);   // proposer only (N1022)
        return ResponseEntity.noContent().build();
    }

    /** Approval is for members of POLICY_APPROVERS, checked by the database (no role pre-check). */
    @PostMapping("/commit-policies/{policyId}/approve")
    public ResponseEntity<Void> approveCommitPolicy(Actor actor, @PathVariable UUID policyId,
                                                    @RequestBody(required = false) ApprovePolicy body) {
        jdbc.sql("SELECT wf.approve_commit_policy(:p, :a, :note, :months)")
                .param("p", policyId).param("a", actor.userId()).param("note", body == null ? null : body.note())
                .param("months", body == null || body.reviewMonths() == null ? 12 : body.reviewMonths())
                .query((rs, i) -> 0).single();
        return ResponseEntity.noContent().build();
    }

    /** Anyone in the policy's owner group or in POLICY_APPROVERS can stop it at once (checked by the database). */
    @PostMapping("/commit-policies/{policyCode}/kill-switch")
    public ResponseEntity<Void> engageKillSwitch(Actor actor, @PathVariable String policyCode, @RequestBody(required = false) KillSwitch body) {
        if (body == null || blank(body.reason())) {
            throw ItemValidationException.field("reason", "is required");
        }
        jdbc.sql("SELECT wf.engage_kill_switch(:code, :a, :reason)").param("code", policyCode).param("a", actor.userId())
                .param("reason", body.reason()).query((rs, i) -> 0).single();
        return ResponseEntity.noContent().build();
    }

    private void call(String sql, UUID id, Actor actor) {
        jdbc.sql(sql).param("p", id).param("a", actor.userId()).query((rs, i) -> 0).single();
    }

    private static boolean blank(String s) {
        return s == null || s.isBlank();
    }

    private static Instant instant(Timestamp t) {
        return t == null ? null : t.toInstant();
    }
}
