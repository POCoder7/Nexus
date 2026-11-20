package com.mdm.api.load;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.mdm.api.apply.ApplyService;
import com.mdm.api.common.BusinessClock;
import com.mdm.api.common.NotFoundException;
import com.mdm.api.common.RuleException;
import com.mdm.api.security.Actor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.io.Resource;
import org.springframework.core.io.support.PathMatchingResourcePatternResolver;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.io.IOException;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.Deque;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * Load runs for the hackathon data set (ADR-046; Phase 4 LLD §4.3, §6.1, §17.6 to §17.8; increment H-6).
 * <ol>
 *   <li><b>Prepare</b> (an ADMIN): a clean staged load (no profiling errors, no collisions with Nexus) gets a plan and a
 *   manifest: the SHA-256 of the staged files' hashes, the target version and the rule library.</li>
 *   <li><b>Approve</b> (a second ADMIN, a person): the approver confirms the manifest hash they reviewed.</li>
 *   <li><b>Apply</b> (the approver): versions; configuration under the approved run; one change request per hierarchy for
 *   its top node; each hierarchy's nodes, placements and values; the access request; version transitions; then a
 *   reconciliation. Every request is drafted by the loader (requester kind system_feed, so import rules run), or by the
 *   preparer for access (only an ADMIN may propose access), validated, submitted, decided by the approver and applied.</li>
 * </ol>
 * Requests are drafted at apply, not at prepare: items need the hierarchies earlier requests create. The approver
 * approves the manifest from which they are derived, deterministically (OD-29 option A).
 */
@Service
public class LoadRunService {

    private static final Logger log = LoggerFactory.getLogger(LoadRunService.class);
    private static final String LOADER_LOGIN = "system.loader";

    public record RunRequest(int seq, String step, UUID changeRequestId, String status) {
    }

    public record LoadRunView(UUID id, String status, String targetVersion, String manifestSha256, JsonNode plan,
                              String preparedBy, Instant preparedAt, String approvedBy, Instant approvedAt, Instant finishedAt,
                              JsonNode report, String error, List<RunRequest> requests) {
    }

    private final JdbcClient jdbc;
    private final ObjectMapper mapper;
    private final ApplyService applies;
    private final BusinessClock clock;
    private final TransactionTemplate tx;
    private final int maxItems;

    public LoadRunService(JdbcClient jdbc, ObjectMapper mapper, ApplyService applies, BusinessClock clock,
                          PlatformTransactionManager transactions) {
        this.jdbc = jdbc;
        this.mapper = mapper;
        this.applies = applies;
        this.clock = clock;
        this.tx = new TransactionTemplate(transactions);
        this.maxItems = jdbc.sql("SELECT coalesce(max(setting_value::int), 5000) FROM mdm.system_setting WHERE setting_key = 'max_items_per_change_request'")
                .query(Integer.class).single();
    }

    // ------------------------------------------------------------------ prepare, approve, cancel

    public LoadRunView prepare(Actor actor, UUID loadId, String versionName) {
        if (!exists("SELECT EXISTS (SELECT 1 FROM mdm_stage.intake_batch WHERE load_id = :l)", loadId)) {
            throw new NotFoundException("Nothing is staged for load " + loadId);
        }
        if (exists("SELECT EXISTS (SELECT 1 FROM mdm.load_run WHERE load_run_id = :l)", loadId)) {
            throw new RuleException("load.already_prepared", "This load has already been prepared.");
        }
        int errors = jdbc.sql("SELECT mdm_stage.profile(:l) + mdm_stage.profile_against_nexus(:l)").param("l", loadId)
                .query(Integer.class).single();
        if (errors > 0) {
            throw new RuleException("load.has_errors", "The staged files have " + errors + " error(s). Fix them and stage the files again.");
        }
        Staged s = staged(loadId);
        String target = targetVersion(s, versionName);
        Map<String, String> library = library();
        ObjectNode plan = plan(s, target, library);
        String manifest = manifest(loadId, target, library);
        jdbc.sql("""
                INSERT INTO mdm.load_run (load_run_id, target_version_name, manifest_sha256, plan, prepared_by)
                VALUES (:id, :v, :sha, CAST(:plan AS jsonb), :by)
                """).param("id", loadId).param("v", target).param("sha", manifest).param("plan", json(plan))
                .param("by", actor.userId()).update();
        return get(loadId);
    }

    public LoadRunView approve(Actor actor, UUID runId, String manifestSha256) {
        LoadRunView run = get(runId);
        if (!"prepared".equals(run.status())) {
            throw new RuleException("load.status_transition", "Only a prepared load can be approved (this one is " + run.status() + ").");
        }
        if (manifestSha256 == null || !manifestSha256.equalsIgnoreCase(run.manifestSha256())) {
            throw new RuleException("load.manifest_mismatch", "The manifest you reviewed is not this load's manifest. Reload it and review again.");
        }
        jdbc.sql("UPDATE mdm.load_run SET status = 'approved', approved_by = :a, approved_at = now() WHERE load_run_id = :id AND status = 'prepared'")
                .param("a", actor.userId()).param("id", runId).update();
        return get(runId);
    }

    public LoadRunView cancel(Actor actor, UUID runId) {
        int n = jdbc.sql("UPDATE mdm.load_run SET status = 'cancelled' WHERE load_run_id = :id AND status IN ('prepared', 'approved')")
                .param("id", runId).update();
        if (n == 0) {
            throw new RuleException("load.status_transition", "Only a prepared or approved load can be cancelled.");
        }
        log.info("load_run.cancelled loadRunId={} actorId={}", runId, actor.userId());
        return get(runId);
    }

    // ------------------------------------------------------------------ apply

    public LoadRunView apply(Actor actor, UUID runId) {
        LoadRunView run = get(runId);
        if (!actor.login().equals(run.approvedBy())) {
            throw new RuleException("load.not_approver", "The load is applied by the ADMIN who approved it.");
        }
        int started = jdbc.sql("UPDATE mdm.load_run SET status = 'applying' WHERE load_run_id = :id AND status = 'approved'")
                .param("id", runId).update();
        if (started == 0) {
            throw new RuleException("load.status_transition", "Only an approved load can be applied (this one is " + run.status() + ").");
        }
        UUID approver = actor.userId();
        UUID preparer = jdbc.sql("SELECT prepared_by FROM mdm.load_run WHERE load_run_id = :id").param("id", runId).query(UUID.class).single();
        Applying a = new Applying(runId, staged(runId), approver, preparer, userId(LOADER_LOGIN), clock.today());
        ObjectNode report = JsonNodeFactory.instance.objectNode();
        try {
            report.set("versions", createVersions(a));
            a.versionId = jdbc.sql("SELECT version_id FROM mdm.version WHERE version_name = :n").param("n", run.targetVersion())
                    .query(UUID.class).single();
            report.set("definitions", mapper.readTree(jdbc.sql("SELECT CAST(mdm.load_apply_definitions(:r, :a, CAST(:lib AS jsonb)) AS text)")
                    .param("r", runId).param("a", approver).param("lib", json(libraryFor(a.s))).query(String.class).single()));
            hierarchies(a);
            report.set("scopes", mapper.readTree(jdbc.sql("SELECT CAST(mdm.load_apply_scopes(:r, :a) AS text)")
                    .param("r", runId).param("a", approver).query(String.class).single()));
            structureAndValues(a);
            report.set("access", access(a));
            report.set("versionTransitions", transitions(a));
            report.set("reconciliation", reconcile(a));
            finish(runId, "applied", report, null);
        } catch (RuntimeException | IOException e) {
            log.error("load_run.failed loadRunId={} reason=\"{}\"", runId, e.getMessage());
            finish(runId, "failed", report, e.getMessage());
        }
        return get(runId);
    }

    private void finish(UUID runId, String status, JsonNode report, String error) {
        jdbc.sql("UPDATE mdm.load_run SET status = :s, finished_at = now(), report = CAST(:r AS jsonb), error = :e WHERE load_run_id = :id")
                .param("s", status).param("r", json(report)).param("e", error).param("id", runId).update();
    }

    /** State while applying: who, which version, and the node ids allocated so far by code. */
    private static final class Applying {
        final UUID runId;
        final Staged s;
        final UUID approver;
        final UUID preparer;
        final UUID loader;
        final LocalDate today;
        final Map<String, UUID> nodeIds = new TreeMap<>();
        final Map<String, UUID> hierarchyIds = new TreeMap<>();
        UUID versionId;
        int seq;

        Applying(UUID runId, Staged s, UUID approver, UUID preparer, UUID loader, LocalDate today) {
            this.runId = runId;
            this.s = s;
            this.approver = approver;
            this.preparer = preparer;
            this.loader = loader;
            this.today = today;
        }
    }

    /** One item of a request being drafted; {@code nodeKind} set = allocate a new node and remember it under {@code code}. */
    private record Item(String action, UUID hierarchyId, String code, String nodeKind, UUID nodeId, UUID parentId, UUID propertyId,
                        ObjectNode payload) {
    }

    private JsonNode createVersions(Applying a) {
        ArrayNode created = JsonNodeFactory.instance.arrayNode();
        for (Map<String, String> v : a.s.versions) {
            jdbc.sql("SELECT mdm.create_version(:n, :d, NULL, :desc, :a)").param("n", v.get("version_name")).param("d", a.today)
                    .param("desc", v.get("description")).param("a", a.approver).query(UUID.class).single();
            created.add(v.get("version_name"));
        }
        return created;
    }

    private void hierarchies(Applying a) {
        for (Map<String, String> h : a.s.hierarchies) {
            String top = h.get("top_node_code");
            Map<String, String> topNode = a.s.nodes.get(top);
            ObjectNode topPayload = JsonNodeFactory.instance.objectNode().put("nodeKind", "structural").put("name", top);
            putIf(topPayload, "displayName", topNode.get("node_name"));
            putIf(topPayload, "description", topNode.get("description"));
            ObjectNode payload = JsonNodeFactory.instance.objectNode().put("code", h.get("hierarchy_code")).put("name", h.get("hierarchy_name"));
            putIf(payload, "description", h.get("description"));
            payload.set("topNode", topPayload);
            request(a, "hierarchy " + h.get("hierarchy_code"), "Create hierarchy " + h.get("hierarchy_code"), a.loader, "system_feed",
                    List.of(new Item("add_hierarchy", null, top, "structural", null, null, null, payload)));
            a.hierarchyIds.put(h.get("hierarchy_code"), jdbc.sql("SELECT hierarchy_id FROM mdm.hierarchy WHERE hierarchy_code = :c")
                    .param("c", h.get("hierarchy_code")).query(UUID.class).single());
        }
    }

    /** Per hierarchy: new nodes and placements (parents first), then the values whose home is this hierarchy. */
    private void structureAndValues(Applying a) {
        Map<String, String> home = valueHomes(a.s);
        Map<String, UUID> propertyIds = jdbc.sql("SELECT property_code, property_id FROM mdm.property_definition")
                .query((rs, i) -> Map.entry(rs.getString(1), rs.getObject(2, UUID.class))).list().stream()
                .collect(Collectors.toMap(Map.Entry::getKey, Map.Entry::getValue));
        for (Map<String, String> h : a.s.hierarchies) {
            String code = h.get("hierarchy_code");
            UUID hid = a.hierarchyIds.get(code);
            List<Item> items = new ArrayList<>();
            for (Map<String, String> r : a.s.parentsFirst(code)) {
                Map<String, String> n = a.s.nodes.get(r.get("child_code"));
                ObjectNode p = JsonNodeFactory.instance.objectNode();
                if (r.get("sort_order") != null) {
                    p.put("sortOrder", new BigDecimal(r.get("sort_order")));
                }
                String child = r.get("child_code");
                if (a.nodeIds.containsKey(child) || items.stream().anyMatch(i -> child.equals(i.code()) && i.nodeKind() != null)) {
                    items.add(new Item("insert_node", hid, child, null, null, null, null, p));
                } else {
                    p.put("name", child).put("isLeaf", "LEAF".equalsIgnoreCase(n.get("node_type")))
                            .put("active", "active".equalsIgnoreCase(n.get("status")));
                    putIf(p, "displayName", n.get("node_name"));
                    putIf(p, "description", n.get("description"));
                    items.add(new Item("add_node", hid, child, "structural", null, null, null, p));
                }
                items.set(items.size() - 1, withParent(items.get(items.size() - 1), r.get("parent_code")));
            }
            for (Map<String, String> v : a.s.values) {
                Map<String, String> d = a.s.definitions.get(v.get("attribute_code"));
                if (d == null || d.get("derivation") != null) {
                    continue;
                }
                boolean local = v.get("hierarchy_code") != null;
                String valueHome = local ? v.get("hierarchy_code") : home.get(v.get("node_code") + "|" + v.get("attribute_code"));
                if (!code.equals(valueHome)) {
                    continue;
                }
                ObjectNode p = JsonNodeFactory.instance.objectNode();
                p.set("value", typed(d, v.get("value")));
                items.add(new Item("set_property", hid, v.get("node_code"), null, null, null, propertyIds.get(v.get("attribute_code")), p));
            }
            for (int from = 0; from < items.size(); from += maxItems) {
                List<Item> chunk = items.subList(from, Math.min(items.size(), from + maxItems));
                request(a, "nodes " + code, "Load nodes and values of " + code + (items.size() > maxItems ? " (part " + (from / maxItems + 1) + ")" : ""),
                        a.loader, "system_feed", chunk);
            }
        }
    }

    /** Parents are resolved when the request is drafted: a node created earlier in the same request has its id by then. */
    private static Item withParent(Item i, String parentCode) {
        ObjectNode p = i.payload().deepCopy();
        p.put("_parentCode", parentCode);
        return new Item(i.action(), i.hierarchyId(), i.code(), i.nodeKind(), i.nodeId(), null, i.propertyId(), p);
    }

    /**
     * Where each global value is set: the first hierarchy (in file order) the node is placed in where the attribute
     * applies, so the applicability guard (N2025) holds when it is written.
     */
    private static Map<String, String> valueHomes(Staged s) {
        Map<String, String> home = new LinkedHashMap<>();
        for (Map<String, String> v : s.values) {
            if (v.get("hierarchy_code") != null) {
                continue;
            }
            Map<String, String> d = s.definitions.get(v.get("attribute_code"));
            Set<String> listed = d == null || d.get("hierarchies") == null ? Set.of()
                    : Arrays.stream(d.get("hierarchies").split(";")).map(String::strip).filter(x -> !x.isEmpty()).collect(Collectors.toSet());
            for (Map<String, String> h : s.hierarchies) {
                String code = h.get("hierarchy_code");
                if ((listed.isEmpty() || listed.contains(code)) && s.placedIn(v.get("node_code"), code)) {
                    home.put(v.get("node_code") + "|" + v.get("attribute_code"), code);
                    break;
                }
            }
        }
        return home;
    }

    private JsonNode access(Applying a) {
        List<Item> items = new ArrayList<>();
        ArrayNode skipped = JsonNodeFactory.instance.arrayNode();
        String preparerLogin = login(a.preparer);
        String approverLogin = login(a.approver);
        for (Map<String, String> g : a.s.groups) {
            String group = g.get("group_code");
            boolean exists = exists("SELECT EXISTS (SELECT 1 FROM mdm.user_group WHERE group_code = :l)", group);
            if (!exists) {
                items.add(access("create_group", JsonNodeFactory.instance.objectNode().put("group", group).put("name", group)
                        .put("role", g.get("role").toUpperCase(Locale.ROOT))));
            }
            for (String h : split(g.get("hierarchies"))) {
                if (!exists || !exists("""
                        SELECT EXISTS (SELECT 1 FROM mdm.user_group_scope s JOIN mdm.user_group g ON g.group_id = s.group_id
                        JOIN mdm.hierarchy h ON h.hierarchy_id = s.hierarchy_id
                        WHERE g.group_code = :l AND h.hierarchy_code = :x AND upper_inf(s.recorded_period) AND s.valid_period @> mdm.business_today())
                        """, group, h)) {
                    items.add(access("add_group_scope", JsonNodeFactory.instance.objectNode().put("group", group).put("hierarchy", h)));
                }
            }
        }
        for (Map<String, String> u : a.s.users) {
            String user = u.get("user_id");
            for (String group : split(u.get("groups"))) {
                boolean all = "ALL".equalsIgnoreCase(group);
                if (user.equals(preparerLogin) || user.equals(approverLogin)) {
                    skipped.add(user + (all ? " (" + u.get("role") + " on every hierarchy)" : " in " + group)
                            + ": nobody grants themselves access, so this is left to another ADMIN");
                    continue;
                }
                if (all) {
                    if (!exists("""
                            SELECT EXISTS (SELECT 1 FROM mdm.user_role r JOIN mdm.app_user u ON u.user_id = r.user_id
                            WHERE u.login = :l AND r.role_code = :x AND r.hierarchy_id IS NULL AND upper_inf(r.recorded_period)
                              AND r.valid_period @> mdm.business_today())
                            """, user, u.get("role").toUpperCase(Locale.ROOT))) {
                        items.add(access("grant_role", JsonNodeFactory.instance.objectNode().put("user", user)
                                .put("role", u.get("role").toUpperCase(Locale.ROOT))));
                    }
                } else if (!exists("""
                        SELECT EXISTS (SELECT 1 FROM mdm.user_group_member m JOIN mdm.user_group g ON g.group_id = m.group_id
                        JOIN mdm.app_user u ON u.user_id = m.user_id
                        WHERE u.login = :l AND g.group_code = :x AND upper_inf(m.recorded_period) AND m.valid_period @> mdm.business_today())
                        """, user, group)) {
                    items.add(access("add_group_member", JsonNodeFactory.instance.objectNode().put("user", user).put("group", group)));
                }
            }
        }
        ObjectNode out = JsonNodeFactory.instance.objectNode().put("items", items.size());
        out.set("skipped", skipped);
        if (!items.isEmpty()) {
            request(a, "access", "Load users and groups", a.preparer, "human", items);
        }
        return out;
    }

    private static Item access(String action, ObjectNode payload) {
        return new Item(action, null, null, null, null, null, null, payload);
    }

    private JsonNode transitions(Applying a) {
        ArrayNode done = JsonNodeFactory.instance.arrayNode();
        for (Map<String, String> v : a.s.versions) {
            String status = v.get("status").toLowerCase(Locale.ROOT);
            if ("working".equals(status)) {
                continue;
            }
            UUID id = jdbc.sql("SELECT version_id FROM mdm.version WHERE version_name = :n").param("n", v.get("version_name")).query(UUID.class).single();
            transition(id, "submitted", a.preparer);   // the preparer submits; a different ADMIN finalizes (V11 guard)
            transition(id, "finalized", a.approver);
            if ("expired".equals(status)) {
                transition(id, "expired", a.approver);
            }
            done.add(v.get("version_name") + " " + status);
        }
        return done;
    }

    private void transition(UUID version, String to, UUID actor) {
        jdbc.sql("SELECT mdm.transition_version(:v, :to, :why, :a)").param("v", version).param("to", to)
                .param("why", "Hackathon data load").param("a", actor).query((rs, i) -> 0).single();
    }

    /** Staged against applied, per hierarchy: placements (with the top node) and stored values. */
    private JsonNode reconcile(Applying a) {
        ArrayNode rows = JsonNodeFactory.instance.arrayNode();
        boolean clean = true;
        for (Map<String, String> h : a.s.hierarchies) {
            String code = h.get("hierarchy_code");
            long staged = a.s.relationships.stream().filter(r -> code.equals(r.get("hierarchy_code")) && r.get("parent_code") != null).count() + 1;
            long applied = jdbc.sql("""
                    SELECT 1 + count(*) FROM mdm.hierarchy_relationship r JOIN mdm.hierarchy h ON h.hierarchy_id = r.hierarchy_id
                    WHERE h.hierarchy_code = :c AND r.valid_period @> CAST(:d AS date) AND upper_inf(r.recorded_period)
                    """).param("c", code).param("d", a.today).query(Long.class).single();
            clean &= staged == applied;
            rows.add(JsonNodeFactory.instance.objectNode().put("hierarchy", code).put("placementsStaged", staged).put("placementsApplied", applied));
        }
        long valuesStaged = a.s.values.stream().filter(v -> {
            Map<String, String> d = a.s.definitions.get(v.get("attribute_code"));
            return d != null && d.get("derivation") == null;
        }).count();
        long valuesApplied = jdbc.sql("""
                SELECT count(*) FROM mdm.property_value v JOIN mdm.node_attr a ON a.node_id = v.node_id
                 AND a.valid_period @> CAST(:d AS date) AND upper_inf(a.recorded_period)
                WHERE a.node_name = ANY (CAST(:codes AS text[])) AND upper_inf(v.recorded_period) AND v.valid_period @> CAST(:d AS date)
                """).param("d", a.today).param("codes", a.s.nodes.keySet().toArray(String[]::new)).query(Long.class).single();
        clean &= valuesStaged == valuesApplied;
        ObjectNode out = JsonNodeFactory.instance.objectNode().put("clean", clean).put("valuesStaged", valuesStaged).put("valuesApplied", valuesApplied);
        out.set("hierarchies", rows);
        if (!clean) {
            throw new IllegalStateException("Reconciliation found differences: " + out);
        }
        return out;
    }

    /** Drafts, validates, submits, decides (as the approver) and applies one request; records it on the run. */
    private void request(Applying a, String step, String title, UUID requester, String requesterKind, List<Item> items) {
        UUID cr = tx.execute(st -> {
            UUID id = jdbc.sql("""
                    INSERT INTO mdm.change_request (version_id, title, requester_id, requester_kind, effective_from, origin, rationale)
                    VALUES (:v, :t, :r, CAST(:k AS mdm.requester_kind), :d, 'load', :why) RETURNING change_request_id
                    """).param("v", a.versionId).param("t", title).param("r", requester).param("k", requesterKind).param("d", a.today)
                    .param("why", "Load run " + a.runId).query(UUID.class).single();
            int seq = 0;
            for (Item i : items) {
                UUID node = i.nodeId();
                if (i.nodeKind() != null) {
                    node = jdbc.sql("SELECT mdm.allocate_node(CAST(:k AS mdm.node_kind), :cr)").param("k", i.nodeKind()).param("cr", id)
                            .query(UUID.class).single();
                    a.nodeIds.put(i.code(), node);
                } else if (i.code() != null) {
                    node = a.nodeIds.get(i.code());
                }
                ObjectNode payload = i.payload().deepCopy();
                UUID parent = i.parentId();
                if (payload.has("_parentCode")) {
                    parent = a.nodeIds.get(payload.get("_parentCode").asText());
                    payload.remove("_parentCode");
                }
                jdbc.sql("""
                        INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, target_parent_id, property_id, payload)
                        VALUES (:cr, :seq, CAST(:a AS mdm.change_action), :h, :n, :p, :prop, CAST(:pl AS jsonb))
                        """).param("cr", id).param("seq", ++seq).param("a", i.action()).param("h", i.hierarchyId()).param("n", node)
                        .param("p", parent).param("prop", i.propertyId()).param("pl", json(payload)).update();
            }
            List<String> errors = jdbc.sql("SELECT rule_code || ': ' || message FROM mdm.validate_change_request(:cr, :d) WHERE severity = 'error'")
                    .param("cr", id).param("d", a.today).query(String.class).list();
            if (!errors.isEmpty()) {
                throw new IllegalStateException(step + " failed validation: " + String.join("; ", errors.subList(0, Math.min(5, errors.size()))));
            }
            jdbc.sql("SELECT mdm.submit_change_request(:cr, :r)").param("cr", id).param("r", requester).query((rs, i) -> 0).single();
            jdbc.sql("SELECT mdm.decide_change_request(:cr, :a, 'approve', :note)").param("cr", id).param("a", a.approver)
                    .param("note", "Approved with load run " + a.runId).query((rs, i) -> 0).single();
            jdbc.sql("INSERT INTO mdm.load_run_request (load_run_id, seq, step, change_request_id) VALUES (:r, :s, :st, :cr)")
                    .param("r", a.runId).param("s", ++a.seq).param("st", step).param("cr", id).update();
            return id;
        });
        ApplyService.ApplyResult result = applies.apply(a.approver, cr);
        if (!"applied".equals(result.status())) {
            throw new IllegalStateException(step + " was not applied: " + result.applyError());
        }
    }

    // ------------------------------------------------------------------ reading

    public LoadRunView get(UUID runId) {
        List<RunRequest> requests = jdbc.sql("""
                SELECT r.seq, r.step, r.change_request_id, c.status::text FROM mdm.load_run_request r
                JOIN mdm.change_request c ON c.change_request_id = r.change_request_id WHERE r.load_run_id = :id ORDER BY r.seq
                """).param("id", runId).query((rs, i) -> new RunRequest(rs.getInt(1), rs.getString(2), rs.getObject(3, UUID.class), rs.getString(4)))
                .list();
        return jdbc.sql("""
                SELECT l.load_run_id, l.status, l.target_version_name, l.manifest_sha256, CAST(l.plan AS text) AS plan, p.login AS prepared_by,
                       l.prepared_at, a.login AS approved_by, l.approved_at, l.finished_at, CAST(l.report AS text) AS report, l.error
                FROM mdm.load_run l JOIN mdm.app_user p ON p.user_id = l.prepared_by LEFT JOIN mdm.app_user a ON a.user_id = l.approved_by
                WHERE l.load_run_id = :id
                """).param("id", runId)
                .query((rs, i) -> new LoadRunView(rs.getObject(1, UUID.class), rs.getString(2), rs.getString(3), rs.getString(4),
                        read(rs.getString(5)), rs.getString(6), instant(rs.getTimestamp(7)), rs.getString(8), instant(rs.getTimestamp(9)),
                        instant(rs.getTimestamp(10)), read(rs.getString(11)), rs.getString(12), requests))
                .optional().orElseThrow(() -> new NotFoundException("Load run " + runId + " not found"));
    }

    /** One keyset page of runs, newest first ({@code limit + 1} rows). */
    public List<LoadRunView> page(Instant before, int limit) {
        return jdbc.sql("""
                SELECT load_run_id FROM mdm.load_run WHERE CAST(:b AS timestamptz) IS NULL OR prepared_at < CAST(:b AS timestamptz)
                ORDER BY prepared_at DESC LIMIT :limit
                """).param("b", before == null ? null : Timestamp.from(before)).param("limit", limit + 1).query(UUID.class).list()
                .stream().map(this::get).toList();
    }

    // ------------------------------------------------------------------ staged data and the plan

    /** A staged load, read once: rows as column maps in file order. */
    private static final class Staged {
        List<Map<String, String>> hierarchies;
        Map<String, Map<String, String>> nodes;
        List<Map<String, String>> relationships;
        Map<String, Map<String, String>> definitions;
        List<Map<String, String>> values;
        List<Map<String, String>> versions;
        List<Map<String, String>> users;
        List<Map<String, String>> groups;
        List<Map<String, String>> rules;

        boolean placedIn(String node, String hierarchy) {
            return hierarchies.stream().anyMatch(h -> hierarchy.equals(h.get("hierarchy_code")) && node.equals(h.get("top_node_code")))
                    || relationships.stream().anyMatch(r -> hierarchy.equals(r.get("hierarchy_code")) && node.equals(r.get("child_code"))
                    && r.get("parent_code") != null);
        }

        /** The hierarchy's placements, parents before children, siblings by sort order (the top node row left out). */
        List<Map<String, String>> parentsFirst(String hierarchy) {
            String top = hierarchies.stream().filter(h -> hierarchy.equals(h.get("hierarchy_code"))).findFirst().orElseThrow().get("top_node_code");
            Map<String, List<Map<String, String>>> byParent = relationships.stream()
                    .filter(r -> hierarchy.equals(r.get("hierarchy_code")) && r.get("parent_code") != null)
                    .collect(Collectors.groupingBy(r -> r.get("parent_code"), LinkedHashMap::new, Collectors.toList()));
            List<Map<String, String>> out = new ArrayList<>();
            Deque<String> queue = new ArrayDeque<>(List.of(top));
            Set<String> seen = new java.util.HashSet<>();
            while (!queue.isEmpty()) {
                String parent = queue.poll();
                if (!seen.add(parent)) {
                    continue;
                }
                List<Map<String, String>> children = new ArrayList<>(byParent.getOrDefault(parent, List.of()));
                children.sort(Comparator.comparing((Map<String, String> r) -> r.get("sort_order") == null ? BigDecimal.ZERO : new BigDecimal(r.get("sort_order"))));
                for (Map<String, String> c : children) {
                    out.add(c);
                    queue.add(c.get("child_code"));
                }
            }
            return out;
        }
    }

    private Staged staged(UUID loadId) {
        Staged s = new Staged();
        s.hierarchies = rows("hx_hierarchy", loadId);
        s.nodes = rows("hx_node", loadId).stream().collect(Collectors.toMap(r -> r.get("node_code"), r -> r, (x, y) -> x, LinkedHashMap::new));
        s.relationships = rows("hx_relationship", loadId);
        s.definitions = rows("hx_attribute_definition", loadId).stream()
                .collect(Collectors.toMap(r -> r.get("attribute_code"), r -> r, (x, y) -> x, LinkedHashMap::new));
        s.values = rows("hx_attribute_value", loadId);
        s.versions = rows("hx_version", loadId);
        s.users = rows("hx_user", loadId);
        s.groups = rows("hx_group", loadId);
        s.rules = rows("hx_validation_rule", loadId);
        return s;
    }

    private List<Map<String, String>> rows(String table, UUID loadId) {
        // the table name is one of the fixed staging tables above, never user input
        return jdbc.sql("SELECT s.* FROM mdm_stage." + table + " s JOIN mdm_stage.intake_batch b USING (batch_id) WHERE b.load_id = :l ORDER BY s.line_no")
                .param("l", loadId).query().listOfRows().stream().map(r -> {
                    Map<String, String> m = new LinkedHashMap<>();
                    r.forEach((k, v) -> m.put(k, v == null ? null : v.toString()));
                    return m;
                }).toList();
    }

    /**
     * The target version (D7): the one named; else the staged versions' single working one; else the latest working
     * version in Nexus; none is an error (N2809).
     */
    private String targetVersion(Staged s, String named) {
        if (named != null && !named.isBlank()) {
            boolean staged = s.versions.stream().anyMatch(v -> named.equals(v.get("version_name")) && "working".equalsIgnoreCase(v.get("status")));
            boolean working = exists("SELECT EXISTS (SELECT 1 FROM mdm.version WHERE version_name = :l AND status = 'working')", named);
            if (!staged && !working) {
                throw new RuleException("load.version_not_working", "Version " + named + " is not a working version.");
            }
            return named;
        }
        List<String> stagedWorking = s.versions.stream().filter(v -> "working".equalsIgnoreCase(v.get("status")))
                .map(v -> v.get("version_name")).toList();
        if (stagedWorking.size() == 1) {
            return stagedWorking.get(0);
        }
        return jdbc.sql("SELECT version_name FROM mdm.version WHERE status = 'working' ORDER BY business_as_of DESC, created_at DESC LIMIT 1")
                .query(String.class).optional()
                .orElseThrow(() -> new RuleException("load.no_working_version", "There is no working version to load into. Create one first."));
    }

    private ObjectNode plan(Staged s, String target, Map<String, String> library) {
        ObjectNode plan = JsonNodeFactory.instance.objectNode().put("targetVersion", target);
        ArrayNode steps = plan.putArray("steps");
        steps.add(step("versions", "Create versions", s.versions.size()));
        long properties = s.definitions.values().stream().filter(d -> d.get("derivation") == null).count();
        steps.add(step("definitions", "Attributes, lists, ledgers, users and rules", properties));
        steps.add(step("hierarchies", "One request per hierarchy for its top node", s.hierarchies.size()));
        for (Map<String, String> h : s.hierarchies) {
            String code = h.get("hierarchy_code");
            long placements = s.relationships.stream().filter(r -> code.equals(r.get("hierarchy_code")) && r.get("parent_code") != null).count();
            steps.add(step("nodes " + code, "Nodes, placements and values of " + code, placements));
        }
        steps.add(step("access", "Groups, their hierarchies and members", s.groups.size() + s.users.size()));
        ObjectNode counts = plan.putObject("counts");
        counts.put("hierarchies", s.hierarchies.size()).put("nodes", s.nodes.size()).put("placements", s.relationships.size())
                .put("attributes", properties).put("values", s.values.size()).put("versions", s.versions.size())
                .put("users", s.users.size()).put("groups", s.groups.size());
        ObjectNode rules = plan.putObject("rules");
        rules.put("guardsRelabelled", jdbc.sql("SELECT count(*) FROM mdm.load_rule_guard_map").query(Integer.class).single());
        rules.put("withExpression", s.rules.stream().filter(r -> library.containsKey(r.get("rule_code") + ".sql")).count());
        ArrayNode inactive = rules.putArray("storedInactive");
        s.rules.stream().filter(r -> !"FEED".equalsIgnoreCase(r.get("level")) && !library.containsKey(r.get("rule_code") + ".sql"))
                .map(r -> r.get("rule_code")).filter(c -> !exists("SELECT EXISTS (SELECT 1 FROM mdm.load_rule_guard_map WHERE external_code = :l)", c))
                .forEach(inactive::add);
        ArrayNode skipped = plan.putArray("skipped");
        s.definitions.values().stream().filter(d -> d.get("derivation") != null).forEach(d -> skipped.add("attribute " + d.get("attribute_code") + " (derived)"));
        s.rules.stream().filter(r -> "FEED".equalsIgnoreCase(r.get("level"))).forEach(r -> skipped.add("rule " + r.get("rule_code") + " (FEED)"));
        s.nodes.keySet().stream().filter(n -> s.hierarchies.stream().noneMatch(h -> s.placedIn(n, h.get("hierarchy_code"))))
                .forEach(n -> skipped.add("node " + n + " (placed in no hierarchy)"));
        return plan;
    }

    private static ObjectNode step(String step, String label, long count) {
        return JsonNodeFactory.instance.objectNode().put("step", step).put("label", label).put("count", count);
    }

    /** SHA-256 over the staged files' hashes (by name), the target version and the rule library (by file). */
    private String manifest(UUID loadId, String target, Map<String, String> library) {
        StringBuilder sb = new StringBuilder();
        jdbc.sql("SELECT file_name || ':' || file_sha256 FROM mdm_stage.intake_batch WHERE load_id = :l ORDER BY file_name")
                .param("l", loadId).query(String.class).list().forEach(x -> sb.append(x).append('\n'));
        sb.append("version:").append(target).append('\n');
        library.forEach((name, sql) -> sb.append("rule:").append(name).append(':').append(sha256(sql)).append('\n'));
        return sha256(sb.toString());
    }

    // ------------------------------------------------------------------ rule library

    /** The library files by name (VR01.sql …), read from the classpath. */
    private Map<String, String> library() {
        Map<String, String> files = new TreeMap<>();
        try {
            for (Resource r : new PathMatchingResourcePatternResolver().getResources("classpath:load/rules/*.sql")) {
                files.put(r.getFilename(), r.getContentAsString(StandardCharsets.UTF_8));
            }
        } catch (IOException e) {
            throw new IllegalStateException("The rule library cannot be read", e);
        }
        return files;
    }

    /** Rule code to expression for this load, with {{hierarchy}} replaced by the rule's applies_to as a SQL literal. */
    private ObjectNode libraryFor(Staged s) {
        Map<String, String> files = library();
        ObjectNode out = JsonNodeFactory.instance.objectNode();
        for (Map<String, String> r : s.rules) {
            String sql = files.get(r.get("rule_code") + ".sql");
            if (sql != null) {
                String scope = r.get("applies_to") == null ? "ALL" : r.get("applies_to");
                out.put(r.get("rule_code"), sql.replace("{{hierarchy}}", "'" + scope.replace("'", "''") + "'").strip());
            }
        }
        return out;
    }

    // ------------------------------------------------------------------ helpers

    private static JsonNode typed(Map<String, String> d, String raw) {
        if (raw == null) {
            return JsonNodeFactory.instance.nullNode();
        }
        String type = d.get("data_type").toLowerCase(Locale.ROOT);
        if ("boolean".equals(type)) {
            return JsonNodeFactory.instance.booleanNode("Y".equalsIgnoreCase(raw));
        }
        if (d.get("reference_list") == null && ("integer".equals(type) || "decimal".equals(type))) {
            return JsonNodeFactory.instance.numberNode(new BigDecimal(raw));
        }
        return JsonNodeFactory.instance.textNode(raw);
    }

    private static List<String> split(String list) {
        return list == null ? List.of() : Arrays.stream(list.split(";")).map(String::strip).filter(x -> !x.isEmpty()).toList();
    }

    private static void putIf(ObjectNode n, String field, String value) {
        if (value != null) {
            n.put(field, value);
        }
    }

    private boolean exists(String sql, Object l) {
        return jdbc.sql(sql).param("l", l).query(Boolean.class).single();
    }

    private boolean exists(String sql, Object l, Object x) {
        return jdbc.sql(sql).param("l", l).param("x", x).query(Boolean.class).single();
    }

    private UUID userId(String login) {
        return jdbc.sql("SELECT user_id FROM mdm.app_user WHERE login = :l").param("l", login).query(UUID.class).single();
    }

    private String login(UUID user) {
        return jdbc.sql("SELECT login FROM mdm.app_user WHERE user_id = :u").param("u", user).query(String.class).single();
    }

    private String json(Object o) {
        try {
            return mapper.writeValueAsString(o);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException(e);
        }
    }

    private JsonNode read(String s) {
        try {
            return s == null ? null : mapper.readTree(s);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException(e);
        }
    }

    private static Instant instant(Timestamp t) {
        return t == null ? null : t.toInstant();
    }

    private static String sha256(String text) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }
}
