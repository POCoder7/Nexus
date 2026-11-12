package com.mdm.api.version;

import com.mdm.api.common.ETags;
import com.mdm.api.common.Page;
import com.mdm.api.security.Actor;
import com.mdm.api.version.VersionDtos.CreateVersion;
import com.mdm.api.version.VersionDtos.UpdateVersion;
import com.mdm.api.version.VersionDtos.VersionTransitionRequest;
import com.mdm.api.version.VersionDtos.VersionView;
import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.util.UriComponentsBuilder;

/**
 * Versions (VER-01, VER-02; Phase 3 LLD V.5). A version's picture is read through the existing endpoints with
 * {@code asOf} = its business date and {@code recordedAsOf} = its pin. Creating a version takes an optional
 * {@code Idempotency-Key} (IdempotencyFilter); changes take {@code If-Match} (428 without it, 412 if stale).
 */
@RestController
@RequestMapping("/api/v1/versions")
public class VersionController {

    private final VersionService service;

    public VersionController(VersionService service) {
        this.service = service;
    }

    /** Newest business date first, then by name. {@code status}: working, submitted, finalized or expired. */
    @GetMapping
    public Page<VersionView> listVersions(Actor actor, @RequestParam(required = false) String status,
                                          @RequestParam(defaultValue = "50") int limit,
                                          @RequestParam(required = false) String cursor) {
        return service.list(actor, status, limit, cursor);
    }

    @GetMapping("/{name}")
    public ResponseEntity<VersionView> getVersion(Actor actor, @PathVariable String name) {
        VersionView v = service.get(actor, name);
        return ResponseEntity.ok().eTag(ETags.of(v.revision())).body(v);
    }

    @PostMapping
    public ResponseEntity<VersionView> createVersion(Actor actor, @RequestBody(required = false) CreateVersion body) {
        VersionView v = service.create(actor, body);
        return ResponseEntity.created(UriComponentsBuilder.fromPath("/api/v1/versions/{name}").buildAndExpand(v.name()).encode().toUri())
                .eTag(ETags.of(v.revision())).body(v);
    }

    /** Name and description, while the version is working or submitted. */
    @PatchMapping("/{name}")
    public ResponseEntity<VersionView> updateVersion(Actor actor, @PathVariable String name,
                                                     @RequestHeader(value = HttpHeaders.IF_MATCH, required = false) String ifMatch,
                                                     @RequestBody(required = false) UpdateVersion body) {
        VersionView v = service.update(actor, name, ifMatch, body);
        return ResponseEntity.ok().eTag(ETags.of(v.revision())).body(v);
    }

    /** Submit (to submitted), reopen (to working), finalize or expire. Returns the version after the move. */
    @PostMapping("/{name}/transitions")
    public ResponseEntity<VersionView> transitionVersion(Actor actor, @PathVariable String name,
                                                         @RequestHeader(value = HttpHeaders.IF_MATCH, required = false) String ifMatch,
                                                         @RequestBody(required = false) VersionTransitionRequest body) {
        VersionView v = service.transition(actor, name, ifMatch, body);
        return ResponseEntity.ok().eTag(ETags.of(v.revision())).body(v);
    }
}
