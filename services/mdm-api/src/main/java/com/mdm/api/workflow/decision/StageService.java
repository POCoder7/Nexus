package com.mdm.api.workflow.decision;

import com.mdm.api.changerequest.ChangeRequestDtos.ChangeRequestView;
import com.mdm.api.changerequest.ChangeRequestDtos.ItemCommand;
import com.mdm.api.changerequest.ChangeRequestDtos.ItemView;
import com.mdm.api.changerequest.ChangeRequestRepository;
import com.mdm.api.changerequest.ChangeRequestService;
import com.mdm.api.changerequest.ItemFactory;
import com.mdm.api.common.ItemValidationException;
import com.mdm.api.common.NotFoundException;
import com.mdm.api.common.RuleException;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import com.mdm.api.security.ForbiddenException;
import com.mdm.api.security.Permission;
import com.mdm.api.workflow.WorkflowGateway;
import org.springframework.core.NestedExceptionUtils;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;

import java.sql.SQLException;
import java.util.Set;
import java.util.UUID;

/**
 * Stage decisions, claims and enrichment items (Phase 2 LLD §5.1, GOV-02). The database decides who may act
 * ({@code wf.can_act} and the guards); this service checks the role as a pre-check, calls one guarded function, and when
 * the database refuses, explains why in words ({@code wf.why_cannot_act}).
 *
 * <p>Each call is a single guarded function, run without a surrounding transaction: after PostgreSQL refuses a
 * statement, the transaction it ran in can do nothing more, and the explanation must be read afterwards.
 */
@Service
public class StageService {

    /** Guard codes that mean "this person cannot act here": explained with wf.why_cannot_act. */
    private static final Set<String> CANNOT_ACT = Set.of("N1010", "N1015", "N1016");

    public record StageRef(UUID instanceStageId, UUID instanceId, UUID changeRequestId, String stageType) {
    }

    private final JdbcClient jdbc;
    private final WorkflowGateway workflow;
    private final ChangeRequestService changeRequests;
    private final ChangeRequestRepository requests;
    private final ItemFactory items;
    private final EntitlementService entitlements;

    public StageService(JdbcClient jdbc, WorkflowGateway workflow, ChangeRequestService changeRequests,
                        ChangeRequestRepository requests, ItemFactory items, EntitlementService entitlements) {
        this.jdbc = jdbc;
        this.workflow = workflow;
        this.changeRequests = changeRequests;
        this.requests = requests;
        this.items = items;
        this.entitlements = entitlements;
    }

    public String decide(Actor actor, UUID stageId, String decision, String comment) {
        if (!"approve".equals(decision) && !"reject".equals(decision)) {
            throw ItemValidationException.field("decision", "must be approve or reject");
        }
        StageRef stage = visibleStage(actor, stageId);
        preCheck(actor, stage);
        try {
            return workflow.recordDecision(stageId, actor, decision, comment);
        } catch (DataAccessException e) {
            throw explained(e, stageId, actor);
        }
    }

    public void claim(Actor actor, UUID stageId) {
        StageRef stage = visibleStage(actor, stageId);
        preCheck(actor, stage);
        try {
            workflow.claim(stageId, actor);
        } catch (DataAccessException e) {
            throw explained(e, stageId, actor);
        }
    }

    public void unclaim(Actor actor, UUID stageId) {
        visibleStage(actor, stageId);
        workflow.unclaim(stageId, actor);   // claimant or workflow administrator, checked by the function (N1010)
    }

    /**
     * An enrichment item: built and checked like a draft item (payload, expected values, PROPOSE on its scope), then
     * written through the bridge, which checks the stage and the task. New nodes and hierarchies need an identity that
     * only a draft can allocate, so they are drafted, not enriched.
     */
    public ItemView addItem(Actor actor, UUID stageId, ItemCommand cmd) {
        StageRef stage = visibleStage(actor, stageId);
        if (!"enrich".equals(stage.stageType())) {
            throw new RuleException("enrichment.not_an_enrich_stage", "Items can be added only in an Enrich stage.");
        }
        if (cmd == null || cmd.action() == null) {
            throw ItemValidationException.field("action", "is required");
        }
        if ("add_node".equals(cmd.action()) || "add_hierarchy".equals(cmd.action())) {
            throw new RuleException("enrichment.action_not_supported",
                    "New nodes and hierarchies are added while drafting, not during enrichment.");
        }
        ChangeRequestView cr = changeRequests.get(actor, stage.changeRequestId());
        ItemFactory.NewItem item = items.build(cr, cmd, requests.allItems(cr.id()));
        for (ItemFactory.Scope s : item.scopes()) {
            entitlements.require(actor, Permission.PROPOSE, s.hierarchyId(), s.nodeId(), s.categoryCode(), s.propertyEdit());
        }
        UUID itemId;
        try {
            itemId = workflow.addEnrichmentItem(stageId, actor, item.action(), item.hierarchyId(), item.nodeId(),
                    item.targetParentId(), item.propertyId(), item.payload());
        } catch (DataAccessException e) {
            throw explained(e, stageId, actor);
        }
        return requests.item(itemId).orElseThrow();
    }

    // ------------------------------------------------------------------ helpers

    /** The stage, if the actor can see its request (404 otherwise, so existence is not revealed). */
    public StageRef visibleStage(Actor actor, UUID stageId) {
        StageRef stage = jdbc.sql("""
                SELECT ist.instance_stage_id, ist.instance_id, i.change_request_id, ws.stage_type::text AS stage_type
                FROM wf.instance_stage ist
                JOIN wf.workflow_stage ws   ON ws.stage_id = ist.stage_id
                JOIN wf.workflow_instance i ON i.instance_id = ist.instance_id
                WHERE ist.instance_stage_id = :s
                """).param("s", stageId)
                .query((rs, i) -> new StageRef(rs.getObject(1, UUID.class), rs.getObject(2, UUID.class),
                        rs.getObject(3, UUID.class), rs.getString(4)))
                .optional().orElseThrow(() -> new NotFoundException("Stage " + stageId + " not found"));
        changeRequests.get(actor, stage.changeRequestId());   // 404 when the actor cannot see the request
        return stage;
    }

    /** Role pre-check: approving and committing need DECIDE somewhere, enriching needs PROPOSE; the database decides the rest. */
    private void preCheck(Actor actor, StageRef stage) {
        Permission needed = "enrich".equals(stage.stageType()) ? Permission.PROPOSE : Permission.DECIDE;
        if (!entitlements.hasAny(actor, needed)) {
            throw new ForbiddenException("entitlement.missing", "You don't have a role that can act on " + stage.stageType()
                    + " stages. Ask an administrator.");
        }
    }

    private RuntimeException explained(DataAccessException e, UUID stageId, Actor actor) {
        String state = NestedExceptionUtils.getMostSpecificCause(e) instanceof SQLException sql ? sql.getSQLState() : null;
        if (state != null && CANNOT_ACT.contains(state)) {
            return workflow.whyCannotAct(stageId, actor)
                    .<RuntimeException>map(r -> new ForbiddenException(r.code(), r.message()))
                    .orElse(e);
        }
        return e;
    }
}
