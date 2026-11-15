package com.mdm.api.property;

import com.mdm.api.common.Cursors;
import com.mdm.api.common.Page;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import com.mdm.api.security.ForbiddenException;
import com.mdm.api.security.Permission;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Arrays;
import java.util.List;
import java.util.Set;

/**
 * Property definitions (Phase 5 LLD §17.11): what each property is, for the query builder's property picker (5-13b)
 * and, from 5-10, the derived-property administration. Definitions are reference data every reader may see; values
 * stay behind the read scope of the node endpoints.
 */
@RestController
@RequestMapping("/api/v1/property-definitions")
public class PropertyDefinitionController {

    private static final Set<String> ORIGINS = Set.of("stored", "derived", "system");

    /** A definition. For a derived property, its engine, its expression and the original DRM formula it replaces. */
    public record PropertyDefinitionView(String code, String label, String category, String dataType, String scope,
                                         String origin, String inheritance, String derivationEngine, String derivationExpr,
                                         String drmFormulaOrig, List<String> listValues) {
    }

    private final JdbcClient jdbc;
    private final EntitlementService entitlements;
    private final Cursors cursors;

    public PropertyDefinitionController(JdbcClient jdbc, EntitlementService entitlements, Cursors cursors) {
        this.jdbc = jdbc;
        this.entitlements = entitlements;
        this.cursors = cursors;
    }

    /** Definitions by code, optionally of one origin, keyset-paged. */
    @GetMapping
    public Page<PropertyDefinitionView> listPropertyDefinitions(Actor actor,
                                                                @RequestParam(required = false) String origin,
                                                                @RequestParam(defaultValue = "500") int limit,
                                                                @RequestParam(required = false) String cursor) {
        cursors.checkLimit(limit);
        if (!entitlements.hasAny(actor, Permission.READ)) {
            throw new ForbiddenException("entitlement.missing", "You don't have read access to any hierarchy.");
        }
        if (origin != null && !ORIGINS.contains(origin)) {
            throw new IllegalArgumentException("origin must be stored, derived or system");
        }
        List<String> after = cursors.decode(cursor, 1);
        List<PropertyDefinitionView> rows = jdbc.sql("""
                SELECT pd.property_code, pd.label, pd.category_code, pd.data_type::text AS data_type, pd.scope::text AS scope,
                       pd.origin::text AS origin, pd.inheritance::text AS inheritance, pd.derivation_engine, pd.derivation_expr,
                       pd.drm_formula_orig,
                       (SELECT array_agg(lv.list_value ORDER BY lv.sort_seq NULLS LAST, lv.list_value) FROM mdm.property_list_value lv
                        WHERE lv.property_id = pd.property_id AND lv.is_active) AS list_values
                FROM mdm.property_definition pd
                WHERE (CAST(:origin AS text) IS NULL OR pd.origin::text = :origin)
                  AND (CAST(:after AS text) IS NULL OR pd.property_code COLLATE "C" > CAST(:after AS text) COLLATE "C")
                ORDER BY pd.property_code COLLATE "C"
                LIMIT :limit
                """)
                .param("origin", origin).param("after", after == null ? null : after.get(0)).param("limit", limit + 1)
                .query((rs, i) -> {
                    java.sql.Array lv = rs.getArray("list_values");
                    return new PropertyDefinitionView(rs.getString("property_code"), rs.getString("label"),
                            rs.getString("category_code"), rs.getString("data_type"), rs.getString("scope"), rs.getString("origin"),
                            rs.getString("inheritance"), rs.getString("derivation_engine"), rs.getString("derivation_expr"),
                            rs.getString("drm_formula_orig"), lv == null ? List.of() : Arrays.asList((String[]) lv.getArray()));
                })
                .list();
        return Page.of(rows, limit, d -> cursors.encode(d.code()));
    }
}
