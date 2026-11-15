package com.mdm.api.query;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.common.BusinessClock;
import com.mdm.api.common.ETags;
import com.mdm.api.common.ItemValidationException;
import com.mdm.api.common.NotFoundException;
import com.mdm.api.common.RuleException;
import com.mdm.api.hierarchy.HierarchyRepository;
import com.mdm.api.query.QueryDtos.QueryCell;
import com.mdm.api.query.QueryDtos.QueryDefinition;
import com.mdm.api.query.QueryDtos.QueryPage;
import com.mdm.api.query.QueryDtos.QueryRow;
import com.mdm.api.query.QueryDtos.SaveQuery;
import com.mdm.api.query.QueryDtos.SavedQueryView;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import com.mdm.api.security.ForbiddenException;
import com.mdm.api.security.Permission;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * Property queries (QRY-01; Phase 5 LLD §17.5). A query runs against one hierarchy at a slice and returns the matching
 * nodes in (name, id) order with the chosen columns. Each page examines at most {@code query_scan_max} candidates; when
 * that budget runs out first, the page is partial and its cursor continues the scan, so results are never cut short
 * silently.
 * <p>Read scope (ADR-041): until 5-5 the runner filters by readable hierarchy, as every read does today; a hierarchy
 * the caller cannot read is not found. Saved queries are the owner's; a shared one is visible to those who can read its
 * hierarchy, and runs with the runner's own scope.
 */
@Service
public class QueryService {

    static final int CHUNK = 1000;                     // BATCH_FETCH_SIZE (OPEN_DECISIONS)
    private static final Set<String> INCLUDE = Set.of("all", "leaves", "limbs");
    private static final Set<String> VISIBILITY = Set.of("private", "shared");

    private final QueryRepository repository;
    private final QueryPlanner planner;
    private final HierarchyRepository hierarchies;
    private final EntitlementService entitlements;
    private final BusinessClock clock;
    private final ObjectMapper mapper;

    public QueryService(QueryRepository repository, QueryPlanner planner, HierarchyRepository hierarchies,
                        EntitlementService entitlements, BusinessClock clock, ObjectMapper mapper) {
        this.repository = repository;
        this.planner = planner;
        this.hierarchies = hierarchies;
        this.entitlements = entitlements;
        this.clock = clock;
        this.mapper = mapper;
    }

    /** Where a page continues: after the candidate with this (name, id). */
    public record Position(String name, UUID id) {
    }

    /** The slice of a run: a version's, or a business date and recorded time (default today, as recorded now). */
    public record RunSlice(LocalDate asOf, Instant recordedAsOf, String version) {
    }

    // ------------------------------------------------------------------ running

    @Transactional(readOnly = true)
    public QueryPage run(Actor actor, QueryDefinition definition, RunSlice slice, Position after, int limit,
                         java.util.function.Function<Position, String> cursorOf) {
        Checked q = check(actor, definition);
        LocalDate asOf;
        Instant rec;
        if (slice.version() != null) {
            Object[] v = repository.versionSlice(slice.version())
                    .orElseThrow(() -> ItemValidationException.field("version", "unknown version " + slice.version()));
            asOf = (LocalDate) v[0];
            rec = v[1] == null ? clock.now() : (Instant) v[1];
        } else {
            asOf = slice.asOf() == null ? clock.today() : slice.asOf();
            rec = slice.recordedAsOf() == null ? clock.now() : slice.recordedAsOf();
        }

        int budget = repository.setting("query_scan_max", 50_000);
        List<QueryRow> rows = new ArrayList<>();
        Position position = after;
        long scanned = 0;
        boolean more = true;
        boolean full = false;
        while (more && !full && scanned < budget) {
            int size = (int) Math.min(CHUNK, budget - scanned);
            List<QueryRepository.Candidate> chunk = repository.chunk(q.hierarchyId(), definition.rootNodeId(), q.include(),
                    Boolean.TRUE.equals(definition.includeInactive()), asOf, rec, q.compiled(), q.plan(), q.filterProps(),
                    q.allProps(), position == null ? null : position.name(), position == null ? null : position.id(), size);
            more = chunk.size() == size;
            for (QueryRepository.Candidate c : chunk) {
                scanned++;
                position = new Position(c.name(), c.nodeId());
                if (c.hit()) {
                    if (rows.size() == limit) {
                        // one more match than the page holds: the page is full and the next one starts at this match
                        scanned--;
                        full = true;
                        position = rows.isEmpty() ? position : lastOf(rows);
                        break;
                    }
                    rows.add(row(c, q.columns()));
                }
            }
        }
        boolean partial = !full && more && scanned >= budget;
        String next = full || partial ? cursorOf.apply(position) : null;
        return new QueryPage(rows, next, scanned, partial);
    }

    private static Position lastOf(List<QueryRow> rows) {
        QueryRow last = rows.get(rows.size() - 1);
        return new Position(last.name(), last.nodeId());
    }

    private QueryRow row(QueryRepository.Candidate c, List<String> columns) {
        List<QueryCell> cells = new ArrayList<>();
        for (String code : columns) {
            JsonNode v = c.values().path(code);
            JsonNode value = v.get("value");                   // a stored explicit blank is null with provenance "stored"
            cells.add(new QueryCell(code, value == null || value.isNull() ? null : value,
                    v.path("provenance").asText("none"),
                    v.hasNonNull("source") ? UUID.fromString(v.get("source").asText()) : null));
        }
        return new QueryRow(c.nodeId(), c.name(), c.parentName(), c.leaf(), cells);
    }

    /** A definition checked once: hierarchy, scope, columns, the compiled filter and its plan. */
    private record Checked(UUID hierarchyId, String include, JsonNode compiled, QueryPlanner.Plan plan, List<UUID> filterProps,
                           List<UUID> allProps, List<String> columns) {
    }

    private Checked check(Actor actor, QueryDefinition d) {
        if (d == null) {
            throw ItemValidationException.field("definition", "is required");
        }
        if (d.hierarchyCode() == null || d.hierarchyCode().isBlank()) {
            throw ItemValidationException.field("definition.hierarchyCode", "is required");
        }
        UUID hierarchyId = hierarchies.findIdByCode(d.hierarchyCode()).filter(h -> entitlements.canRead(actor, h))
                .orElseThrow(() -> new NotFoundException("Hierarchy " + d.hierarchyCode() + " not found"));
        String include = d.include() == null ? "all" : d.include();
        if (!INCLUDE.contains(include)) {
            throw ItemValidationException.field("definition.include", "must be all, leaves or limbs");
        }
        List<String> columns = d.columns() == null ? List.of() : List.copyOf(new LinkedHashSet<>(d.columns()));
        int maxColumns = repository.setting("query_max_columns", 50);
        if (columns.size() > maxColumns) {
            throw new RuleException("query.too_many_columns", "A query shows at most " + maxColumns + " columns.");
        }
        JsonNode compiled = repository.compile(d.where() == null ? mapper.createObjectNode().set("all", mapper.createArrayNode()) : d.where());
        Set<String> codes = new LinkedHashSet<>(columns);
        compiled.get("props").forEach(p -> codes.add(p.get("code").asText()));
        Map<String, QueryPlanner.PropertyInfo> props = repository.properties(codes);
        for (String c : columns) {
            if (!props.containsKey(c)) {
                throw new RuleException("query.unknown_column", "There is no property " + c + " to show as a column.");
            }
        }
        QueryPlanner.Plan plan = planner.plan(compiled.get("tree"), props);
        if (plan.java() > 0) {
            // ADR-041: no CEL engine before 5-10, so no CEL-derived property can be compared yet
            throw new RuleException("query.cel_not_available",
                    "This query compares a formula-derived property, which queries cannot evaluate yet.");
        }
        List<UUID> filterProps = new ArrayList<>();
        compiled.get("props").forEach(p -> filterProps.add(UUID.fromString(p.get("id").asText())));
        List<UUID> allProps = codes.stream().map(props::get).map(QueryPlanner.PropertyInfo::id).distinct().toList();
        return new Checked(hierarchyId, include, compiled, plan, filterProps, allProps, columns);
    }

    // ------------------------------------------------------------------ saved queries

    @Transactional(readOnly = true)
    public List<SavedQueryView> listSaved(Actor actor, String afterName, UUID afterId, int limit) {
        return repository.listSaved(actor.userId(), entitlements.readableHierarchies(actor).orElse(null), afterName, afterId, limit);
    }

    @Transactional(readOnly = true)
    public SavedQueryView getSaved(Actor actor, UUID id) {
        return visible(actor, repository.saved(id, actor.userId()), id);
    }

    @Transactional
    public SavedQueryView save(Actor actor, SaveQuery body) {
        if (!entitlements.hasAny(actor, Permission.READ)) {
            throw new ForbiddenException("entitlement.missing", "You don't have read access to any hierarchy.");
        }
        Valid v = validate(actor, body);
        int max = repository.setting("saved_query_max_per_user", 200);
        if (repository.ownedCount(actor.userId()) >= max) {
            throw new RuleException("query.too_many_saved", "You already have " + max + " saved queries. Delete one first.");
        }
        UUID id = repository.insertSaved(actor.userId(), v.name(), body.description(), v.hierarchyId(), v.definition(), v.visibility());
        return repository.saved(id, actor.userId()).orElseThrow();
    }

    @Transactional
    public SavedQueryView update(Actor actor, UUID id, String ifMatch, SaveQuery body) {
        int expected = ETags.require(ifMatch);
        SavedQueryView current = own(actor, repository.lockSaved(id, actor.userId()), id);
        ETags.check(expected, current.rowVersion());
        Valid v = validate(actor, body);
        repository.updateSaved(id, v.name(), body.description(), v.hierarchyId(), v.definition(), v.visibility());
        return repository.saved(id, actor.userId()).orElseThrow();
    }

    @Transactional
    public void delete(Actor actor, UUID id, String ifMatch) {
        int expected = ETags.require(ifMatch);
        SavedQueryView current = own(actor, repository.lockSaved(id, actor.userId()), id);
        ETags.check(expected, current.rowVersion());
        repository.deleteSaved(id);
    }

    private record Valid(String name, UUID hierarchyId, JsonNode definition, String visibility) {
    }

    /** A definition is checked when it is saved, with the same checks as a run (N2604, N2605, N2807). */
    private Valid validate(Actor actor, SaveQuery body) {
        if (body == null || body.name() == null || body.name().isBlank()) {
            throw ItemValidationException.field("name", "is required");
        }
        String visibility = body.visibility() == null ? "private" : body.visibility();
        if (!VISIBILITY.contains(visibility)) {
            throw ItemValidationException.field("visibility", "must be private or shared");
        }
        Checked c = check(actor, body.definition());
        return new Valid(body.name().trim(), c.hierarchyId(), mapper.valueToTree(body.definition()), visibility);
    }

    private SavedQueryView visible(Actor actor, Optional<SavedQueryView> q, UUID id) {
        SavedQueryView v = q.orElseThrow(() -> notFound(id));
        if (v.mine()) {
            return v;
        }
        boolean readable = v.hierarchyCode() == null || hierarchies.findIdByCode(v.hierarchyCode())
                .map(h -> entitlements.canRead(actor, h)).orElse(false);
        if (!"shared".equals(v.visibility()) || !readable) {
            throw notFound(id);
        }
        return v;
    }

    private SavedQueryView own(Actor actor, Optional<SavedQueryView> q, UUID id) {
        SavedQueryView v = visible(actor, q, id);
        if (!v.mine()) {
            throw new ForbiddenException("query.not_owner", "Only the owner can change this saved query.");
        }
        return v;
    }

    private static NotFoundException notFound(UUID id) {
        return new NotFoundException("Saved query " + id + " not found");
    }
}
