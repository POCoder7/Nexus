package com.mdm.api.security;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * UI preferences (Phase 3 LLD §4, OD-27): one row per user in {@code mdm.user_preference}. Every method takes the
 * caller's own user id from {@link Actor}; there is no way to name another user, so a caller can only read or change
 * their own row. Not governed data.
 */
@Repository
public class PreferencesRepository {

    public static final Set<String> START_PAGES = Set.of("home", "hierarchies", "worklist");
    public static final Set<String> DENSITIES = Set.of("compact", "comfortable");

    /** What the UI needs: start page, the last hierarchy used (by code) and the density. */
    public record Preferences(String startPage, String lastHierarchyCode, String density) {
        public static final Preferences DEFAULTS = new Preferences("home", null, "compact");
    }

    private final JdbcClient jdbc;

    public PreferencesRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    public Preferences find(UUID userId) {
        return jdbc.sql("""
                SELECT p.start_page, h.hierarchy_code, p.density
                FROM mdm.user_preference p
                LEFT JOIN mdm.hierarchy h ON h.hierarchy_id = p.last_hierarchy_id AND h.is_active
                WHERE p.user_id = :user
                """)
                .param("user", userId)
                .query((rs, i) -> new Preferences(rs.getString("start_page"), rs.getString("hierarchy_code"), rs.getString("density")))
                .optional()
                .orElse(Preferences.DEFAULTS);
    }

    public Optional<UUID> lastHierarchyId(UUID userId) {
        return jdbc.sql("SELECT last_hierarchy_id FROM mdm.user_preference WHERE user_id = :user AND last_hierarchy_id IS NOT NULL")
                .param("user", userId).query(UUID.class).optional();
    }

    /** Writes the caller's row; null arguments keep the stored value (or the default for a new row). */
    public void save(UUID userId, String startPage, UUID lastHierarchyId, String density) {
        jdbc.sql("""
                INSERT INTO mdm.user_preference (user_id, start_page, last_hierarchy_id, density, updated_at)
                VALUES (:user, coalesce(CAST(:start AS text), 'home'), CAST(:hier AS uuid), coalesce(CAST(:density AS text), 'compact'), now())
                ON CONFLICT (user_id) DO UPDATE
                   SET start_page        = coalesce(CAST(:start AS text), mdm.user_preference.start_page),
                       last_hierarchy_id = coalesce(CAST(:hier AS uuid), mdm.user_preference.last_hierarchy_id),
                       density           = coalesce(CAST(:density AS text), mdm.user_preference.density),
                       updated_at        = now()
                """)
                .param("user", userId).param("start", startPage).param("hier", lastHierarchyId).param("density", density)
                .update();
    }
}
