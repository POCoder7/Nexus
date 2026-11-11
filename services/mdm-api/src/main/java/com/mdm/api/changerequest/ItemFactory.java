package com.mdm.api.changerequest;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.mdm.api.changerequest.ChangeRequestDtos.ChangeRequestView;
import com.mdm.api.changerequest.ChangeRequestDtos.ItemCommand;
import com.mdm.api.changerequest.ChangeRequestDtos.ItemView;
import com.mdm.api.common.ItemValidationException;
import com.mdm.api.common.RuleException;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;

/**
 * Turns an {@link ItemCommand} into a change_item (Phase 1 LLD §3.2, §5.2, §7.3): validates the payload for the action,
 * resolves codes to ids, allocates the identity of a new node, and records in {@code payload.expected} the state the
 * item assumes, after the effect of earlier items of the same request. Apply re-checks everything under lock; these
 * checks give early, clear errors.
 */
@Component
public class ItemFactory {

    /** Actions built in Phase 1 (decided capabilities). Others are pending decision (inactivate, reorder, identifiers…). */
    static final Set<String> PHASE_1_ACTIONS = Set.of("add_node", "insert_node", "move_node", "remove_node", "delete_node",
            "update_node", "add_hierarchy", "set_property", "clear_property");

    private static final Map<String, Set<String>> ALLOWED_PAYLOAD = Map.of(
            "add_node", Set.of("nodeKind", "name", "description", "isLeaf", "sortOrder"),
            "insert_node", Set.of("sortOrder"),
            "move_node", Set.of("sortOrder"),
            "remove_node", Set.of("cascade"),
            "delete_node", Set.of(),
            "update_node", Set.of("name", "description"),
            "add_hierarchy", Set.of("code", "name", "purpose", "group", "allowSharedNodes", "sortSeq", "topNode"),
            "set_property", Set.of("value", "validTo"),
            "clear_property", Set.of());

    private static final Set<String> NODE_KINDS = Set.of("legal_entity", "natural_person", "trust", "fund", "partnership",
            "government_body", "structural");

    private final JdbcClient jdbc;
    private final ObjectMapper mapper;
    private final ChangeRequestRepository requests;

    public ItemFactory(JdbcClient jdbc, ObjectMapper mapper, ChangeRequestRepository requests) {
        this.jdbc = jdbc;
        this.mapper = mapper;
        this.requests = requests;
    }

    /** The item to insert, plus the (hierarchy, node) pairs the requester must have PROPOSE on. */
    public record NewItem(String action, UUID hierarchyId, UUID nodeId, UUID targetParentId, UUID propertyId,
                          ObjectNode payload, List<Scope> scopes) {
    }

    public record Scope(UUID hierarchyId, UUID nodeId) {
    }

    public NewItem build(ChangeRequestView cr, ItemCommand cmd, List<ItemView> earlier) {
        String action = cmd.action();
        if (action == null || action.isBlank()) {
            throw ItemValidationException.field("action", "is required");
        }
        if (!PHASE_1_ACTIONS.contains(action)) {
            throw new RuleException("change_item.action_not_available",
                    "The action '" + action + "' is not available yet (its capability is pending a decision or a later phase).");
        }
        ObjectNode payload = payloadOf(cmd, action);
        LocalDate d = cr.effectiveFrom();

        if ("add_hierarchy".equals(action)) {
            return addHierarchy(cr, payload);
        }

        HierarchyRow h = hierarchy(cmd.hierarchyCode());
        return switch (action) {
            case "add_node" -> addNode(cr, cmd, payload, h, d, earlier);
            case "insert_node", "move_node" -> placement(cmd, action, payload, h, d, earlier);
            case "remove_node" -> remove(cmd, payload, h, d, earlier);
            case "delete_node", "update_node" -> nodeLevel(cmd, action, payload, h, d, earlier);
            default -> property(cmd, action, payload, h, d, earlier);
        };
    }

    // ------------------------------------------------------------------ actions

    private NewItem addHierarchy(ChangeRequestView cr, ObjectNode payload) {
        require(payload, "code");
        require(payload, "name");
        JsonNode top = payload.get("topNode");
        if (top == null || !top.isObject() || !top.hasNonNull("name") || !top.hasNonNull("nodeKind")) {
            throw ItemValidationException.field("payload.topNode", "needs nodeKind and name");
        }
        nodeKind(top.get("nodeKind").asText(), "payload.topNode.nodeKind");
        String code = payload.get("code").asText();
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = :c").param("c", code).query(Integer.class).single() > 0) {
            throw new RuleException("hierarchy.code_exists", "A hierarchy with code " + code + " already exists.");
        }
        UUID topNode = requests.allocateNode(top.get("nodeKind").asText(), cr.id());
        return new NewItem("add_hierarchy", null, topNode, null, null, payload, List.of(new Scope(null, null)));
    }

    private NewItem addNode(ChangeRequestView cr, ItemCommand cmd, ObjectNode payload, HierarchyRow h, LocalDate d,
                            List<ItemView> earlier) {
        require(payload, "name");
        require(payload, "nodeKind");
        nodeKind(payload.get("nodeKind").asText(), "payload.nodeKind");
        UUID parent = requireId(cmd.targetParentId(), "targetParentId");
        Optional<ItemView> parentAddedEarlier = earlier.stream()
                .filter(e -> "add_node".equals(e.action()) && parent.equals(e.nodeId()) && h.code().equals(e.hierarchyCode()))
                .findFirst();
        if (parentAddedEarlier.isPresent()) {
            if (parentAddedEarlier.get().payload().path("isLeaf").asBoolean(false)) {   // like allows_children, default is not a leaf
                throw new RuleException("change_item.parent_is_leaf", "The new parent in this request is a leaf; it cannot have children.");
            }
        } else {
            if (!inHierarchy(parent, h, d)) {
                throw new RuleException("change_item.not_in_hierarchy", "The target parent is not in " + h.code() + " on " + d + ".");
            }
            if (!allowsChildren(parent, d)) {
                throw new RuleException("change_item.parent_is_leaf", "The target parent is a leaf; leaf nodes can't have children.");
            }
        }
        UUID node = requests.allocateNode(payload.get("nodeKind").asText(), cr.id());
        return new NewItem("add_node", h.id(), node, parent, null, payload, List.of(new Scope(h.id(), parent)));
    }

    private NewItem placement(ItemCommand cmd, String action, ObjectNode payload, HierarchyRow h, LocalDate d,
                              List<ItemView> earlier) {
        UUID node = requireId(cmd.nodeId(), "nodeId");
        UUID target = requireId(cmd.targetParentId(), "targetParentId");
        if (!inHierarchy(target, h, d) && !addedEarlier(target, h, earlier)) {
            throw new RuleException("change_item.not_in_hierarchy", "The target parent is not in " + h.code() + " on " + d + ".");
        }
        Placement p = simulatePlacement(node, h, d, earlier);
        ObjectNode expected = payload.putObject("expected");
        if ("move_node".equals(action)) {
            if (p.primaryParent() == null) {
                throw new RuleException("change_item.not_in_hierarchy", "The node is not placed in " + h.code() + " on " + d + ".");
            }
            expected.put("parentId", p.primaryParent().toString());
        } else {
            if (p.parents().contains(target)) {
                throw new RuleException("change_item.already_under_target", "The node is already under that parent.");
            }
        }
        ArrayNode parents = expected.putArray("parentIds");
        p.parents().stream().map(UUID::toString).sorted().forEach(parents::add);
        List<Scope> scopes = new ArrayList<>(List.of(new Scope(h.id(), target)));
        if ("move_node".equals(action)) {
            scopes.add(new Scope(h.id(), node));   // moving a node out of a scope needs the right on its current place too
        }
        return new NewItem(action, h.id(), node, target, null, payload, scopes);
    }

    private NewItem remove(ItemCommand cmd, ObjectNode payload, HierarchyRow h, LocalDate d, List<ItemView> earlier) {
        UUID node = requireId(cmd.nodeId(), "nodeId");
        Placement p = simulatePlacement(node, h, d, earlier);
        if (p.parents().isEmpty()) {
            throw new RuleException("change_item.not_in_hierarchy", "The node is not placed in " + h.code() + " on " + d + ".");
        }
        ArrayNode parents = payload.putObject("expected").putArray("parentIds");
        p.parents().stream().map(UUID::toString).sorted().forEach(parents::add);
        return new NewItem("remove_node", h.id(), node, null, null, payload, List.of(new Scope(h.id(), node)));
    }

    private NewItem nodeLevel(ItemCommand cmd, String action, ObjectNode payload, HierarchyRow h, LocalDate d,
                              List<ItemView> earlier) {
        UUID node = requireId(cmd.nodeId(), "nodeId");
        if (!inHierarchy(node, h, d)) {
            throw new RuleException("change_item.not_in_hierarchy", "The node is not in " + h.code() + " on " + d + ".");
        }
        if ("update_node".equals(action) && !payload.has("name") && !payload.has("description")) {
            throw ItemValidationException.field("payload", "update_node needs name or description");
        }
        String[] attrs = attributesAfterEarlier(node, d, earlier);
        if (attrs == null) {
            throw new RuleException("change_item.node_not_found", "The node has no attributes on " + d + ".");
        }
        ObjectNode expected = payload.putObject("expected");
        expected.put("name", attrs[0]);
        if (attrs[1] == null) {
            expected.putNull("description");
        } else {
            expected.put("description", attrs[1]);
        }
        return new NewItem(action, h.id(), node, null, null, payload, List.of(new Scope(h.id(), node)));
    }

    private NewItem property(ItemCommand cmd, String action, ObjectNode payload, HierarchyRow h, LocalDate d,
                             List<ItemView> earlier) {
        UUID node = requireId(cmd.nodeId(), "nodeId");
        if (cmd.propertyCode() == null || cmd.propertyCode().isBlank()) {
            throw ItemValidationException.field("propertyCode", "is required");
        }
        PropertyRow prop = jdbc.sql("""
                SELECT property_id, scope::text AS scope, origin::text AS origin FROM mdm.property_definition WHERE property_code = :c
                """).param("c", cmd.propertyCode())
                .query((rs, i) -> new PropertyRow(rs.getObject("property_id", UUID.class), rs.getString("scope"), rs.getString("origin")))
                .optional()
                .orElseThrow(() -> ItemValidationException.field("propertyCode", "unknown property " + cmd.propertyCode()));
        if ("derived".equals(prop.origin())) {
            throw new RuleException("property.derived", "Property " + cmd.propertyCode() + " is derived and cannot be set.");
        }
        if ("set_property".equals(action) && !payload.has("value")) {
            throw ItemValidationException.field("payload.value", "is required (use null for an explicit blank)");
        }
        if (!inHierarchy(node, h, d)) {
            throw new RuleException("change_item.not_in_hierarchy", "The node is not in " + h.code() + " on " + d + ".");
        }
        UUID valueHierarchy = "local".equals(prop.scope()) ? h.id() : null;
        ObjectNode expected = payload.putObject("expected");
        Optional<ItemView> last = earlier.stream()
                .filter(e -> ("set_property".equals(e.action()) || "clear_property".equals(e.action()))
                        && node.equals(e.nodeId()) && cmd.propertyCode().equals(e.propertyCode())
                        && ("global".equals(prop.scope()) || h.code().equals(e.hierarchyCode())))
                .reduce((a, b) -> b);
        if (last.isPresent()) {
            boolean present = "set_property".equals(last.get().action());
            expected.put("present", present);
            expected.set("value", present ? last.get().payload().get("value") : null);
        } else {
            Optional<String> stored = jdbc.sql("""
                    SELECT value::text FROM mdm.property_value
                    WHERE node_id = :n AND property_id = :p AND hierarchy_id IS NOT DISTINCT FROM CAST(:h AS uuid)
                      AND valid_period @> CAST(:d AS date) AND upper_inf(recorded_period)
                    """).param("n", node).param("p", prop.id()).param("h", valueHierarchy).param("d", d)
                    .query(String.class).optional();
            expected.put("present", stored.isPresent());
            expected.set("value", stored.map(this::readJson).orElse(null));
        }
        return new NewItem(action, h.id(), node, null, prop.id(), payload, List.of(new Scope(h.id(), node)));
    }

    // ------------------------------------------------------------------ helpers

    private record HierarchyRow(UUID id, String code) {
    }

    private record PropertyRow(UUID id, String scope, String origin) {
    }

    private record Placement(UUID primaryParent, Set<UUID> parents) {
    }

    private HierarchyRow hierarchy(String code) {
        if (code == null || code.isBlank()) {
            throw ItemValidationException.field("hierarchyCode", "is required");
        }
        return jdbc.sql("SELECT hierarchy_id, hierarchy_code FROM mdm.hierarchy WHERE hierarchy_code = :c AND is_active")
                .param("c", code)
                .query((rs, i) -> new HierarchyRow(rs.getObject("hierarchy_id", UUID.class), rs.getString("hierarchy_code")))
                .optional()
                .orElseThrow(() -> ItemValidationException.field("hierarchyCode", "unknown hierarchy " + code));
    }

    private boolean inHierarchy(UUID node, HierarchyRow h, LocalDate d) {
        return jdbc.sql("""
                SELECT EXISTS (SELECT 1 FROM mdm.hierarchy WHERE hierarchy_id = :h AND top_node_id = :n)
                    OR EXISTS (SELECT 1 FROM mdm.hierarchy_relationship r WHERE r.hierarchy_id = :h AND r.child_node_id = :n
                               AND r.valid_period @> CAST(:d AS date) AND upper_inf(r.recorded_period))
                """).param("h", h.id()).param("n", node).param("d", d).query(Boolean.class).single();
    }

    private boolean addedEarlier(UUID node, HierarchyRow h, List<ItemView> earlier) {
        return earlier.stream().anyMatch(e -> "add_node".equals(e.action()) && node.equals(e.nodeId()) && h.code().equals(e.hierarchyCode()));
    }

    private boolean allowsChildren(UUID node, LocalDate d) {
        return jdbc.sql("""
                SELECT coalesce((SELECT allows_children FROM mdm.node_attr WHERE node_id = :n
                                 AND valid_period @> CAST(:d AS date) AND upper_inf(recorded_period)), false)
                """).param("n", node).param("d", d).query(Boolean.class).single();
    }

    /** Current placements of the node in the hierarchy, changed by earlier items of the same request (LLD §7.3). */
    private Placement simulatePlacement(UUID node, HierarchyRow h, LocalDate d, List<ItemView> earlier) {
        UUID primary = null;
        Set<UUID> parents = new TreeSet<>();
        for (var row : jdbc.sql("""
                SELECT parent_node_id, is_primary FROM mdm.hierarchy_relationship
                WHERE hierarchy_id = :h AND child_node_id = :n AND valid_period @> CAST(:d AS date) AND upper_inf(recorded_period)
                """).param("h", h.id()).param("n", node).param("d", d)
                .query((rs, i) -> Map.entry(rs.getObject("parent_node_id", UUID.class), rs.getBoolean("is_primary"))).list()) {
            parents.add(row.getKey());
            if (row.getValue()) {
                primary = row.getKey();
            }
        }
        for (ItemView e : earlier) {
            if (!node.equals(e.nodeId()) || !h.code().equals(e.hierarchyCode())) {
                continue;
            }
            switch (e.action()) {
                case "add_node" -> { parents = new TreeSet<>(Set.of(e.targetParentId())); primary = e.targetParentId(); }
                case "move_node" -> { if (primary != null) { parents.remove(primary); } parents.add(e.targetParentId()); primary = e.targetParentId(); }
                case "insert_node" -> { parents.add(e.targetParentId()); if (primary == null) { primary = e.targetParentId(); } }
                case "remove_node" -> { parents.clear(); primary = null; }
                default -> { }
            }
        }
        return new Placement(primary, new LinkedHashSet<>(parents));
    }

    /** {name, description} on {@code d}, after earlier update_node items of the request; null if the node has no attributes. */
    private String[] attributesAfterEarlier(UUID node, LocalDate d, List<ItemView> earlier) {
        String[] attrs = jdbc.sql("""
                SELECT node_name, description FROM mdm.node_attr
                WHERE node_id = :n AND valid_period @> CAST(:d AS date) AND upper_inf(recorded_period)
                """).param("n", node).param("d", d)
                .query((rs, i) -> new String[] {rs.getString("node_name"), rs.getString("description")}).optional().orElse(null);
        for (ItemView e : earlier) {
            if ("update_node".equals(e.action()) && node.equals(e.nodeId()) && attrs != null) {
                if (e.payload().has("name")) {
                    attrs[0] = e.payload().get("name").asText();
                }
                if (e.payload().has("description")) {
                    attrs[1] = e.payload().get("description").isNull() ? null : e.payload().get("description").asText();
                }
            }
        }
        return attrs;
    }

    private ObjectNode payloadOf(ItemCommand cmd, String action) {
        JsonNode p = cmd.payload();
        if (p != null && !p.isObject()) {
            throw ItemValidationException.field("payload", "must be a JSON object");
        }
        ObjectNode payload = p == null ? JsonNodeFactory.instance.objectNode() : ((ObjectNode) p).deepCopy();
        List<Map<String, String>> unknown = new ArrayList<>();
        payload.fieldNames().forEachRemaining(f -> {
            if (!ALLOWED_PAYLOAD.get(action).contains(f)) {
                unknown.add(Map.of("field", "payload." + f, "message", "is not allowed for " + action));
            }
        });
        if (!unknown.isEmpty()) {
            throw new ItemValidationException("The item has fields its action does not use.", unknown);
        }
        return payload;
    }

    private static void require(ObjectNode payload, String field) {
        JsonNode v = payload.get(field);
        if (v == null || v.isNull() || (v.isTextual() && v.asText().isBlank())) {
            throw ItemValidationException.field("payload." + field, "is required");
        }
    }

    private static UUID requireId(UUID id, String field) {
        if (id == null) {
            throw ItemValidationException.field(field, "is required");
        }
        return id;
    }

    private static void nodeKind(String kind, String field) {
        if (!NODE_KINDS.contains(kind)) {
            throw ItemValidationException.field(field, "must be one of " + new TreeSet<>(NODE_KINDS));
        }
    }

    private JsonNode readJson(String s) {
        try {
            return mapper.readTree(s);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }
}
