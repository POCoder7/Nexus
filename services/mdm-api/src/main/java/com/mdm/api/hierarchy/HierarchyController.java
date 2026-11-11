package com.mdm.api.hierarchy;

import com.mdm.api.common.NotFoundException;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.web.bind.annotation.*;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/api/v1/hierarchies")
public class HierarchyController {

    private final HierarchyRepository repository;
    private final int maxPageSize;

    public HierarchyController(HierarchyRepository repository,
                               @Value("${mdm.api.max-page-size:1000}") int maxPageSize) {
        this.repository = repository;
        this.maxPageSize = maxPageSize;
    }

    @GetMapping
    public List<HierarchySummary> list(
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf) {
        return repository.findActive(asOf == null ? LocalDate.now() : asOf);
    }

    @GetMapping("/{code}")
    public HierarchySummary get(
            @PathVariable String code,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf) {
        return repository.findByCode(code, asOf == null ? LocalDate.now() : asOf)
                .orElseThrow(() -> new NotFoundException("Hierarchy " + code + " not found"));
    }

    @GetMapping("/{code}/children")
    public List<ChildNode> children(
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
        return repository.findChildren(code, parentId, asOf == null ? LocalDate.now() : asOf, limit, offset);
    }
}
