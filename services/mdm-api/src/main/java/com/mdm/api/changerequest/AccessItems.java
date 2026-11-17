package com.mdm.api.changerequest;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.mdm.api.changerequest.ChangeRequestDtos.ItemView;
import com.mdm.api.common.ItemValidationException;
import com.mdm.api.common.RuleException;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * The eight governed access changes (ADR-042 D3; Phase 5 LLD §19.4): payload rules and early checks. Items name groups,
 * users, roles and hierarchies by code, carry no hierarchy or node of their own, and are decided by a second ADMIN in
 * core mode. The database re-checks everything: who proposes and decides (V14 triggers) and every rule at apply.
 */
@Component
public class AccessItems {

    public static final Set<String> ACTIONS = Set.of("create_group", "update_group", "add_group_scope", "end_group_scope",
            "add_group_member", "remove_group_member", "grant_role", "revoke_role");

    static final Map<String, Set<String>> ALLOWED_PAYLOAD = Map.of(
            "create_group", Set.of("group", "name", "description", "role"),
            "update_group", Set.of("group", "name", "description", "active", "role"),
            "add_group_scope", Set.of("group", "hierarchy", "topNodeId", "categories", "validTo"),
            "end_group_scope", Set.of("group", "hierarchy", "topNodeId"),
            "add_group_member", Set.of("group", "user", "validTo"),
            "remove_group_member", Set.of("group", "user"),
            "grant_role", Set.of("user", "role", "hierarchy", "topNodeId", "categories", "validTo"),
            "revoke_role", Set.of("user", "role", "hierarchy", "topNodeId"));

    private final JdbcClient jdbc;

    public AccessItems(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    public static boolean isAccess(String action) {
        return ACTIONS.contains(action);
    }

    /** Validates the payload; the item has no hierarchy, node or property, and no PROPOSE scope (ADMIN is checked instead). */
    public ItemFactory.NewItem build(String action, ObjectNode payload, LocalDate effectiveFrom, List<ItemView> earlier) {
        if (earlier.stream().anyMatch(e -> !isAccess(e.action()))) {
            throw new RuleException("access.mixed_request", "Access changes and other changes can't share a change request. Start a new request.");
        }
        switch (action) {
            case "create_group" -> {
                require(payload, "group");
                require(payload, "name");
                String code = payload.get("group").asText();
                if (groupExists(code) || createdEarlier(code, earlier)) {
                    throw new RuleException("access.group_exists", "A group with code " + code + " already exists.");
                }
                role(payload, false);
            }
            case "update_group" -> {
                group(payload, earlier);
                if (payload.size() == 1) {
                    throw ItemValidationException.field("payload", "update_group needs name, description, active or role");
                }
                if (payload.has("active") && !payload.get("active").isBoolean()) {
                    throw ItemValidationException.field("payload.active", "must be true or false");
                }
                role(payload, false);
            }
            case "add_group_scope", "end_group_scope" -> {
                group(payload, earlier);
                scope(payload);
            }
            case "add_group_member", "remove_group_member" -> {
                String role = group(payload, earlier);
                UserRow u = user(payload);
                if ("add_group_member".equals(action) && role != null) {
                    holderKind(u, role);
                }
            }
            default -> {   // grant_role, revoke_role
                UserRow u = user(payload);
                String role = role(payload, true);
                scope(payload);
                if ("grant_role".equals(action)) {
                    holderKind(u, role);
                }
            }
        }
        if (payload.has("validTo")) {
            LocalDate to = date(payload, "validTo");
            if (!to.isAfter(effectiveFrom)) {
                throw ItemValidationException.field("payload.validTo", "must be after the request's effective date " + effectiveFrom);
            }
        }
        return new ItemFactory.NewItem(action, null, null, null, null, payload, List.of());
    }

    // ------------------------------------------------------------------ helpers

    private record UserRow(String login, String kind) {
    }

    /** The group's role (null if none); the group may be created by an earlier item of the request. */
    private String group(ObjectNode payload, List<ItemView> earlier) {
        require(payload, "group");
        String code = payload.get("group").asText();
        Optional<ItemView> created = earlier.stream()
                .filter(e -> "create_group".equals(e.action()) && code.equals(e.payload().path("group").asText())).findFirst();
        if (created.isPresent()) {
            JsonNode r = created.get().payload().get("role");
            return r == null || r.isNull() ? null : r.asText();
        }
        return jdbc.sql("SELECT role_code FROM mdm.user_group WHERE group_code = :c").param("c", code)
                .query((rs, i) -> Optional.ofNullable(rs.getString(1))).optional()
                .orElseThrow(() -> ItemValidationException.field("payload.group", "unknown group " + code))
                .orElse(null);
    }

    private boolean groupExists(String code) {
        return jdbc.sql("SELECT count(*) FROM mdm.user_group WHERE group_code = :c").param("c", code).query(Integer.class).single() > 0;
    }

    private static boolean createdEarlier(String code, List<ItemView> earlier) {
        return earlier.stream().anyMatch(e -> "create_group".equals(e.action()) && code.equals(e.payload().path("group").asText()));
    }

    private UserRow user(ObjectNode payload) {
        require(payload, "user");
        String login = payload.get("user").asText();
        return jdbc.sql("SELECT login, kind::text FROM mdm.app_user WHERE login = :l").param("l", login)
                .query((rs, i) -> new UserRow(rs.getString(1), rs.getString(2))).optional()
                .orElseThrow(() -> ItemValidationException.field("payload.user", "unknown user " + login));
    }

    private String role(ObjectNode payload, boolean required) {
        if (required) {
            require(payload, "role");
        }
        JsonNode r = payload.get("role");
        if (r == null || r.isNull()) {
            return null;
        }
        String code = r.asText();
        if (jdbc.sql("SELECT count(*) FROM mdm.role WHERE role_code = :c").param("c", code).query(Integer.class).single() == 0) {
            throw ItemValidationException.field("payload.role", "unknown role " + code);
        }
        return code;
    }

    /** The same rule as the database's N1032 and N1009, given early (ADR-042 D5). */
    private void holderKind(UserRow u, String role) {
        String holder = jdbc.sql("SELECT holder_kind FROM mdm.role WHERE role_code = :r").param("r", role).query(String.class).single();
        if ("ai_agent".equals(u.kind()) || "system_feed".equals(u.kind())) {
            throw new RuleException("roles.human_only", u.login() + " is not a person or a service account and cannot hold a role.");
        }
        if (!holder.equals(u.kind())) {
            throw new RuleException("roles.holder_kind", u.login() + " cannot hold " + role
                    + ": people hold every role but CONSUMER, and service accounts hold only CONSUMER.");
        }
    }

    private void scope(ObjectNode payload) {
        if (payload.hasNonNull("hierarchy")) {
            String code = payload.get("hierarchy").asText();
            if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = :c").param("c", code).query(Integer.class).single() == 0) {
                throw ItemValidationException.field("payload.hierarchy", "unknown hierarchy " + code);
            }
        } else if (payload.hasNonNull("topNodeId")) {
            throw ItemValidationException.field("payload.topNodeId", "a sub-tree scope needs its hierarchy");
        }
        if (payload.hasNonNull("topNodeId")) {
            try {
                UUID.fromString(payload.get("topNodeId").asText());
            } catch (IllegalArgumentException e) {
                throw ItemValidationException.field("payload.topNodeId", "must be a node id");
            }
        }
        if (payload.has("categories")) {
            JsonNode c = payload.get("categories");
            if (!c.isArray() || c.isEmpty()) {
                throw ItemValidationException.field("payload.categories", "must be a non-empty list, or left out for every category");
            }
        }
    }

    private static LocalDate date(ObjectNode payload, String field) {
        try {
            return LocalDate.parse(payload.get(field).asText());
        } catch (RuntimeException e) {
            throw ItemValidationException.field("payload." + field, "must be a date (yyyy-mm-dd)");
        }
    }

    private static void require(ObjectNode payload, String field) {
        JsonNode v = payload.get(field);
        if (v == null || v.isNull() || (v.isTextual() && v.asText().isBlank())) {
            throw ItemValidationException.field("payload." + field, "is required");
        }
    }
}
