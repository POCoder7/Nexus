package com.mdm.api.query;

import com.mdm.api.common.Cursors;
import com.mdm.api.common.ETags;
import com.mdm.api.common.Page;
import com.mdm.api.query.QueryDtos.QueryPage;
import com.mdm.api.query.QueryDtos.RunQuery;
import com.mdm.api.query.QueryDtos.SaveQuery;
import com.mdm.api.query.QueryDtos.SavedQueryView;
import com.mdm.api.security.Actor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.net.URI;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * Property queries (QRY-01; Phase 5 LLD §17.11): run a query, and keep queries to run again or share. A run reads one
 * slice: a version's ({@code version}), or a business date and recorded time ({@code asOf}, {@code recordedAsOf}).
 */
@RestController
@RequestMapping("/api/v1/queries")
public class QueryController {

    private final QueryService service;
    private final Cursors cursors;

    public QueryController(QueryService service, Cursors cursors) {
        this.service = service;
        this.cursors = cursors;
    }

    /** Runs a query that is not saved. A partial page ({@code partial: true}) continues with its cursor. */
    @PostMapping("/run")
    public QueryPage runQuery(Actor actor, @RequestBody RunQuery body,
                              @RequestParam(required = false) String version,
                              @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf,
                              @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant recordedAsOf,
                              @RequestParam(defaultValue = "100") int limit,
                              @RequestParam(required = false) String cursor) {
        cursors.checkLimit(limit);
        return service.run(actor, body == null ? null : body.definition(), new QueryService.RunSlice(asOf, recordedAsOf, version),
                position(cursor), limit, this::encode);
    }

    /** The caller's own saved queries and the shared ones they can read, by name. */
    @GetMapping
    public Page<SavedQueryView> listSavedQueries(Actor actor, @RequestParam(defaultValue = "100") int limit,
                                                 @RequestParam(required = false) String cursor) {
        cursors.checkLimit(limit);
        QueryService.Position after = position(cursor);
        return Page.of(service.listSaved(actor, after == null ? null : after.name(), after == null ? null : after.id(), limit),
                limit, q -> encode(new QueryService.Position(q.name(), q.id())));
    }

    @PostMapping
    public ResponseEntity<SavedQueryView> createSavedQuery(Actor actor, @RequestBody SaveQuery body) {
        SavedQueryView q = service.save(actor, body);
        return ResponseEntity.created(URI.create("/api/v1/queries/" + q.id())).eTag(ETags.of(q.rowVersion())).body(q);
    }

    @GetMapping("/{id}")
    public ResponseEntity<SavedQueryView> getSavedQuery(Actor actor, @PathVariable UUID id) {
        SavedQueryView q = service.getSaved(actor, id);
        return ResponseEntity.ok().eTag(ETags.of(q.rowVersion())).body(q);
    }

    @PutMapping("/{id}")
    public ResponseEntity<SavedQueryView> updateSavedQuery(Actor actor, @PathVariable UUID id,
                                                           @RequestHeader(value = HttpHeaders.IF_MATCH, required = false) String ifMatch,
                                                           @RequestBody SaveQuery body) {
        SavedQueryView q = service.update(actor, id, ifMatch, body);
        return ResponseEntity.ok().eTag(ETags.of(q.rowVersion())).body(q);
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> deleteSavedQuery(Actor actor, @PathVariable UUID id,
                                                 @RequestHeader(value = HttpHeaders.IF_MATCH, required = false) String ifMatch) {
        service.delete(actor, id, ifMatch);
        return ResponseEntity.noContent().build();
    }

    /** Runs a saved query with the caller's own read scope (sharing a query never shares data). */
    @PostMapping("/{id}/run")
    public QueryPage runSavedQuery(Actor actor, @PathVariable UUID id,
                                   @RequestParam(required = false) String version,
                                   @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate asOf,
                                   @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant recordedAsOf,
                                   @RequestParam(defaultValue = "100") int limit,
                                   @RequestParam(required = false) String cursor) {
        cursors.checkLimit(limit);
        SavedQueryView q = service.getSaved(actor, id);
        return service.run(actor, q.definition(), new QueryService.RunSlice(asOf, recordedAsOf, version), position(cursor), limit,
                this::encode);
    }

    private QueryService.Position position(String cursor) {
        List<String> after = cursors.decode(cursor, 2);
        return after == null ? null : new QueryService.Position(after.get(0), UUID.fromString(after.get(1)));
    }

    private String encode(QueryService.Position p) {
        return cursors.encode(p.name(), p.id().toString());
    }
}
