package com.mdm.api.query;

import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Sorts a compiled query's conditions into the three classes of Phase 5 LLD §17.5.2 and turns the indexed ones into SQL
 * predicates for candidate selection.
 * <ul>
 *   <li><b>indexed</b>: {@code name} and {@code description} conditions, and stored-only properties (stored, not
 *       inherited, no default) with {@code =}, {@code in} or {@code not_null};</li>
 *   <li><b>resolved</b>: everything else, evaluated in SQL by {@code mdm.filter_holds} over each chunk;</li>
 *   <li><b>java</b>: CEL-derived properties. No engine yet (ADR-041): the runner refuses them until 5-10.</li>
 * </ul>
 * Only conditions directly under the top-level {@code all} become predicates: an {@code any} group, or anything under
 * one, narrows nothing on its own. A predicate only ever narrows the candidates to a superset of the matches, because
 * every candidate is then checked against the whole filter; so a planner mistake can cost speed but not correctness.
 */
@Component
public class QueryPlanner {

    /** A property the compiled filter names, with what decides its class. */
    public record PropertyInfo(UUID id, String code, String scope, boolean storedOnly, boolean cel) {
    }

    /** SQL predicates over the candidate's node attributes ({@code a}) and the slice, with their bound parameters. */
    public record Plan(List<String> predicates, Map<String, Object> params, int indexed, int resolved, int java) {
    }

    public Plan plan(JsonNode tree, Map<String, PropertyInfo> props) {
        List<String> predicates = new ArrayList<>();
        Map<String, Object> params = new LinkedHashMap<>();
        int[] counts = new int[3];
        count(tree, props, counts);
        if (tree.has("all")) {
            for (JsonNode c : tree.get("all")) {
                String sql = predicate(c, props, params);
                if (sql != null) {
                    predicates.add(sql);
                }
            }
        }
        return new Plan(predicates, params, counts[0], counts[1], counts[2]);
    }

    /** The class of one condition: 0 indexed, 1 resolved, 2 java. */
    static int classOf(JsonNode c, Map<String, PropertyInfo> props) {
        String op = c.path("op").asText();
        if (c.has("attribute")) {
            String a = c.get("attribute").asText();
            return (a.equals("name") || a.equals("description")) && isTextIndexable(op) ? 0 : 1;
        }
        PropertyInfo p = props.get(c.path("property").asText());
        if (p == null) {
            return 1;
        }
        if (p.cel()) {
            return 2;
        }
        return p.storedOnly() && (op.equals("=") || op.equals("in") || op.equals("not_null")) ? 0 : 1;
    }

    private static boolean isTextIndexable(String op) {
        return op.equals("=") || op.equals("starts_with") || op.equals("contains") || op.equals("ends_with") || op.equals("like");
    }

    private static void count(JsonNode node, Map<String, PropertyInfo> props, int[] counts) {
        JsonNode kids = node.has("all") ? node.get("all") : node.get("any");
        if (kids != null) {
            kids.forEach(k -> count(k, props, counts));
        } else {
            counts[classOf(node, props)]++;
        }
    }

    /** The SQL predicate for an indexed top-level condition, or null if it is not indexed. */
    private static String predicate(JsonNode c, Map<String, PropertyInfo> props, Map<String, Object> params) {
        if (c.has("all") || c.has("any") || classOf(c, props) != 0) {
            return null;
        }
        String name = "pf" + params.size();
        String op = c.get("op").asText();
        if (c.has("attribute")) {
            String column = c.get("attribute").asText().equals("name") ? "a.node_name" : "a.description";
            boolean ci = c.path("ci").asBoolean(false);
            String value = c.path("value").asText();
            if (op.equals("=")) {
                params.put(name, value);
                return column + " = CAST(:" + name + " AS text)";
            }
            String pattern = switch (op) {
                case "starts_with" -> escapeLike(value) + "%";
                case "ends_with" -> "%" + escapeLike(value);
                case "contains" -> "%" + escapeLike(value) + "%";
                default -> value;                                         // like: the caller's own pattern
            };
            params.put(name, ci ? pattern.toLowerCase(java.util.Locale.ROOT) : pattern);
            // the filter compares lower() of both sides for ci, and LIKE's default escape is the backslash
            return (ci ? "lower(" + column + ")" : column) + " COLLATE \"C\" LIKE CAST(:" + name + " AS text)";
        }
        PropertyInfo p = props.get(c.get("property").asText());
        params.put(name + "p", p.id());
        String key = "pv.hierarchy_id IS NOT DISTINCT FROM " + ("local".equals(p.scope()) ? "CAST(:hierarchyId AS uuid)" : "NULL::uuid");
        String exists = "EXISTS (SELECT 1 FROM mdm.property_value pv WHERE pv.node_id = m.node_id AND pv.property_id = CAST(:"
                + name + "p AS uuid) AND " + key
                + " AND pv.valid_period @> CAST(:asOf AS date) AND pv.recorded_period @> CAST(:rec AS timestamptz) AND ";
        return switch (op) {
            case "=" -> {
                params.put(name, c.get("value").toString());
                yield exists + "pv.value = CAST(:" + name + " AS jsonb))";
            }
            case "in" -> {
                params.put(name, c.get("value").toString());
                yield exists + "CAST(:" + name + " AS jsonb) @> jsonb_build_array(pv.value))";
            }
            default -> exists + "pv.value <> 'null'::jsonb)";              // not_null
        };
    }

    private static String escapeLike(String s) {
        return s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_");
    }
}
