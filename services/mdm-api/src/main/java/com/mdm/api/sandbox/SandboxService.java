package com.mdm.api.sandbox;

import com.mdm.api.changerequest.ChangeRequestDtos.ChangeRequestView;
import com.mdm.api.changerequest.ChangeRequestDtos.ItemCommand;
import com.mdm.api.changerequest.ChangeRequestDtos.ItemView;
import com.mdm.api.changerequest.ChangeRequestRepository;
import com.mdm.api.changerequest.ChangeRequestService;
import com.mdm.api.common.BusinessClock;
import com.mdm.api.common.ETags;
import com.mdm.api.common.ItemValidationException;
import com.mdm.api.common.NotFoundException;
import com.mdm.api.common.RuleException;
import com.mdm.api.hierarchy.HierarchyRepository;
import com.mdm.api.sandbox.SandboxDtos.Conflict;
import com.mdm.api.sandbox.SandboxDtos.CreateSandbox;
import com.mdm.api.sandbox.SandboxDtos.DiffRow;
import com.mdm.api.sandbox.SandboxDtos.ItemFailure;
import com.mdm.api.sandbox.SandboxDtos.RefreshResult;
import com.mdm.api.sandbox.SandboxDtos.SandboxChild;
import com.mdm.api.sandbox.SandboxDtos.SandboxItemAdded;
import com.mdm.api.sandbox.SandboxDtos.SandboxNode;
import com.mdm.api.sandbox.SandboxDtos.SandboxView;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import com.mdm.api.security.ForbiddenException;
import com.mdm.api.security.Permission;
import com.mdm.api.validation.ValidationReport;
import com.mdm.api.validation.ValidationService;
import io.micrometer.core.instrument.DistributionSummary;
import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * Sandboxes (NEW-08; ADR-028; Phase 5 LLD §3.1, §5, §6). A sandbox is a private draft change request whose overlay shows
 * what applying its items would do. Items follow the Phase 1 rules and each change refreshes the overlay in the same
 * transaction. Submit turns the sandbox into an ordinary request; discard withdraws it. One owner edits; people who may
 * read every hierarchy its items touch may view it (F-1). The database functions re-check ownership and state.
 */
@Service
public class SandboxService {

    private final SandboxRepository repository;
    private final ChangeRequestRepository requests;
    private final ChangeRequestService requestService;
    private final HierarchyRepository hierarchies;
    private final EntitlementService entitlements;
    private final ValidationService validation;
    private final BusinessClock clock;
    private final Timer refreshTimer;
    private final DistributionSummary conflictSummary;

    public SandboxService(SandboxRepository repository, ChangeRequestRepository requests, ChangeRequestService requestService,
                          HierarchyRepository hierarchies, EntitlementService entitlements, ValidationService validation,
                          BusinessClock clock, MeterRegistry meters, JdbcClient jdbc) {
        this.repository = repository;
        this.requests = requests;
        this.requestService = requestService;
        this.hierarchies = hierarchies;
        this.entitlements = entitlements;
        this.validation = validation;
        this.clock = clock;
        // LLD §11
        this.refreshTimer = Timer.builder("nexus.sandbox.refresh.duration")
                .description("Time to refresh a sandbox overlay after an item change or rebase").register(meters);
        this.conflictSummary = DistributionSummary.builder("nexus.sandbox.conflicts")
                .description("Conflicting items found when a sandbox's conflicts are listed").register(meters);
        Gauge.builder("nexus.sandbox.active", jdbc, SandboxService::activeSandboxes)
                .description("Open sandboxes (drafts of kind sandbox)").register(meters);
    }

    private static double activeSandboxes(JdbcClient jdbc) {
        try {
            return jdbc.sql("SELECT count(*) FROM mdm.change_request WHERE kind = 'sandbox' AND status = 'draft'")
                    .query(Long.class).single();
        } catch (RuntimeException e) {
            return Double.NaN;   // a scrape never fails because the database is briefly unavailable
        }
    }

    /** Outcome of a submit: the request the sandbox became, or why it stays a sandbox (conflicts or validation errors). */
    public record SubmitOutcome(ChangeRequestView request, List<Conflict> conflicts, ValidationReport report) {
    }

    // ------------------------------------------------------------------ lifecycle

    @Transactional
    public SandboxView create(Actor actor, CreateSandbox body) {
        if (!entitlements.hasAny(actor, Permission.PROPOSE)) {
            throw new ForbiddenException("entitlement.missing",
                    "You don't have the propose permission anywhere. Ask an administrator for a steward role.");
        }
        if (body == null || body.name() == null || body.name().isBlank()) {
            throw ItemValidationException.field("name", "is required");
        }
        if (body.versionName() == null || body.versionName().isBlank()) {
            throw ItemValidationException.field("versionName", "is required");
        }
        UUID versionId = requests.versionId(body.versionName().trim())
                .orElseThrow(() -> ItemValidationException.field("versionName", "unknown version " + body.versionName()));
        if (body.hierarchyCode() != null && hierarchies.findIdByCode(body.hierarchyCode())
                .filter(h -> entitlements.canRead(actor, h)).isEmpty()) {
            throw ItemValidationException.field("hierarchyCode", "unknown hierarchy " + body.hierarchyCode());
        }
        repository.lockOwner(actor.userId());
        int max = repository.maxActivePerUser();
        if (repository.activeCount(actor.userId()) >= max) {
            throw new RuleException("sandbox.too_many_active",
                    "You already have " + max + " open sandboxes. Submit or discard one before starting another.");
        }
        UUID id = repository.insert(versionId, body.name().trim(), actor.userId(), actor.kind(),
                body.effectiveFrom() == null ? clock.today() : body.effectiveFrom());
        return withConflicts(repository.find(id).orElseThrow());
    }

    /** Needs a read-write transaction: the conflict count comes from a trial apply that is rolled back. */
    @Transactional
    public SandboxView get(Actor actor, UUID id) {
        return withConflicts(visible(actor, id));
    }

    @Transactional
    public List<SandboxView> mine(Actor actor, String status, Instant afterCreated, UUID afterId, int limit) {
        return repository.mine(actor.userId(), status == null ? "draft" : status, afterCreated, afterId, limit).stream()
                .map(this::withConflicts).toList();
    }

    /**
     * Submit (LLD §5, §6.1): refused with the conflicts while any item conflicts (N2301); validated as any request,
     * and refused with the findings (which are kept) if it has errors, so it stays a sandbox; otherwise the sandbox
     * becomes a request (convert_sandbox re-checks conflicts and clears the overlay) and is submitted in core mode or
     * into the chosen workflow, all in this transaction.
     */
    @Transactional
    public SubmitOutcome submit(Actor actor, UUID id, String ifMatch, String workflowModelCode) {
        int expected = ETags.require(ifMatch);
        ChangeRequestView cr = lockOwnOpen(actor, id, expected);
        List<Conflict> conflicts = repository.conflicts(id);
        if (!conflicts.isEmpty()) {
            return new SubmitOutcome(null, conflicts, null);
        }
        String model = workflowModelCode == null || workflowModelCode.isBlank() ? null : workflowModelCode.trim();
        if (model != null) {
            if (!requests.activeModelExists(model)) {
                throw new RuleException("workflow.unknown_model", "There is no active workflow model " + model + ".");
            }
            requests.updateDraft(id, null, null, null, null, model, null, null);
        }
        ValidationReport report = validation.run(id, cr.effectiveFrom());
        if (report.hasErrors()) {
            return new SubmitOutcome(null, List.of(), report);
        }
        repository.convert(id, actor.userId());
        return new SubmitOutcome(requestService.submitValidated(actor, requests.find(id).orElseThrow()), List.of(), report);
    }

    @Transactional
    public SandboxView discard(Actor actor, UUID id, String ifMatch) {
        int expected = ETags.require(ifMatch);
        lockOwnOpen(actor, id, expected);
        repository.discard(id, actor.userId());
        return repository.find(id).orElseThrow();
    }

    @Transactional
    public RefreshResult rebase(Actor actor, UUID id, String ifMatch) {
        int expected = ETags.require(ifMatch);
        lockOwnOpen(actor, id, expected);
        List<ItemFailure> failures = refreshTimer.record(() -> repository.rebase(id, actor.userId()));
        return new RefreshResult(repository.find(id).orElseThrow().rowVersion(), failures);
    }

    // ------------------------------------------------------------------ items

    /** Adds an item (Phase 1 rules) and refreshes the overlay in the same transaction (LLD §6.2). */
    @Transactional
    public SandboxItemAdded addItem(Actor actor, UUID id, String ifMatch, ItemCommand cmd) {
        int expected = ETags.require(ifMatch);
        ChangeRequestView cr = lockOwnOpen(actor, id, expected);
        var added = requestService.insertItem(actor, cr, cmd);
        List<ItemFailure> failures = refreshTimer.record(() -> repository.refresh(id, added.item().id()));
        return new SandboxItemAdded(added.item(), added.rowVersion(), failures);
    }

    @Transactional
    public RefreshResult deleteItem(Actor actor, UUID id, UUID itemId, String ifMatch) {
        int expected = ETags.require(ifMatch);
        lockOwnOpen(actor, id, expected);
        int version = requestService.removeItem(id, itemId);
        List<ItemFailure> failures = refreshTimer.record(() -> repository.refresh(id, null));
        return new RefreshResult(version, failures);
    }

    @Transactional(readOnly = true)
    public List<ItemView> items(Actor actor, UUID id, int afterSeq, int limit) {
        visible(actor, id);
        return requests.items(id, afterSeq, limit);
    }

    // ------------------------------------------------------------------ overlay reads

    /** Conflicts are the owner's to resolve (LLD §5). Read-write: they come from a rolled-back trial. */
    @Transactional
    public List<Conflict> conflicts(Actor actor, UUID id) {
        SandboxView s = visible(actor, id);
        requireOwner(actor, s);
        List<Conflict> conflicts = repository.conflicts(id);
        conflictSummary.record(conflicts.size());
        return conflicts;
    }

    @Transactional(readOnly = true)
    public List<SandboxChild> children(Actor actor, UUID id, String hierarchyCode, UUID parentId, LocalDate asOf,
                                       List<String> after, int limit) {
        SandboxView s = visible(actor, id);
        UUID hierarchyId = readableHierarchy(actor, hierarchyCode);
        return repository.children(id, hierarchyId, parentId, dayOf(s, asOf), after, limit);
    }

    @Transactional(readOnly = true)
    public SandboxNode node(Actor actor, UUID id, UUID nodeId, String hierarchyCode, LocalDate asOf) {
        SandboxView s = visible(actor, id);
        UUID hierarchyId = hierarchyCode == null ? null : readableHierarchy(actor, hierarchyCode);
        return repository.node(id, nodeId, hierarchyId, dayOf(s, asOf))
                .orElseThrow(() -> new NotFoundException("Node " + nodeId + " not found"));
    }

    @Transactional(readOnly = true)
    public List<SandboxRepository.KeyedDiff> diff(Actor actor, UUID id, String afterKey, int limit) {
        visible(actor, id);
        return repository.diff(id, afterKey, limit);
    }

    // ------------------------------------------------------------------ helpers

    /**
     * The overlay is read at the sandbox's effective date unless the caller names one: that is the date its items
     * take effect, so it is where their effect shows (the Phase 1 reads default to today).
     */
    private static LocalDate dayOf(SandboxView s, LocalDate asOf) {
        return asOf != null ? asOf : s.effectiveFrom();
    }

    private UUID readableHierarchy(Actor actor, String code) {
        return hierarchies.findIdByCode(code).filter(h -> entitlements.canRead(actor, h))
                .orElseThrow(() -> new NotFoundException("Hierarchy " + code + " not found"));
    }

    private SandboxView withConflicts(SandboxView s) {
        if (!"sandbox".equals(s.kind()) || !"draft".equals(s.status())) {
            return s;
        }
        return new SandboxView(s.id(), s.name(), s.versionName(), s.kind(), s.status(), s.ownerId(), s.effectiveFrom(),
                s.baseRecordedAt(), s.createdAt(), s.itemCount(), repository.conflicts(s.id()).size(), s.rowVersion());
    }

    /** Locks the sandbox, checks owner, ETag and that it is still an open sandbox; returns it as a change request. */
    private ChangeRequestView lockOwnOpen(Actor actor, UUID id, int expectedVersion) {
        SandboxView s = repository.lock(id).orElseThrow(() -> notFound(id));
        if (!canSee(actor, s)) {
            throw notFound(id);
        }
        requireOwner(actor, s);
        ETags.check(expectedVersion, s.rowVersion());
        if (!"sandbox".equals(s.kind()) || !"draft".equals(s.status())) {
            throw new RuleException("sandbox.not_draft", "This sandbox was " + ("sandbox".equals(s.kind())
                    ? "discarded" : "submitted") + " and can no longer change.");
        }
        return requests.find(id).orElseThrow();
    }

    private SandboxView visible(Actor actor, UUID id) {
        SandboxView s = repository.find(id).orElseThrow(() -> notFound(id));
        if (!canSee(actor, s)) {
            throw notFound(id);
        }
        return s;
    }

    /** The owner, or someone who may read every hierarchy its items touch (F-1); an empty sandbox is private. */
    private boolean canSee(Actor actor, SandboxView s) {
        if (actor.userId().equals(s.ownerId())) {
            return true;
        }
        List<UUID> touched = repository.itemHierarchies(s.id());
        return !touched.isEmpty() && touched.stream().allMatch(h -> entitlements.canRead(actor, h));
    }

    private static void requireOwner(Actor actor, SandboxView s) {
        if (!actor.userId().equals(s.ownerId())) {
            throw new ForbiddenException("change_request.not_requester", "Only the sandbox's owner can do this.");
        }
    }

    private static NotFoundException notFound(UUID id) {
        return new NotFoundException("Sandbox " + id + " not found");
    }
}
