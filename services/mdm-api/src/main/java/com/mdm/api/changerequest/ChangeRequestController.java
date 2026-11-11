package com.mdm.api.changerequest;

import com.mdm.api.apply.ApplyService;
import com.mdm.api.changerequest.ChangeRequestDtos.ChangeRequestView;
import com.mdm.api.changerequest.ChangeRequestDtos.CreateRequest;
import com.mdm.api.changerequest.ChangeRequestDtos.ItemCommand;
import com.mdm.api.changerequest.ChangeRequestDtos.ItemView;
import com.mdm.api.changerequest.ChangeRequestDtos.UpdateRequest;
import com.mdm.api.common.Cursors;
import com.mdm.api.common.ETags;
import com.mdm.api.common.Page;
import com.mdm.api.common.Problems;
import com.mdm.api.security.Actor;
import com.mdm.api.validation.ValidationReport;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ProblemDetail;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.net.URI;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Drafting change requests (HIE-02, PRP-01; Phase 1 LLD §5.2). Submit and decision arrive in increment 1-8. */
@RestController
@RequestMapping("/api/v1/change-requests")
public class ChangeRequestController {

    private final ChangeRequestService service;
    private final ApplyService apply;
    private final Cursors cursors;

    public ChangeRequestController(ChangeRequestService service, ApplyService apply, Cursors cursors) {
        this.service = service;
        this.apply = apply;
        this.cursors = cursors;
    }

    @PostMapping
    public ResponseEntity<ChangeRequestView> createChangeRequest(Actor actor, @RequestBody CreateRequest body) {
        ChangeRequestView cr = service.create(actor, body);
        return ResponseEntity.created(URI.create("/api/v1/change-requests/" + cr.id()))
                .eTag(ETags.of(cr.rowVersion())).body(cr);
    }

    /**
     * {@code mine=true}: the caller's own requests, newest first. {@code mine=false}: the review queue, other people's
     * requests (default status submitted) the caller may decide, oldest first.
     */
    @GetMapping
    public Page<ChangeRequestView> listChangeRequests(Actor actor,
                                        @RequestParam(defaultValue = "true") boolean mine,
                                        @RequestParam(required = false) String status,
                                        @RequestParam(defaultValue = "50") int limit,
                                        @RequestParam(required = false) String cursor) {
        cursors.checkLimit(limit);
        List<String> after = cursors.decode(cursor, 2);
        Instant afterCreated = after == null ? null : Instant.parse(after.get(0));
        UUID afterId = after == null ? null : UUID.fromString(after.get(1));
        List<ChangeRequestView> rows = mine
                ? service.mine(actor, status, afterCreated, afterId, limit)
                : service.queue(actor, status, afterCreated, afterId, limit);
        return Page.of(rows, limit, cr -> cursors.encode(cr.createdAt().toString(), cr.id().toString()));
    }

    @GetMapping("/{id}")
    public ResponseEntity<ChangeRequestView> getChangeRequest(Actor actor, @PathVariable UUID id) {
        ChangeRequestView cr = service.get(actor, id);
        return ResponseEntity.ok().eTag(ETags.of(cr.rowVersion())).body(cr);
    }

    @PatchMapping("/{id}")
    public ResponseEntity<ChangeRequestView> updateChangeRequest(Actor actor, @PathVariable UUID id,
                                                    @RequestHeader(value = HttpHeaders.IF_MATCH, required = false) String ifMatch,
                                                    @RequestBody UpdateRequest body) {
        ChangeRequestView cr = service.update(actor, id, ifMatch, body);
        return ResponseEntity.ok().eTag(ETags.of(cr.rowVersion())).body(cr);
    }

    @PostMapping("/{id}/items")
    public ResponseEntity<ItemView> addChangeRequestItem(Actor actor, @PathVariable UUID id,
                                            @RequestHeader(value = HttpHeaders.IF_MATCH, required = false) String ifMatch,
                                            @RequestBody ItemCommand body) {
        var added = service.addItem(actor, id, ifMatch, body);
        return ResponseEntity.status(HttpStatus.CREATED)
                .location(URI.create("/api/v1/change-requests/" + id + "/items/" + added.item().id()))
                .eTag(ETags.of(added.rowVersion())).body(added.item());
    }

    @GetMapping("/{id}/items")
    public Page<ItemView> listChangeRequestItems(Actor actor, @PathVariable UUID id,
                                @RequestParam(defaultValue = "200") int limit,
                                @RequestParam(required = false) String cursor) {
        cursors.checkLimit(limit);
        List<String> after = cursors.decode(cursor, 1);
        return Page.of(service.items(actor, id, after == null ? 0 : Integer.parseInt(after.get(0)), limit), limit,
                i -> cursors.encode(String.valueOf(i.seq())));
    }

    @DeleteMapping("/{id}/items/{itemId}")
    public ResponseEntity<Void> deleteChangeRequestItem(Actor actor, @PathVariable UUID id, @PathVariable UUID itemId,
                                           @RequestHeader(value = HttpHeaders.IF_MATCH, required = false) String ifMatch) {
        int version = service.deleteItem(actor, id, itemId, ifMatch);
        return ResponseEntity.noContent().eTag(ETags.of(version)).build();
    }

    /** Trial validation: nothing changes except that the findings are stored with the request. */
    @PostMapping("/{id}/validate")
    public ValidationReport validateChangeRequest(Actor actor, @PathVariable UUID id) {
        return service.validate(actor, id);
    }

    /** Validate and submit. 200 with the submitted request, or 422 with the findings (the request stays a draft). */
    @PostMapping("/{id}/submit")
    public ResponseEntity<?> submitChangeRequest(Actor actor, @PathVariable UUID id,
                                    @RequestHeader(value = HttpHeaders.IF_MATCH, required = false) String ifMatch,
                                    @RequestBody(required = false) Map<String, Object> ignored) {
        ChangeRequestService.SubmitOutcome outcome = service.submit(actor, id, ifMatch);
        if (outcome.refused()) {
            ProblemDetail p = Problems.of(HttpStatus.UNPROCESSABLE_ENTITY, Problems.VALIDATION_FAILED,
                    "The change request has validation errors and stays a draft. Fix them and submit again.");
            p.setProperty("code", "change_request.validation_failed");
            p.setProperty("errors", outcome.report().errors());
            p.setProperty("warnings", outcome.report().warnings());
            return ResponseEntity.unprocessableEntity().contentType(MediaType.APPLICATION_PROBLEM_JSON).body(p);
        }
        return ResponseEntity.ok().eTag(ETags.of(outcome.request().rowVersion())).body(outcome.request());
    }

    /**
     * Approve or reject (core mode). An approval is applied straight after the decision commits; the response carries
     * the outcome ({@code applied} or {@code apply_failed} with its reason). A rejection ends the request.
     */
    @PostMapping("/{id}/decision")
    public ResponseEntity<ChangeRequestView> decideChangeRequest(Actor actor, @PathVariable UUID id,
                                                    @RequestHeader(value = HttpHeaders.IF_MATCH, required = false) String ifMatch,
                                                    @RequestBody(required = false) ChangeRequestDtos.DecisionRequest body) {
        ChangeRequestView decided = service.decide(actor, id, ifMatch, body);
        if ("approved".equals(decided.status())) {
            apply.apply(actor.userId(), id);
        }
        ChangeRequestView cr = service.get(actor, id);
        return ResponseEntity.ok().eTag(ETags.of(cr.rowVersion())).body(cr);
    }

    @PostMapping("/{id}/withdraw")
    public ResponseEntity<ChangeRequestView> withdrawChangeRequest(Actor actor, @PathVariable UUID id,
                                                      @RequestHeader(value = HttpHeaders.IF_MATCH, required = false) String ifMatch,
                                                      @RequestBody(required = false) Map<String, Object> ignored) {
        ChangeRequestView cr = service.withdraw(actor, id, ifMatch);
        return ResponseEntity.ok().eTag(ETags.of(cr.rowVersion())).body(cr);
    }
}
