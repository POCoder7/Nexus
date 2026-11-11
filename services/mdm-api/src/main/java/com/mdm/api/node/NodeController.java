package com.mdm.api.node;

import com.mdm.api.common.BusinessClock;
import com.mdm.api.common.NotFoundException;
import com.mdm.api.common.Slice;
import com.mdm.api.hierarchy.HierarchyRepository;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.web.bind.annotation.*;

import java.time.Instant;
import java.time.LocalDate;
import java.util.UUID;

@RestController
@RequestMapping("/api/v1/nodes")
public class NodeController {

    private final NodeRepository repository;
    private final HierarchyRepository hierarchies;
    private final EntitlementService entitlements;
    private final BusinessClock clock;

    public NodeController(NodeRepository repository, HierarchyRepository hierarchies, EntitlementService entitlements,
                          BusinessClock clock) {
        this.repository = repository;
        this.hierarchies = hierarchies;
        this.entitlements = entitlements;
        this.clock = clock;
    }

    /**
     * Node detail with resolved properties; pass a hierarchy code to include its local properties.
     * The actor must be able to read the named hierarchy, or (without one) a hierarchy that contains the node.
     * An unknown hierarchy code is a 404, not a silent omission of local properties (D-19).
     */
    @GetMapping("/{nodeId}")
    public NodeDetail get(
            Actor actor,
            @PathVariable UUID nodeId,
            @RequestParam(required = false) String hierarchy,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant recordedAsOf) {
        Slice slice = Slice.of(asOf, recordedAsOf, clock);
        LocalDate day = slice.asOf();
        if (hierarchy != null) {
            UUID hierarchyId = hierarchies.findIdByCode(hierarchy)
                    .filter(id -> entitlements.canRead(actor, id))
                    .orElseThrow(() -> new NotFoundException("Hierarchy " + hierarchy + " not found"));
            if (!repository.isInHierarchy(nodeId, hierarchyId, day)) {
                throw nodeNotFound(nodeId);
            }
        } else if (repository.hierarchiesContaining(nodeId, day).stream().noneMatch(id -> entitlements.canRead(actor, id))
                && entitlements.readableHierarchies(actor).isPresent()) {
            throw nodeNotFound(nodeId);
        }
        return repository.find(nodeId, hierarchy, slice).orElseThrow(() -> nodeNotFound(nodeId));
    }

    private static NotFoundException nodeNotFound(UUID nodeId) {
        return new NotFoundException("Node " + nodeId + " not found");
    }
}
