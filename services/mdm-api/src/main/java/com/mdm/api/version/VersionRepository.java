package com.mdm.api.version;

import com.mdm.api.version.VersionDtos.OpenRequests;
import com.mdm.api.version.VersionDtos.PersonRef;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/**
 * Reads {@code mdm.version} and calls the version functions (V11). The API role has no direct write on the table
 * (ADR-014): every change goes through {@code mdm.create_version}, {@code mdm.update_version} and
 * {@code mdm.transition_version}, whose guard is the last word on every rule.
 */
@Repository
public class VersionRepository {

    /** A version row as stored, with the ids the service needs for its rules. */
    public record VersionRow(UUID id, String name, String status, LocalDate businessAsOf, Instant recordedAsOf,
                             String baseVersion, String description, Instant createdAt, PersonRef createdBy,
                             Instant submittedAt, PersonRef submittedBy, Instant finalizedAt, PersonRef finalizedBy,
                             int revision) {
    }

    private static final String SELECT = """
            SELECT v.version_id, v.version_name, v.status::text AS status, v.business_as_of, v.recorded_as_of,
                   b.version_name AS base_name, v.description, v.created_at,
                   v.created_by, cu.display_name AS created_by_name,
                   v.submitted_at, v.submitted_by, su.display_name AS submitted_by_name,
                   v.finalized_at, v.finalized_by, fu.display_name AS finalized_by_name,
                   v.revision
            FROM mdm.version v
            LEFT JOIN mdm.version b   ON b.version_id = v.base_version_id
            LEFT JOIN mdm.app_user cu ON cu.user_id = v.created_by
            LEFT JOIN mdm.app_user su ON su.user_id = v.submitted_by
            LEFT JOIN mdm.app_user fu ON fu.user_id = v.finalized_by
            """;

    private static final RowMapper<VersionRow> ROW = VersionRepository::row;

    private final JdbcClient jdbc;

    public VersionRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    /** Keyset page on (business date descending, name); fetches {@code limit + 1} rows so the caller can tell if there is more. */
    public List<VersionRow> page(String status, LocalDate afterDate, String afterName, int limit) {
        return jdbc.sql(SELECT + """
                WHERE (CAST(:status AS text) IS NULL OR v.status::text = CAST(:status AS text))
                  AND (CAST(:d AS date) IS NULL
                       OR v.business_as_of < CAST(:d AS date)
                       OR (v.business_as_of = CAST(:d AS date) AND v.version_name > CAST(:n AS text)))
                ORDER BY v.business_as_of DESC, v.version_name
                LIMIT :limit
                """)
                .param("status", status).param("d", afterDate).param("n", afterName).param("limit", limit + 1)
                .query(ROW).list();
    }

    public Optional<VersionRow> findByName(String name) {
        return jdbc.sql(SELECT + " WHERE v.version_name = :name").param("name", name).query(ROW).optional();
    }

    public Optional<VersionRow> findById(UUID id) {
        return jdbc.sql(SELECT + " WHERE v.version_id = :id").param("id", id).query(ROW).optional();
    }

    /** Requests by status for each of the given versions (versions with none are absent from the map). */
    public Map<UUID, OpenRequests> openRequests(List<UUID> versionIds) {
        Map<UUID, OpenRequests> out = new HashMap<>();
        if (versionIds.isEmpty()) {
            return out;
        }
        jdbc.sql("""
                SELECT version_id,
                       count(*) FILTER (WHERE status = 'draft')     AS draft,
                       count(*) FILTER (WHERE status = 'submitted') AS submitted,
                       count(*) FILTER (WHERE status = 'in_review') AS in_review,
                       count(*) FILTER (WHERE status = 'approved')  AS approved
                FROM mdm.change_request
                WHERE version_id IN (:ids)
                GROUP BY version_id
                """)
                .param("ids", versionIds)
                .query((ResultSet rs) -> {
                    out.put(rs.getObject("version_id", UUID.class), new OpenRequests(rs.getLong("draft"),
                            rs.getLong("submitted"), rs.getLong("in_review"), rs.getLong("approved")));
                });
        return out;
    }

    /** Same rule as the functions' N1028 check: a current VERSION_ADMIN grant on all hierarchies, held by an active person. */
    public boolean isAdmin(UUID userId) {
        return jdbc.sql("SELECT mdm.is_version_admin(:u)").param("u", userId).query(Boolean.class).single();
    }

    public UUID create(String name, LocalDate businessAsOf, UUID baseVersionId, String description, UUID actor) {
        return jdbc.sql("SELECT mdm.create_version(:name, CAST(:date AS date), CAST(:base AS uuid), :description, :actor)")
                .param("name", name).param("date", businessAsOf).param("base", baseVersionId)
                .param("description", description).param("actor", actor)
                .query(UUID.class).single();
    }

    public void update(UUID versionId, String name, String description, UUID actor) {
        jdbc.sql("SELECT mdm.update_version(:id, :name, :description, :actor)")
                .param("id", versionId).param("name", name).param("description", description).param("actor", actor)
                .query((rs, i) -> 0).single();
    }

    public void transition(UUID versionId, String to, String reason, UUID actor) {
        jdbc.sql("SELECT mdm.transition_version(:id, :to, :reason, :actor)")
                .param("id", versionId).param("to", to).param("reason", reason).param("actor", actor)
                .query((rs, i) -> 0).single();
    }

    private static VersionRow row(ResultSet rs, int i) throws SQLException {
        return new VersionRow(rs.getObject("version_id", UUID.class), rs.getString("version_name"), rs.getString("status"),
                rs.getObject("business_as_of", LocalDate.class), instant(rs.getTimestamp("recorded_as_of")),
                rs.getString("base_name"), rs.getString("description"), instant(rs.getTimestamp("created_at")),
                person(rs, "created_by"), instant(rs.getTimestamp("submitted_at")), person(rs, "submitted_by"),
                instant(rs.getTimestamp("finalized_at")), person(rs, "finalized_by"), rs.getInt("revision"));
    }

    private static PersonRef person(ResultSet rs, String column) throws SQLException {
        UUID id = rs.getObject(column, UUID.class);
        return id == null ? null : new PersonRef(id, rs.getString(column + "_name"));
    }

    private static Instant instant(Timestamp t) {
        return t == null ? null : t.toInstant();
    }
}
