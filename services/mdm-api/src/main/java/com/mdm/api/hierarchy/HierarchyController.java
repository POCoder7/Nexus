package com.mdm.api.hierarchy;

import com.mdm.api.common.BusinessClock;
import com.mdm.api.common.NotFoundException;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.web.bind.annotation.*;

import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

@RestController
@RequestMapping("/api/v1/hierarchies")
public class HierarchyController {

    private final HierarchyRepository repository;
    private final EntitlementService entitlements;
    private final BusinessClock clock;
    private final int maxPageSize;

    public HierarchyController(HierarchyRepository repository, EntitlementService entitlements, BusinessClock clock,
                               @Value("${mdm.api.max-page-size:1000}") int maxPageSize) {
        this.repository = repository;
        this.entitlements = entitlements;
        this.clock = clock;
        this.maxPageSize = maxPageSize;
    }

    /** Hierarchies the actor may read (SEC-02). */
    @GetMapping
    public List<HierarchySummary> list(
            Actor actor,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf) {
        Optional<Set<UUID>> readable = entitlements.readableHierarchies(actor);
        return repository.findActive(asOf == null ? clock.today() : asOf).stream()
                .filter(h -> readable.map(ids -> ids.contains(h.hierarchyId())).orElse(true))
                .toList();
    }

    @GetMapping("/{code}")
    public HierarchySummary get(
            Actor actor,
            @PathVariable String code,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf) {
        UUID id = readableHierarchyId(actor, code);
        return repository.findByCode(code, asOf == null ? clock.today() : asOf)
                .filter(h -> h.hierarchyId().equals(id))
                .orElseThrow(() -> notFound(code));
    }

    @GetMapping("/{code}/children")
    public List<ChildNode> children(
            Actor actor,
            @PathVariable String code,
            @RequestParam UUID parentId,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf,
            @RequestParam(defaultValue = "200") int limit,
            @RequestParam(defaultValue = "0") int offset) {
        if (limit < 1 || limit > maxPageSize) {
            throw new IllegalArgumentException("limit must be between 1 and " + maxPageSize);
        }
        if (offset < 0) {
            throw new IllegalArgumentException("offset must be >= 0");
        }
        readableHierarchyId(actor, code);
        return repository.findChildren(code, parentId, asOf == null ? clock.today() : asOf, limit, offset);
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
