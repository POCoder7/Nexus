package com.mdm.api.workflow;

import com.mdm.api.changerequest.ChangeRequestDtos.ItemCommand;
import com.mdm.api.changerequest.ChangeRequestDtos.ItemView;
import com.mdm.api.changerequest.ChangeRequestService;
import com.mdm.api.common.NotFoundException;
import com.mdm.api.security.Actor;
import com.mdm.api.workflow.InstanceQuery.InstanceView;
import com.mdm.api.workflow.decision.StageService;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.net.URI;
import java.util.Map;
import java.util.UUID;

/**
 * Workflow endpoints (Phase 2 LLD §5.1, GOV-02): the instance view, stage decisions, claims and enrichment items.
 * Refusals by the database guards come back as 403 with a code and a sentence that says why.
 */
@RestController
@RequestMapping("/api/v1/workflow")
public class WorkflowController {

    public record DecisionBody(String decision, String comment) {
    }

    public record DecisionResult(String stageOutcome) {
    }

    private final StageService stages;
    private final InstanceQuery instances;
    private final ChangeRequestService changeRequests;

    public WorkflowController(StageService stages, InstanceQuery instances, ChangeRequestService changeRequests) {
        this.stages = stages;
        this.instances = instances;
        this.changeRequests = changeRequests;
    }

    /** The instance with its stages, decisions and policy evaluations; visible to whoever can see the request. */
    @GetMapping("/instances/{instanceId}")
    public InstanceView getWorkflowInstance(Actor actor, @PathVariable UUID instanceId) {
        UUID cr = instances.changeRequestOf(instanceId).orElseThrow(() -> notFound(instanceId));
        changeRequests.get(actor, cr);   // 404 when the actor cannot see the request
        return instances.find(instanceId, actor).orElseThrow(() -> notFound(instanceId));
    }

    @PostMapping("/stages/{stageId}/decision")
    public DecisionResult decideStage(Actor actor, @PathVariable UUID stageId, @RequestBody(required = false) DecisionBody body) {
        return new DecisionResult(stages.decide(actor, stageId, body == null ? null : body.decision(), body == null ? null : body.comment()));
    }

    @PostMapping("/stages/{stageId}/claim")
    public ResponseEntity<Void> claimStage(Actor actor, @PathVariable UUID stageId,
                                      @RequestBody(required = false) Map<String, Object> ignored) {
        stages.claim(actor, stageId);
        return ResponseEntity.noContent().build();
    }

    @DeleteMapping("/stages/{stageId}/claim")
    public ResponseEntity<Void> unclaimStage(Actor actor, @PathVariable UUID stageId) {
        stages.unclaim(actor, stageId);
        return ResponseEntity.noContent().build();
    }

    @PostMapping("/stages/{stageId}/items")
    public ResponseEntity<ItemView> addEnrichmentItem(Actor actor, @PathVariable UUID stageId, @RequestBody ItemCommand body) {
        ItemView item = stages.addItem(actor, stageId, body);
        return ResponseEntity.status(HttpStatus.CREATED).location(URI.create("/api/v1/workflow/stages/" + stageId + "/items/" + item.id()))
                .body(item);
    }

    private static NotFoundException notFound(UUID id) {
        return new NotFoundException("Workflow instance " + id + " not found");
    }
}
