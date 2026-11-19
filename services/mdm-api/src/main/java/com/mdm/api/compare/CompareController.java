package com.mdm.api.compare;

import com.mdm.api.common.Page;
import com.mdm.api.compare.CompareDtos.CompareRequest;
import com.mdm.api.compare.CompareDtos.CompareRow;
import com.mdm.api.compare.CompareDtos.CompareRunView;
import com.mdm.api.security.Actor;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.net.URI;
import java.util.UUID;

/**
 * Compares (QRY-02, VER-04; Phase 5 LLD §17.4, §17.11): start a run (202, then poll it), read its status and counts,
 * and page its rows by kind. READ on both hierarchies; a run is not shown to someone who cannot read both.
 */
@RestController
@RequestMapping("/api/v1/compares")
public class CompareController {

    private final CompareService service;

    public CompareController(CompareService service) {
        this.service = service;
    }

    @PostMapping
    public ResponseEntity<CompareRunView> startCompare(Actor actor, @RequestBody(required = false) CompareRequest body) {
        CompareRunView run = service.start(actor, body);
        return ResponseEntity.status(HttpStatus.ACCEPTED).location(URI.create("/api/v1/compares/" + run.id())).body(run);
    }

    @GetMapping("/{id}")
    public CompareRunView getCompare(Actor actor, @PathVariable UUID id) {
        return service.get(actor, id);
    }

    /**
     * {@code type}: structure, property or rename (the row's kind); none = all, ordered by kind then node name. Not named
     * {@code kind}: that name is kept off query parameters so the actor's fields can never leak into the API (OpenApiDocumentTest).
     */
    @GetMapping("/{id}/rows")
    public Page<CompareRow> listCompareRows(Actor actor, @PathVariable UUID id, @RequestParam(name = "type", required = false) String kind,
                                            @RequestParam(required = false) String cursor,
                                            @RequestParam(defaultValue = "100") int limit) {
        return service.rows(actor, id, kind, cursor, limit);
    }
}
