package com.mdm.api.hierarchy;

import com.mdm.api.common.BusinessClock;
import com.mdm.api.common.Cursors;
import com.mdm.api.common.NotFoundException;
import com.mdm.api.common.Page;
import com.mdm.api.common.RuleException;
import com.mdm.api.common.Slice;
import com.mdm.api.hierarchy.HierarchyRepository.NodeRef;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.web.bind.annotation.*;

import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** HIE-01 reads and lazy tree loading, at any business date and recorded time (NEW-01), keyset-paged (ADR-015). */
@RestController
@RequestMapping("/api/v1/hierarchies")
public class HierarchyController {

    private final HierarchyRepository repository;
    private final EntitlementService entitlements;
    private final BusinessClock clock;
    private final Cursors cursors;

    public HierarchyController(HierarchyRepository repository, EntitlementService entitlements, BusinessClock clock,
                               Cursors cursors) {
        this.repository = repository;
        this.entitlements = entitlements;
        this.clock = clock;
        this.cursors = cursors;
    }

    /** Hierarchies the actor may read (SEC-02), ordered by sort sequence then code. */
    @GetMapping
    public Page<HierarchySummary> listHierarchies(
            Actor actor,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant recordedAsOf,
            @RequestParam(defaultValue = "200") int limit,
            @RequestParam(required = false) String cursor) {
        cursors.checkLimit(limit);
        Slice slice = Slice.of(asOf, recordedAsOf, clock);
        return Page.of(repository.findPage(slice, entitlements.readableHierarchies(actor), cursors.decode(cursor, 2), limit),
                limit, h -> cursors.encode(String.valueOf(h.sortKey()), h.code()));
    }

    @GetMapping("/{code}")
    public HierarchySummary getHierarchy(
            Actor actor,
            @PathVariable String code,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant recordedAsOf) {
        readableHierarchyId(actor, code);
        return repository.findByCode(code, Slice.of(asOf, recordedAsOf, clock)).orElseThrow(() -> notFound(code));
    }

    @GetMapping("/{code}/children")
    public Page<ChildNode> listChildren(
            Actor actor,
            @PathVariable String code,
            @RequestParam UUID parentId,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant recordedAsOf,
            @RequestParam(defaultValue = "200") int limit,
            @RequestParam(required = false) String cursor) {
        cursors.checkLimit(limit);
        readableHierarchyId(actor, code);
        Slice slice = Slice.of(asOf, recordedAsOf, clock);
        return Page.of(repository.findChildren(code, parentId, slice, cursors.decode(cursor, 3), limit), limit,
                c -> cursors.encode(c.sortOrder().toPlainString(), c.name() == null ? "" : c.name(), c.nodeId().toString()));
    }

    public static final int SEARCH_MIN_CHARS = 2;
    public static final int SEARCH_MAX_LIMIT = 50;

    /** A search hit with its primary path from the top node, so the tree can reveal it (Phase 3 LLD §7.2). */
    public record SearchHit(UUID nodeId, String name, List<NodeRef> path) {
    }

    public record NodePath(List<NodeRef> path) {
    }

    /** HIE-12 in-tree search by name or description. {@code q} needs at least two characters (422 otherwise). */
    @GetMapping("/{code}/search")
    public Page<SearchHit> searchHierarchy(
            Actor actor,
            @PathVariable String code,
            @RequestParam String q,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant recordedAsOf,
            @RequestParam(defaultValue = "20") int limit,
            @RequestParam(required = false) String cursor) {
        if (limit < 1 || limit > SEARCH_MAX_LIMIT) {
            throw new IllegalArgumentException("limit must be between 1 and " + SEARCH_MAX_LIMIT);
        }
        String text = q.strip();
        if (text.length() < SEARCH_MIN_CHARS) {
            throw new RuleException("search.query_too_short", "Type at least " + SEARCH_MIN_CHARS + " characters to search.");
        }
        if (text.length() > 100) {
            throw new IllegalArgumentException("q must be at most 100 characters");
        }
        UUID hierarchyId = readableHierarchyId(actor, code);
        Slice slice = Slice.of(asOf, recordedAsOf, clock);
        Page<NodeRef> hits = Page.of(repository.search(hierarchyId, text, slice, cursors.decode(cursor, 2), limit), limit,
                n -> cursors.encode(n.name(), n.nodeId().toString()));
        return new Page<>(hits.items().stream()
                .map(n -> new SearchHit(n.nodeId(), n.name(), repository.primaryPath(hierarchyId, n.nodeId(), slice)))
                .toList(), hits.nextCursor());
    }

    /** Primary-placement path from the top node to the node (both included); 404 if the node is not in the hierarchy then. */
    @GetMapping("/{code}/nodes/{nodeId}/path")
    public NodePath getNodePath(
            Actor actor,
            @PathVariable String code,
            @PathVariable UUID nodeId,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant recordedAsOf) {
        UUID hierarchyId = readableHierarchyId(actor, code);
        List<NodeRef> path = repository.primaryPath(hierarchyId, nodeId, Slice.of(asOf, recordedAsOf, clock));
        if (path.isEmpty()) {
            throw new NotFoundException("Node " + nodeId + " not found in " + code);
        }
        return new NodePath(path);
    }

    /**
     * What moving, removing or deleting the node would touch (UI_STANDARD §6 impact preview): descendants by primary links
     * (capped), placements and whether it is the top node. Read-only; the change itself is validated on submit.
     */
    @GetMapping("/{code}/nodes/{nodeId}/impact")
    public HierarchyRepository.Impact getNodeImpact(
            Actor actor,
            @PathVariable String code,
            @PathVariable UUID nodeId,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant recordedAsOf) {
        UUID hierarchyId = readableHierarchyId(actor, code);
        Slice slice = Slice.of(asOf, recordedAsOf, clock);
        if (repository.primaryPath(hierarchyId, nodeId, slice).isEmpty()) {
            throw new NotFoundException("Node " + nodeId + " not found in " + code);
        }
        return repository.impact(hierarchyId, nodeId, slice);
    }

    /** The hierarchy's id if it exists and the actor may read it; otherwise 404, so existence is not revealed. */
    private UUID readableHierarchyId(Actor actor, String code) {
        return repository.findIdByCode(code)
                .filter(id -> entitlements.canRead(actor, id))
                .orElseThrow(() -> notFound(code));
    }

    private static NotFoundException notFound(String code) {
        return new NotFoundException("Hierarchy " + code + " not found");
    }
}
