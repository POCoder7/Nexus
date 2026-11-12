package com.mdm.api.version;

import com.mdm.api.common.Cursors;
import com.mdm.api.common.ETags;
import com.mdm.api.common.ItemValidationException;
import com.mdm.api.common.NotFoundException;
import com.mdm.api.common.Page;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import com.mdm.api.security.ForbiddenException;
import com.mdm.api.security.Permission;
import com.mdm.api.version.VersionDtos.CreateVersion;
import com.mdm.api.version.VersionDtos.OpenRequests;
import com.mdm.api.version.VersionDtos.UpdateVersion;
import com.mdm.api.version.VersionDtos.VersionEdit;
import com.mdm.api.version.VersionDtos.VersionTransition;
import com.mdm.api.version.VersionDtos.VersionTransitionRequest;
import com.mdm.api.version.VersionDtos.VersionView;
import com.mdm.api.version.VersionRepository.VersionRow;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * Versions (VER-01 create and copy, VER-02 lifecycle; ADR-037, Phase 3 LLD V.5).
 * <ul>
 *   <li>Reads need READ. Writes are for version administrators; the database checks that again (N1028) with every other
 *       rule: the four moves (N2701), frozen fields (N2702), requests in flight (N2704), four eyes (N1029), people only (N1030).</li>
 *   <li>{@code transitions} and {@code edit} tell the caller what they may do and why not, computed read-only with the same
 *       rules, so the UI shows the server's reasons and holds no rule of its own.</li>
 *   <li>Writes take {@code If-Match}. The API role cannot lock a version row (it has no UPDATE privilege on it), so the
 *       revision is checked before the write and again after it: a change made by someone else in between shows as a
 *       revision that moved by more than one, and the transaction is rolled back with 412.</li>
 * </ul>
 */
@Service
public class VersionService {

    /** The four moves of the lifecycle (V11 guard, N2701), by current status. */
    static final Map<String, List<String>> NEXT = Map.of(
            "working", List.of("submitted"),
            "submitted", List.of("working", "finalized"),
            "finalized", List.of("expired"),
            "expired", List.of());

    static final Set<String> STATUSES = NEXT.keySet();
    static final int MAX_NAME = 100;

    private final VersionRepository repository;
    private final EntitlementService entitlements;
    private final Cursors cursors;

    public VersionService(VersionRepository repository, EntitlementService entitlements, Cursors cursors) {
        this.repository = repository;
        this.entitlements = entitlements;
        this.cursors = cursors;
    }

    @Transactional(readOnly = true)
    public Page<VersionView> list(Actor actor, String status, int limit, String cursor) {
        requireRead(actor);
        cursors.checkLimit(limit);
        if (status != null && !STATUSES.contains(status)) {
            throw new IllegalArgumentException("status must be one of working, submitted, finalized, expired");
        }
        List<String> after = cursors.decode(cursor, 2);
        List<VersionRow> rows = repository.page(status, after == null ? null : cursorDate(after.get(0)),
                after == null ? null : after.get(1), limit);
        boolean admin = repository.isAdmin(actor.userId());
        // counts are needed only to explain a refused submit, so only for working versions
        Map<UUID, OpenRequests> counts = repository.openRequests(
                rows.stream().filter(r -> "working".equals(r.status())).map(VersionRow::id).toList());
        List<VersionView> views = rows.stream()
                .map(r -> view(r, actor.userId(), admin, counts.getOrDefault(r.id(), NONE), false)).toList();
        return Page.of(views, limit, v -> cursors.encode(v.businessAsOf().toString(), v.name()));
    }

    @Transactional(readOnly = true)
    public VersionView get(Actor actor, String name) {
        requireRead(actor);
        return full(actor, find(name));
    }

    @Transactional
    public VersionView create(Actor actor, CreateVersion body) {
        requireAdmin(actor);
        if (body == null) {
            throw ItemValidationException.field("name", "is required");
        }
        String name = validName(body.name());
        UUID baseId = null;
        LocalDate businessAsOf = body.businessAsOf();
        if (body.baseVersion() != null && !body.baseVersion().isBlank()) {
            VersionRow base = repository.findByName(body.baseVersion().trim())
                    .orElseThrow(() -> ItemValidationException.field("baseVersion", "unknown version " + body.baseVersion()));
            baseId = base.id();
            if (businessAsOf == null) {
                businessAsOf = base.businessAsOf();   // a copy shows its base's picture unless told otherwise (VER-01)
            }
        }
        if (businessAsOf == null) {
            throw ItemValidationException.field("businessAsOf", "is required");
        }
        UUID id = repository.create(name, businessAsOf, baseId, blankToNull(body.description()), actor.userId());
        return full(actor, repository.findById(id).orElseThrow());
    }

    @Transactional
    public VersionView update(Actor actor, String name, String ifMatch, UpdateVersion body) {
        requireAdmin(actor);
        int expected = ETags.require(ifMatch);
        VersionRow v = find(name);
        ETags.check(expected, v.revision());
        if (body == null) {
            return full(actor, v);
        }
        String newName = body.name() == null ? v.name() : validName(body.name());
        String newDescription = body.description() == null ? v.description() : blankToNull(body.description());
        if (newName.equals(v.name()) && Objects.equals(newDescription, v.description())) {
            return full(actor, v);   // nothing to change: no write, no new revision
        }
        repository.update(v.id(), newName, newDescription, actor.userId());
        return full(actor, afterWrite(v, expected));
    }

    @Transactional
    public VersionView transition(Actor actor, String name, String ifMatch, VersionTransitionRequest body) {
        requireAdmin(actor);
        int expected = ETags.require(ifMatch);
        if (body == null || body.to() == null || body.to().isBlank()) {
            throw ItemValidationException.field("to", "is required");
        }
        VersionRow v = find(name);
        ETags.check(expected, v.revision());
        repository.transition(v.id(), body.to().trim(), blankToNull(body.reason()), actor.userId());
        return full(actor, afterWrite(v, expected));
    }

    // ------------------------------------------------------------------ rules for the caller (read-only)

    private static final OpenRequests NONE = new OpenRequests(0, 0, 0, 0);

    private VersionView full(Actor actor, VersionRow v) {
        OpenRequests counts = repository.openRequests(List.of(v.id())).getOrDefault(v.id(), NONE);
        return view(v, actor.userId(), repository.isAdmin(actor.userId()), counts, true);
    }

    private static VersionView view(VersionRow v, UUID caller, boolean admin, OpenRequests counts, boolean withCounts) {
        List<VersionTransition> transitions = new ArrayList<>();
        for (String to : NEXT.get(v.status())) {
            String why = whyNot(v, to, caller, admin, counts);
            transitions.add(new VersionTransition(to, why == null, why));
        }
        String editWhy = editWhyNot(v, admin);
        return new VersionView(v.name(), v.status(), v.businessAsOf(), v.recordedAsOf(), v.baseVersion(), v.description(),
                v.createdAt(), v.createdBy(), v.submittedAt(), v.submittedBy(), v.finalizedAt(), v.finalizedBy(), v.revision(),
                List.copyOf(transitions), new VersionEdit(editWhy == null, editWhy), withCounts ? counts : null);
    }

    /** Null when the caller may make the move; otherwise the reason, in the order the database checks it. */
    static String whyNot(VersionRow v, String to, UUID caller, boolean admin, OpenRequests counts) {
        if (!admin) {
            return "Only a version administrator can " + verb(to) + " versions";
        }
        if ("submitted".equals(to) && counts.inFlight() > 0) {
            return inFlight(counts);
        }
        if ("finalized".equals(to) && v.submittedBy() != null && caller.equals(v.submittedBy().id())) {
            return "You submitted this version; another version administrator must finalize it";
        }
        return null;
    }

    static String editWhyNot(VersionRow v, boolean admin) {
        if (!admin) {
            return "Only a version administrator can edit versions";
        }
        return switch (v.status()) {
            case "finalized" -> "A finalized version can only be expired";
            case "expired" -> "An expired version cannot be changed";
            default -> null;
        };
    }

    /** The same words as the database's N2704 message, so the reason shown before and after an attempt agree. */
    static String inFlight(OpenRequests c) {
        List<String> parts = new ArrayList<>();
        if (c.submitted() > 0) {
            parts.add(c.submitted() + " submitted");
        }
        if (c.inReview() > 0) {
            parts.add(c.inReview() + " in review");
        }
        if (c.approved() > 0) {
            parts.add(c.approved() + " approved");
        }
        long n = c.inFlight();
        return n + (n == 1 ? " request in this version is" : " requests in this version are") + " still in flight ("
                + String.join(", ", parts) + ")";
    }

    private static String verb(String to) {
        return switch (to) {
            case "submitted" -> "submit";
            case "working" -> "reopen";
            case "finalized" -> "finalize";
            default -> "expire";
        };
    }

    // ------------------------------------------------------------------ helpers

    private void requireRead(Actor actor) {
        if (!entitlements.hasAny(actor, Permission.READ)) {
            throw new ForbiddenException("entitlement.missing",
                    "You don't have the read permission anywhere. Ask an administrator for a role.");
        }
    }

    /** Same words and code as the database's N1028, which still checks every call. */
    private void requireAdmin(Actor actor) {
        if (!repository.isAdmin(actor.userId())) {
            throw new ForbiddenException("version.not_admin", "Only a version administrator can create or change versions");
        }
    }

    private VersionRow find(String name) {
        return repository.findByName(name).orElseThrow(() -> new NotFoundException("Version " + name + " not found"));
    }

    /** The row after this transaction's one write: its revision moved by exactly one, or someone else wrote in between. */
    private VersionRow afterWrite(VersionRow before, int expected) {
        VersionRow after = repository.findById(before.id()).orElseThrow();
        if (after.revision() != expected + 1) {
            throw new ETags.PreconditionFailedException(after.revision() - 1);
        }
        return after;
    }

    private static String validName(String raw) {
        String name = raw == null ? "" : raw.trim();
        if (name.isEmpty()) {
            throw ItemValidationException.field("name", "is required");
        }
        if (name.length() > MAX_NAME) {
            throw ItemValidationException.field("name", "must be at most " + MAX_NAME + " characters");
        }
        if (name.contains("/")) {
            throw ItemValidationException.field("name", "must not contain /, because the name is part of the version's address");
        }
        return name;
    }

    private static LocalDate cursorDate(String s) {
        try {
            return LocalDate.parse(s);
        } catch (java.time.DateTimeException e) {
            throw new IllegalArgumentException("Invalid cursor");
        }
    }

    private static String blankToNull(String s) {
        return s == null || s.isBlank() ? null : s.trim();
    }
}
