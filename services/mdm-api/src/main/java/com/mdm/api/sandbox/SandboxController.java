package com.mdm.api.sandbox;

import com.mdm.api.changerequest.ChangeRequestDtos.ItemCommand;
import com.mdm.api.changerequest.ChangeRequestDtos.ItemView;
import com.mdm.api.common.Cursors;
import com.mdm.api.common.ETags;
import com.mdm.api.common.Page;
import com.mdm.api.common.Problems;
import com.mdm.api.sandbox.SandboxDtos.Conflict;
import com.mdm.api.sandbox.SandboxDtos.CreateSandbox;
import com.mdm.api.sandbox.SandboxDtos.DiffRow;
import com.mdm.api.sandbox.SandboxDtos.RefreshResult;
import com.mdm.api.sandbox.SandboxDtos.SandboxChild;
import com.mdm.api.sandbox.SandboxDtos.SandboxItemAdded;
import com.mdm.api.sandbox.SandboxDtos.SandboxNode;
import com.mdm.api.sandbox.SandboxDtos.SandboxView;
import com.mdm.api.sandbox.SandboxDtos.SubmitSandbox;
import com.mdm.api.security.Actor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ProblemDetail;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.net.URI;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Sandboxes (NEW-08; Phase 5 LLD §5): private drafts with an overlay showing what applying them would do. */
@RestController
@RequestMapping("/api/v1/sandboxes")
public class SandboxController {

    private final SandboxService service;
    private final Cursors cursors;

    public SandboxController(SandboxService service, Cursors cursors) {
        this.service = service;
        this.cursors = cursors;
    }

    @PostMapping
    public ResponseEntity<SandboxView> createSandbox(Actor actor, @RequestBody CreateSandbox body) {
        SandboxView s = service.create(actor, body);
        return ResponseEntity.created(URI.create("/api/v1/sandboxes/" + s.id())).eTag(ETags.of(s.rowVersion())).body(s);
    }

    /** The caller's own sandboxes in a status (default {@code draft}, the open ones), newest first. */
    @GetMapping
    public Page<SandboxView> listSandboxes(Actor actor,
                                           @RequestParam(required = false) String status,
                                           @RequestParam(defaultValue = "50") int limit,
                                           @RequestParam(required = false) String cursor) {
        cursors.checkLimit(limit);
        List<String> after = cursors.decode(cursor, 2);
        List<SandboxView> rows = service.mine(actor, status, after == null ? null : Instant.parse(after.get(0)),
                after == null ? null : UUID.fromString(after.get(1)), limit);
        return Page.of(rows, limit, s -> cursors.encode(s.createdAt().toString(), s.id().toString()));
    }

    @GetMapping("/{id}")
    public ResponseEntity<SandboxView> getSandbox(Actor actor, @PathVariable UUID id) {
        SandboxView s = service.get(actor, id);
        return ResponseEntity.ok().eTag(ETags.of(s.rowVersion())).body(s);
    }

    /** Adds an item (the Phase 1 item payloads) and refreshes the overlay; failing items are listed, not refused. */
    @PostMapping("/{id}/items")
    public ResponseEntity<SandboxItemAdded> addSandboxItem(Actor actor, @PathVariable UUID id,
                                                           @RequestHeader(value = HttpHeaders.IF_MATCH, required = false) String ifMatch,
                                                           @RequestBody ItemCommand body) {
        SandboxItemAdded added = service.addItem(actor, id, ifMatch, body);
        return ResponseEntity.status(HttpStatus.CREATED)
                .location(URI.create("/api/v1/sandboxes/" + id + "/items/" + added.item().id()))
                .eTag(ETags.of(added.rowVersion())).body(added);
    }

    @GetMapping("/{id}/items")
    public Page<ItemView> listSandboxItems(Actor actor, @PathVariable UUID id,
                                           @RequestParam(defaultValue = "200") int limit,
                                           @RequestParam(required = false) String cursor) {
        cursors.checkLimit(limit);
        List<String> after = cursors.decode(cursor, 1);
        return Page.of(service.items(actor, id, after == null ? 0 : Integer.parseInt(after.get(0)), limit), limit,
                i -> cursors.encode(String.valueOf(i.seq())));
    }

    @DeleteMapping("/{id}/items/{itemId}")
    public ResponseEntity<RefreshResult> deleteSandboxItem(Actor actor, @PathVariable UUID id, @PathVariable UUID itemId,
                                                           @RequestHeader(value = HttpHeaders.IF_MATCH, required = false) String ifMatch) {
        RefreshResult r = service.deleteItem(actor, id, itemId, ifMatch);
        return ResponseEntity.ok().eTag(ETags.of(r.rowVersion())).body(r);
    }

    /** The overlay's children of a parent. {@code asOf} defaults to the sandbox's effective date. */
    @GetMapping("/{id}/hierarchies/{code}/children")
    public Page<SandboxChild> listSandboxChildren(
            Actor actor, @PathVariable UUID id, @PathVariable String code, @RequestParam UUID parentId,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf,
            @RequestParam(defaultValue = "200") int limit,
            @RequestParam(required = false) String cursor) {
        cursors.checkLimit(limit);
        return Page.of(service.children(actor, id, code, parentId, asOf, cursors.decode(cursor, 3), limit), limit,
                c -> cursors.encode(c.sortOrder().toPlainString(), c.name() == null ? "" : c.name(), c.nodeId().toString()));
    }

    /** Node detail in the overlay; with {@code hierarchy}, its placements and local properties too. */
    @GetMapping("/{id}/nodes/{nodeId}")
    public SandboxNode getSandboxNode(
            Actor actor, @PathVariable UUID id, @PathVariable UUID nodeId,
            @RequestParam(required = false) String hierarchy,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf) {
        return service.node(actor, id, nodeId, hierarchy, asOf);
    }

    /** What the sandbox changes, fact by fact: each replaced row (before) and each row it writes (after). */
    @GetMapping("/{id}/diff")
    public Page<DiffRow> listSandboxDiff(Actor actor, @PathVariable UUID id,
                                         @RequestParam(defaultValue = "200") int limit,
                                         @RequestParam(required = false) String cursor) {
        cursors.checkLimit(limit);
        List<String> after = cursors.decode(cursor, 1);
        Page<SandboxRepository.KeyedDiff> page = Page.of(service.diff(actor, id, after == null ? null : after.get(0), limit),
                limit, d -> cursors.encode(d.key()));
        return new Page<>(page.items().stream().map(SandboxRepository.KeyedDiff::row).toList(), page.nextCursor());
    }

    /** Items whose expected base no longer holds (owner only), in item order. */
    @GetMapping("/{id}/conflicts")
    public Page<Conflict> listSandboxConflicts(Actor actor, @PathVariable UUID id,
                                               @RequestParam(defaultValue = "200") int limit,
                                               @RequestParam(required = false) String cursor) {
        cursors.checkLimit(limit);
        List<String> after = cursors.decode(cursor, 1);
        int afterSeq = after == null ? 0 : Integer.parseInt(after.get(0));
        List<Conflict> rows = service.conflicts(actor, id).stream().filter(c -> c.seq() > afterSeq).limit(limit + 1L).toList();
        return Page.of(rows, limit, c -> cursors.encode(String.valueOf(c.seq())));
    }

    /** Moves the base to now and refreshes; conflicting items stay listed until the owner changes them. */
    @PostMapping("/{id}/rebase")
    public ResponseEntity<RefreshResult> rebaseSandbox(Actor actor, @PathVariable UUID id,
                                                       @RequestHeader(value = HttpHeaders.IF_MATCH, required = false) String ifMatch) {
        RefreshResult r = service.rebase(actor, id, ifMatch);
        return ResponseEntity.ok().eTag(ETags.of(r.rowVersion())).body(r);
    }

    /**
     * Submit: 200 with the request the sandbox became; 422 {@code sandbox.has_conflicts} with the conflicts, or 422
     * {@code change_request.validation_failed} with the findings. In both refusals it stays a sandbox.
     */
    @PostMapping("/{id}/submit")
    public ResponseEntity<?> submitSandbox(Actor actor, @PathVariable UUID id,
                                           @RequestHeader(value = HttpHeaders.IF_MATCH, required = false) String ifMatch,
                                           @RequestBody(required = false) SubmitSandbox body) {
        SandboxService.SubmitOutcome outcome = service.submit(actor, id, ifMatch, body == null ? null : body.workflowModelCode());
        if (outcome.request() != null) {
            return ResponseEntity.ok().eTag(ETags.of(outcome.request().rowVersion())).body(outcome.request());
        }
        ProblemDetail p;
        if (!outcome.conflicts().isEmpty()) {
            p = Problems.of(HttpStatus.UNPROCESSABLE_ENTITY, Problems.RULE_VIOLATION,
                    "Other changes were made to what this sandbox changes. Rebase it, or change the conflicting items, and submit again.");
            p.setProperty("code", "sandbox.has_conflicts");
            p.setProperty("sqlState", "N2301");
            p.setProperty("conflicts", outcome.conflicts());
        } else {
            p = Problems.of(HttpStatus.UNPROCESSABLE_ENTITY, Problems.VALIDATION_FAILED,
                    "The sandbox has validation errors and stays a sandbox. Fix them and submit again.");
            p.setProperty("code", "change_request.validation_failed");
            p.setProperty("errors", outcome.report().errors());
            p.setProperty("warnings", outcome.report().warnings());
        }
        return ResponseEntity.unprocessableEntity().contentType(MediaType.APPLICATION_PROBLEM_JSON).body(p);
    }

    @PostMapping("/{id}/discard")
    public ResponseEntity<SandboxView> discardSandbox(Actor actor, @PathVariable UUID id,
                                                      @RequestHeader(value = HttpHeaders.IF_MATCH, required = false) String ifMatch) {
        SandboxView s = service.discard(actor, id, ifMatch);
        return ResponseEntity.ok().eTag(ETags.of(s.rowVersion())).body(s);
    }
}
