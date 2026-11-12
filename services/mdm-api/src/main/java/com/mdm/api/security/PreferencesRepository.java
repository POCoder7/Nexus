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

    /**
     * What the UI needs: start page, the last hierarchy used (by code), the density, and the working version the user
     * chose (by name; null when none is chosen or the chosen one is no longer working).
     */
    public record Preferences(String startPage, String lastHierarchyCode, String density, String workingVersion) {
        public static final Preferences DEFAULTS = new Preferences("home", null, "compact", null);
    }

    /** A version's id and status, looked up by name when the user chooses a working version. */
    public record VersionStatus(UUID id, String status) {
    }

    private final JdbcClient jdbc;

    public PreferencesRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    public Preferences find(UUID userId) {
        return jdbc.sql("""
                SELECT p.start_page, h.hierarchy_code, p.density, v.version_name
                FROM mdm.user_preference p
                LEFT JOIN mdm.hierarchy h ON h.hierarchy_id = p.last_hierarchy_id AND h.is_active
                LEFT JOIN mdm.version v ON v.version_id = p.working_version_id AND v.status = 'working'
                WHERE p.user_id = :user
                """)
                .param("user", userId)
                .query((rs, i) -> new Preferences(rs.getString("start_page"), rs.getString("hierarchy_code"), rs.getString("density"),
                        rs.getString("version_name")))
                .optional()
                .orElse(Preferences.DEFAULTS);
    }

    /**
     * Where the UI raises the user's new change requests (ADR-037, Phase 3 LLD V.5): the working version they chose,
     * while it is still working; otherwise the latest working version (by business date, then name).
     */
    public Optional<String> workingVersion(UUID userId) {
        return jdbc.sql("""
                SELECT v.version_name
                FROM mdm.version v
                LEFT JOIN mdm.user_preference p ON p.user_id = :user AND p.working_version_id = v.version_id
                WHERE v.status = 'working'
                ORDER BY (p.user_id IS NOT NULL) DESC, v.business_as_of DESC, v.version_name
                LIMIT 1
                """).param("user", userId).query(String.class).optional();
    }

    public Optional<VersionStatus> versionStatus(String name) {
        return jdbc.sql("SELECT version_id, status::text FROM mdm.version WHERE version_name = :name").param("name", name)
                .query((rs, i) -> new VersionStatus(rs.getObject(1, UUID.class), rs.getString(2))).optional();
    }

    public Optional<UUID> lastHierarchyId(UUID userId) {
        return jdbc.sql("SELECT last_hierarchy_id FROM mdm.user_preference WHERE user_id = :user AND last_hierarchy_id IS NOT NULL")
                .param("user", userId).query(UUID.class).optional();
    }

    /** Writes the caller's row; null arguments keep the stored value (or the default for a new row). */
    public void save(UUID userId, String startPage, UUID lastHierarchyId, String density, UUID workingVersionId) {
        jdbc.sql("""
                INSERT INTO mdm.user_preference (user_id, start_page, last_hierarchy_id, density, working_version_id, updated_at)
                VALUES (:user, coalesce(CAST(:start AS text), 'home'), CAST(:hier AS uuid), coalesce(CAST(:density AS text), 'compact'),
                        CAST(:version AS uuid), now())
                ON CONFLICT (user_id) DO UPDATE
                   SET start_page         = coalesce(CAST(:start AS text), mdm.user_preference.start_page),
                       last_hierarchy_id  = coalesce(CAST(:hier AS uuid), mdm.user_preference.last_hierarchy_id),
                       density            = coalesce(CAST(:density AS text), mdm.user_preference.density),
                       working_version_id = coalesce(CAST(:version AS uuid), mdm.user_preference.working_version_id),
                       updated_at         = now()
                """)
                .param("user", userId).param("start", startPage).param("hier", lastHierarchyId).param("density", density)
                .param("version", workingVersionId)
                .update();
    }
}
