package com.mdm.api.audit;

import com.mdm.api.audit.AuditQuery.AuditEntry;
import com.mdm.api.audit.AuditQuery.Criteria;
import com.mdm.api.audit.AuditQuery.Row;
import com.mdm.api.common.BusinessClock;
import com.mdm.api.common.Cursors;
import com.mdm.api.common.ItemValidationException;
import com.mdm.api.common.Page;
import com.mdm.api.hierarchy.HierarchyRepository;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import com.mdm.api.security.ForbiddenException;
import com.mdm.api.security.Permission;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.time.LocalDate;
import java.time.temporal.ChronoUnit;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * Transaction history (AUD-01; Phase 5 LLD §18.4, §18.5): every recorded change, newest first, filtered by recorded date,
 * user, hierarchy, node, property, request and category. Everyone who can read a hierarchy sees the data changes of the
 * hierarchies they can read; the other categories are for ADMINs. Read-only.
 */
@RestController
@RequestMapping("/api/v1/audit")
public class AuditController {

    public static final int DEFAULT_DAYS = 30;
    /** A search over more days needs a narrowing filter (request, node or user), so one search cannot scan years. */
    public static final int MAX_DAYS_UNFILTERED = 366;
    private static final int DEFAULT_LIMIT = 50;
    private static final int MAX_LIMIT = 200;
    private static final Set<String> ADMIN_CATEGORIES = Set.of("requests", "definitions", "access", "configuration");

    private final AuditQuery query;
    private final EntitlementService entitlements;
    private final HierarchyRepository hierarchies;
    private final BusinessClock clock;
    private final Cursors cursors;
    private final JdbcClient jdbc;

    public AuditController(AuditQuery query, EntitlementService entitlements, HierarchyRepository hierarchies, BusinessClock clock,
                           Cursors cursors, JdbcClient jdbc) {
        this.query = query;
        this.entitlements = entitlements;
        this.hierarchies = hierarchies;
        this.clock = clock;
        this.cursors = cursors;
        this.jdbc = jdbc;
    }

    /**
     * {@code from} and {@code to} are business dates (inclusive) of when the change was recorded; default the last 30 days.
     * {@code user} is a login (requester, decider or applying actor); {@code hierarchy} and {@code property} are codes.
     */
    @GetMapping
    public Page<AuditEntry> searchAudit(Actor actor,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate from,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate to,
            @RequestParam(required = false) String user,
            @RequestParam(required = false) String hierarchy,
            @RequestParam(required = false) UUID node,
            @RequestParam(required = false) String property,
            @RequestParam(required = false) UUID request,
            @RequestParam(required = false) List<String> category,
            @RequestParam(defaultValue = "false") boolean includeSuperseded,
            @RequestParam(required = false) String cursor,
            @RequestParam(defaultValue = "" + DEFAULT_LIMIT) int limit) {
        if (limit < 1 || limit > MAX_LIMIT) {
            throw ItemValidationException.field("limit", "must be between 1 and " + MAX_LIMIT);
        }
        Optional<Set<UUID>> readable = entitlements.readableHierarchies(actor);
        boolean admin = entitlements.hasAny(actor, Permission.ADMIN_SYSTEM);
        if (!admin && readable.map(Set::isEmpty).orElse(false)) {
            throw new ForbiddenException("entitlement.missing", "You can't read any hierarchy, so there is no history to show.");
        }

        Set<String> categories = new LinkedHashSet<>(category == null || category.isEmpty() ? List.of("data") : category);
        for (String c : categories) {
            if (!AuditQuery.CATEGORIES.containsKey(c)) {
                throw ItemValidationException.field("category", "must be one of " + AuditQuery.CATEGORIES.keySet());
            }
            if (!admin && ADMIN_CATEGORIES.contains(c)) {
                throw new ForbiddenException("entitlement.missing", "Only an ADMIN can see the " + c + " history.");
            }
        }

        LocalDate today = clock.today();
        LocalDate last = to == null ? today : to;
        LocalDate first = from == null ? last.minusDays(DEFAULT_DAYS - 1L) : from;
        if (first.isAfter(last)) {
            throw ItemValidationException.field("from", "must be on or before 'to'");
        }
        if (ChronoUnit.DAYS.between(first, last) + 1 > MAX_DAYS_UNFILTERED && request == null && node == null && user == null) {
            throw ItemValidationException.field("from", "a search over more than " + MAX_DAYS_UNFILTERED
                    + " days needs a request, node or user filter");
        }

        UUID userId = user == null ? null : lookup("SELECT user_id FROM mdm.app_user WHERE login = :c", user, "user");
        UUID hierarchyId = hierarchy == null ? null
                : hierarchies.findIdByCode(hierarchy).orElseThrow(() -> ItemValidationException.field("hierarchy", "unknown hierarchy " + hierarchy));
        UUID propertyId = property == null ? null
                : lookup("SELECT property_id FROM mdm.property_definition WHERE property_code = :c", property, "property");

        List<String> key = cursors.decode(cursor, 3);
        Criteria criteria = new Criteria(start(first), start(last.plusDays(1)), userId, hierarchyId, node, propertyId, request,
                categories, includeSuperseded, admin, admin ? null : readable.orElse(null),
                key == null ? null : Instant.parse(key.get(0)), key == null ? null : key.get(1),
                key == null ? null : Long.valueOf(key.get(2)), limit);
        List<Row> rows = query.search(criteria);
        boolean more = rows.size() > limit;
        List<Row> page = more ? rows.subList(0, limit) : rows;
        String next = null;
        if (more) {
            Row lastRow = page.get(page.size() - 1);
            next = cursors.encode(lastRow.occurredAt().toString(), lastRow.source(), String.valueOf(lastRow.auditId()));
        }
        return new Page<>(page.stream().map(Row::entry).toList(), next);
    }

    private Instant start(LocalDate d) {
        return d.atStartOfDay(clock.zone()).toInstant();
    }

    private UUID lookup(String sql, String value, String field) {
        return jdbc.sql(sql).param("c", value).query(UUID.class).optional()
                .orElseThrow(() -> ItemValidationException.field(field, "unknown " + field + " " + value));
    }
}
