package com.mdm.api.security;

import com.mdm.api.common.BusinessClock;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;

import java.time.LocalDate;
import java.util.HashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * Answers "may this actor do this here?" from the actor's current grants in {@code mdm.user_role} (ADR-022).
 * <ul>
 *   <li>A grant covers all hierarchies, one hierarchy, or one sub-tree of a hierarchy.</li>
 *   <li>Phase 1 reads are checked per hierarchy; sub-tree read filtering comes with SEC-02 in full (Phase 5).</li>
 *   <li>Writes and decisions are checked against the node they touch: it must be the scope's top node or under it,
 *       through any placement (primary or shared) at the business date.</li>
 * </ul>
 * This class does not decide maker-checker, separation of duties or human-only rules: the database does.
 */
@Service
public class EntitlementService {

    private final JdbcClient jdbc;
    private final BusinessClock clock;

    public EntitlementService(JdbcClient jdbc, BusinessClock clock) {
        this.jdbc = jdbc;
        this.clock = clock;
    }

    /** The actor's grants valid today (business date), current recorded belief. */
    public List<Grant> grants(Actor actor) {
        return grants(actor, clock.today());
    }

    public List<Grant> grants(Actor actor, LocalDate on) {
        return jdbc.sql("""
                SELECT ur.role_code, ur.hierarchy_id, h.hierarchy_code, ur.top_node_id,
                       lower(ur.valid_period) AS valid_from, upper(ur.valid_period) AS valid_to
                FROM mdm.user_role ur
                LEFT JOIN mdm.hierarchy h ON h.hierarchy_id = ur.hierarchy_id
                WHERE ur.user_id = :user
                  AND upper_inf(ur.recorded_period)
                  AND ur.valid_period @> CAST(:on AS date)
                ORDER BY ur.role_code, h.hierarchy_code NULLS FIRST
                """)
                .param("user", actor.userId())
                .param("on", on)
                .query((rs, i) -> new Grant(rs.getString("role_code"), rs.getObject("hierarchy_id", UUID.class),
                        rs.getString("hierarchy_code"), rs.getObject("top_node_id", UUID.class),
                        rs.getObject("valid_from", LocalDate.class), rs.getObject("valid_to", LocalDate.class)))
                .list();
    }

    /** Hierarchies the actor may read; empty Optional means every hierarchy. */
    public Optional<Set<UUID>> readableHierarchies(Actor actor) {
        Set<UUID> ids = new HashSet<>();
        for (Grant g : grants(actor)) {
            if (!RolePermissions.allows(g.roleCode(), Permission.READ)) {
                continue;
            }
            if (g.allHierarchies()) {
                return Optional.empty();
            }
            ids.add(g.hierarchyId());
        }
        return Optional.of(ids);
    }

    public boolean canRead(Actor actor, UUID hierarchyId) {
        return readableHierarchies(actor).map(ids -> ids.contains(hierarchyId)).orElse(true);
    }

    /**
     * Throws {@link ForbiddenException} unless a current grant gives {@code permission} for {@code nodeId} in
     * {@code hierarchyId}. {@code nodeId} may be null for actions on the hierarchy as a whole (then only whole-hierarchy
     * or all-hierarchy grants count).
     */
    public void require(Actor actor, Permission permission, UUID hierarchyId, UUID nodeId) {
        LocalDate today = clock.today();
        for (Grant g : grants(actor, today)) {
            if (!RolePermissions.allows(g.roleCode(), permission)) {
                continue;
            }
            if (g.allHierarchies()) {
                return;
            }
            if (!g.hierarchyId().equals(hierarchyId)) {
                continue;
            }
            if (g.wholeHierarchy() || permission == Permission.READ) {
                return;
            }
            if (nodeId != null && isInSubtree(hierarchyId, nodeId, g.topNodeId(), today)) {
                return;
            }
        }
        throw new ForbiddenException("entitlement.missing", "You don't have the " + describe(permission)
                + " permission for this part of the hierarchy. Ask an administrator for a role with that scope.");
    }

    /** True if {@code nodeId} is {@code topNodeId} or placed (primarily or shared) somewhere under it on {@code on}. */
    boolean isInSubtree(UUID hierarchyId, UUID nodeId, UUID topNodeId, LocalDate on) {
        if (nodeId.equals(topNodeId)) {
            return true;
        }
        // Walk up every placement (UNION removes repeats; the hierarchy guard prevents cycles, so this ends).
        return jdbc.sql("""
                WITH RECURSIVE up(node_id) AS (
                  SELECT CAST(:node AS uuid)
                  UNION
                  SELECT r.parent_node_id
                  FROM up
                  JOIN mdm.hierarchy_relationship r
                    ON r.child_node_id = up.node_id
                   AND r.hierarchy_id = :hierarchy
                   AND r.valid_period @> CAST(:on AS date)
                   AND upper_inf(r.recorded_period)
                )
                SELECT EXISTS (SELECT 1 FROM up WHERE node_id = :top)
                """)
                .param("node", nodeId)
                .param("hierarchy", hierarchyId)
                .param("on", on)
                .param("top", topNodeId)
                .query(Boolean.class).single();
    }

    private static String describe(Permission p) {
        return switch (p) {
            case READ -> "read";
            case PROPOSE -> "propose changes";
            case DECIDE -> "decide requests";
            case ADMIN_WORKFLOW -> "workflow administration";
            case ADMIN_POLICY -> "policy administration";
            case ADMIN_SYSTEM -> "system administration";
        };
    }
}
