package com.mdm.api.hierarchy;

import com.mdm.api.common.BusinessClock;
import com.mdm.api.common.Cursors;
import com.mdm.api.common.NotFoundException;
import com.mdm.api.common.Page;
import com.mdm.api.common.Slice;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.web.bind.annotation.*;

import java.time.Instant;
import java.time.LocalDate;
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
    public Page<HierarchySummary> list(
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
    public HierarchySummary get(
            Actor actor,
            @PathVariable String code,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant recordedAsOf) {
        readableHierarchyId(actor, code);
        return repository.findByCode(code, Slice.of(asOf, recordedAsOf, clock)).orElseThrow(() -> notFound(code));
    }

    @GetMapping("/{code}/children")
    public Page<ChildNode> children(
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
