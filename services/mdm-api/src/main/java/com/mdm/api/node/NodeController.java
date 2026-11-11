package com.mdm.api.node;

import com.mdm.api.common.NotFoundException;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.web.bind.annotation.*;

import java.time.LocalDate;
import java.util.UUID;

@RestController
@RequestMapping("/api/v1/nodes")
public class NodeController {

    private final NodeRepository repository;

    public NodeController(NodeRepository repository) {
        this.repository = repository;
    }

    /** Node detail with resolved properties; pass a hierarchy code to include its local properties. */
    @GetMapping("/{nodeId}")
    public NodeDetail get(
            @PathVariable UUID nodeId,
            @RequestParam(required = false) String hierarchy,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf) {
        return repository.find(nodeId, hierarchy, asOf == null ? LocalDate.now() : asOf)
                .orElseThrow(() -> new NotFoundException("Node " + nodeId + " not found"));
    }
}
