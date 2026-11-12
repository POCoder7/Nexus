package com.mdm.api.changerequest;

import com.mdm.api.changerequest.ChangeRequestDtos.AddedItem;
import com.mdm.api.changerequest.ChangeRequestDtos.ChangeRequestView;
import com.mdm.api.changerequest.ChangeRequestDtos.CreateRequest;
import com.mdm.api.changerequest.ChangeRequestDtos.ItemCommand;
import com.mdm.api.changerequest.ChangeRequestDtos.ItemView;
import com.mdm.api.changerequest.ChangeRequestDtos.UpdateRequest;
import com.mdm.api.common.BusinessClock;
import com.mdm.api.common.ETags;
import com.mdm.api.common.ItemValidationException;
import com.mdm.api.common.NotFoundException;
import com.mdm.api.common.RuleException;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import com.mdm.api.security.ForbiddenException;
import com.mdm.api.security.Permission;
import com.mdm.api.validation.ValidationReport;
import com.mdm.api.validation.ValidationService;
import com.mdm.api.workflow.WorkflowGateway;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * Drafting change requests (HIE-02, PRP-01; Phase 1 LLD §5.2). Every write locks the request row, checks the
 * {@code If-Match} ETag under the lock and leaves the database guards (draft-only items, frozen content,
 * status transitions) as the last word.
 */
@Service
public class ChangeRequestService {

    private static final Set<String> RISK_TIERS = Set.of("low", "medium", "high", "critical");

    private final ChangeRequestRepository repository;
    private final ItemFactory items;
    private final EntitlementService entitlements;
    private final BusinessClock clock;
    private final ValidationService validation;
    private final WorkflowGateway workflow;

    public ChangeRequestService(ChangeRequestRepository repository, ItemFactory items, EntitlementService entitlements,
                                BusinessClock clock, ValidationService validation, WorkflowGateway workflow) {
        this.repository = repository;
        this.items = items;
        this.entitlements = entitlements;
        this.clock = clock;
        this.validation = validation;
        this.workflow = workflow;
    }

    @Transactional
    public ChangeRequestView create(Actor actor, CreateRequest body) {
        if (!entitlements.hasAny(actor, Permission.PROPOSE)) {
            throw new ForbiddenException("entitlement.missing",
                    "You don't have the propose permission anywhere. Ask an administrator for a steward role.");
        }
        if (body == null || body.title() == null || body.title().isBlank()) {
            throw ItemValidationException.field("title", "is required");
        }
        if (body.versionName() == null || body.versionName().isBlank()) {
            throw ItemValidationException.field("versionName", "is required");
        }
        UUID versionId = repository.versionId(body.versionName())
                .orElseThrow(() -> ItemValidationException.field("versionName", "unknown version " + body.versionName()));
        String risk = riskTier(body.riskTier(), "medium");
        String model = blankToNull(body.workflowModelCode());
        if (model != null && !repository.activeModelExists(model)) {
            throw new RuleException("workflow.unknown_model", "There is no active workflow model " + model + ".");
        }
        UUID id = repository.insert(versionId, body.title().trim(), body.rationale(), risk, actor.userId(), actor.kind(),
                body.effectiveFrom() == null ? clock.today() : body.effectiveFrom(), model, Boolean.TRUE.equals(body.isUrgent()));
        return repository.find(id).orElseThrow();
    }

    @Transactional(readOnly = true)
    public ChangeRequestView get(Actor actor, UUID id) {
        return visible(actor, id);
    }

    @Transactional(readOnly = true)
    public List<ChangeRequestView> mine(Actor actor, String status, Instant afterCreated, UUID afterId, int limit) {
        return repository.mine(actor.userId(), status, afterCreated, afterId, limit);
    }

    @Transactional
    public ChangeRequestView update(Actor actor, UUID id, String ifMatch, UpdateRequest body) {
        int expected = ETags.require(ifMatch);
        ChangeRequestView cr = lockOwnDraft(actor, id, expected);
        if (body.title() != null && body.title().isBlank()) {
            throw ItemValidationException.field("title", "must not be blank");
        }
        String model = blankToNull(body.workflowModelCode());
        if (model != null && !repository.activeModelExists(model)) {
            throw new RuleException("workflow.unknown_model", "There is no active workflow model " + model + ".");
        }
        repository.updateDraft(cr.id(), body.title() == null ? null : body.title().trim(), body.rationale(),
                body.riskTier() == null ? null : riskTier(body.riskTier(), null), body.effectiveFrom(), model, body.isUrgent());
        return repository.find(id).orElseThrow();
    }

    @Transactional
    public AddedItem addItem(Actor actor, UUID id, String ifMatch, ItemCommand cmd) {
        int expected = ETags.require(ifMatch);
        ChangeRequestView cr = lockOwnDraft(actor, id, expected);
        if (cmd == null) {
            throw ItemValidationException.field("action", "is required");
        }
        List<ItemView> earlier = repository.allItems(cr.id());
        ItemFactory.NewItem item = items.build(cr, cmd, earlier);
        for (ItemFactory.Scope s : item.scopes()) {
            entitlements.require(actor, Permission.PROPOSE, s.hierarchyId(), existingAncestor(s.nodeId(), earlier));
        }
        UUID itemId = repository.insertItem(cr.id(), repository.nextSeq(cr.id()), item.action(), item.hierarchyId(),
                item.nodeId(), item.targetParentId(), item.propertyId(), item.payload());
        return new AddedItem(repository.item(itemId).orElseThrow(), repository.find(id).orElseThrow().rowVersion());
    }

    @Transactional(readOnly = true)
    public List<ItemView> items(Actor actor, UUID id, int afterSeq, int limit) {
        visible(actor, id);
        return repository.items(id, afterSeq, limit);
    }

    @Transactional
    public int deleteItem(Actor actor, UUID id, UUID itemId, String ifMatch) {
        int expected = ETags.require(ifMatch);
        lockOwnDraft(actor, id, expected);
        if (repository.deleteItem(id, itemId) == 0) {
            throw new NotFoundException("Item " + itemId + " not found in change request " + id);
        }
        return repository.find(id).orElseThrow().rowVersion();
    }

    @Transactional
    public ChangeRequestView withdraw(Actor actor, UUID id, String ifMatch) {
        int expected = ETags.require(ifMatch);
        ChangeRequestView cr = lockVisible(actor, id);
        requireRequester(actor, cr);
        ETags.check(expected, cr.rowVersion());
        if (cr.governedByWorkflow()) {
            // a governed request is withdrawn through its workflow; the bridge carries the outcome to the request
            UUID instance = workflow.openRootInstance(id).orElseThrow(() -> new RuleException("change_request.not_open",
                    "This request's workflow is already closed."));
            workflow.withdraw(instance, actor);
        } else {
            repository.withdraw(id, actor.userId());   // the function re-checks requester, status and workflow ownership
        }
        return repository.find(id).orElseThrow();
    }

    /**
     * The review queue: other people's requests in {@code status} (default submitted) that the actor may decide, i.e.
     * with DECIDE on every item's scope. Keyset over candidates, filtered here; a page keeps reading until it is full.
     */
    @Transactional(readOnly = true)
    public List<ChangeRequestView> queue(Actor actor, String status, Instant afterCreated, UUID afterId, int limit) {
        List<ChangeRequestView> result = new java.util.ArrayList<>();
        Instant cursorAt = afterCreated;
        UUID cursorId = afterId;
        int batch = Math.max(limit + 1, 50);
        while (result.size() <= limit) {
            List<ChangeRequestView> candidates = repository.queue(actor.userId(), status == null ? "submitted" : status,
                    cursorAt, cursorId, batch);
            for (ChangeRequestView cr : candidates) {
                if (mayDecide(actor, cr.id())) {
                    result.add(cr);
                    if (result.size() > limit) {
                        break;
                    }
                }
            }
            if (candidates.size() < batch) {
                break;
            }
            ChangeRequestView last = candidates.get(candidates.size() - 1);
            cursorAt = last.createdAt();
            cursorId = last.id();
        }
        return result;
    }

    /**
     * Core-mode decision (LLD §6.2, transaction 1): DECIDE on every item's scope, ETag under the lock; the database
     * function records it with basis human_review and the maker-checker trigger refuses self-decisions and non-humans.
     * Apply runs afterwards in its own transaction, so the decision stands even if apply fails.
     */
    @Transactional
    public ChangeRequestView decide(Actor actor, UUID id, String ifMatch, ChangeRequestDtos.DecisionRequest body) {
        int expected = ETags.require(ifMatch);
        if (body == null || !("approve".equals(body.decision()) || "reject".equals(body.decision()))) {
            throw ItemValidationException.field("decision", "must be approve or reject");
        }
        ChangeRequestView cr = lockVisible(actor, id);
        for (UUID[] scope : repository.itemScopes(id)) {
            entitlements.require(actor, Permission.DECIDE, scope[0], scope[1]);
        }
        ETags.check(expected, cr.rowVersion());
        repository.decide(id, actor.userId(), body.decision(), body.note());
        return repository.find(id).orElseThrow();
    }

    private boolean mayDecide(Actor actor, UUID id) {
        try {
            for (UUID[] scope : repository.itemScopes(id)) {
                entitlements.require(actor, Permission.DECIDE, scope[0], scope[1]);
            }
            return true;
        } catch (ForbiddenException e) {
            return false;
        }
    }

    /** Outcome of a submit: the submitted request, or the report that refused it (the request stays a draft). */
    public record SubmitOutcome(ChangeRequestView request, ValidationReport report) {
        public boolean refused() {
            return request == null;
        }
    }

    /**
     * Trial validation (LLD §5.2): the requester, or someone who may decide every item's scope. The findings are
     * stored with the request.
     */
    @Transactional
    public ValidationReport validate(Actor actor, UUID id) {
        ChangeRequestView cr = visible(actor, id);
        if (!actor.userId().equals(cr.requesterId())) {
            for (UUID[] scope : repository.itemScopes(id)) {
                entitlements.require(actor, Permission.DECIDE, scope[0], scope[1]);
            }
        }
        return validation.run(id, cr.effectiveFrom());
    }

    /**
     * Validate and submit in one transaction (LLD §6.3). On errors the request stays a draft and the outcome carries the
     * report; the transaction still commits, so the stored findings are kept.
     */
    @Transactional
    public SubmitOutcome submit(Actor actor, UUID id, String ifMatch) {
        int expected = ETags.require(ifMatch);
        ChangeRequestView cr = lockOwnDraft(actor, id, expected);
        ValidationReport report = validation.run(id, cr.effectiveFrom());
        if (report.hasErrors()) {
            return new SubmitOutcome(null, report);
        }
        if (cr.workflowModelCode() == null && repository.requiresWorkflow(id)) {
            throw new RuleException("change_request.workflow_required",
                    "This request changes a hierarchy that requires a workflow. Choose a workflow model before submitting.");
        }
        repository.submit(id, actor.userId());   // the function re-checks requester, status, items and workflow ownership
        if (cr.workflowModelCode() != null) {
            // same transaction (LLD §3.2): the instance, its stages and the instance_started event; the bridge marks the
            // request governed and in review
            workflow.startInstance(id, cr.workflowModelCode(), actor);
        }
        return new SubmitOutcome(repository.find(id).orElseThrow(), report);
    }

    // ------------------------------------------------------------------ helpers

    /**
     * For a node created earlier in this request, entitlement is checked on the existing node it hangs under,
     * since the new node is not in any hierarchy yet.
     */
    private static UUID existingAncestor(UUID nodeId, List<ItemView> earlier) {
        UUID current = nodeId;
        for (int guard = 0; current != null && guard <= earlier.size(); guard++) {
            UUID c = current;
            Optional<ItemView> added = earlier.stream().filter(e -> "add_node".equals(e.action()) && c.equals(e.nodeId())).findFirst();
            if (added.isEmpty()) {
                return current;
            }
            current = added.get().targetParentId();
        }
        return current;
    }

    private ChangeRequestView lockOwnDraft(Actor actor, UUID id, int expectedVersion) {
        ChangeRequestView cr = lockVisible(actor, id);
        requireRequester(actor, cr);
        ETags.check(expectedVersion, cr.rowVersion());
        if (!"draft".equals(cr.status())) {
            throw new RuleException("change_request.not_draft",
                    "Only a draft can be edited; this change request is " + cr.status() + ".");
        }
        return cr;
    }

    private ChangeRequestView lockVisible(Actor actor, UUID id) {
        ChangeRequestView cr = repository.lock(id).orElseThrow(() -> notFound(id));
        if (!canSee(actor, cr)) {
            throw notFound(id);
        }
        return cr;
    }

    private ChangeRequestView visible(Actor actor, UUID id) {
        ChangeRequestView cr = repository.find(id).orElseThrow(() -> notFound(id));
        if (!canSee(actor, cr)) {
            throw notFound(id);
        }
        return cr;
    }

    /** The requester, or someone who can read every hierarchy its items touch (a request with no items is private). */
    private boolean canSee(Actor actor, ChangeRequestView cr) {
        if (actor.userId().equals(cr.requesterId())) {
            return true;
        }
        List<UUID> hierarchies = repository.itemHierarchies(cr.id());
        return !hierarchies.isEmpty() && hierarchies.stream().allMatch(h -> entitlements.canRead(actor, h));
    }

    private static void requireRequester(Actor actor, ChangeRequestView cr) {
        if (!actor.userId().equals(cr.requesterId())) {
            throw new ForbiddenException("change_request.not_requester", "Only the requester can change this change request.");
        }
    }

    private static String riskTier(String value, String fallback) {
        if (value == null) {
            return fallback;
        }
        if (!RISK_TIERS.contains(value)) {
            throw ItemValidationException.field("riskTier", "must be one of low, medium, high, critical");
        }
        return value;
    }


    private static String blankToNull(String s) {
        return s == null || s.isBlank() ? null : s.trim();
    }
    private static NotFoundException notFound(UUID id) {
        return new NotFoundException("Change request " + id + " not found");
    }
}
