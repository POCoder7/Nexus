package com.mdm.api.load;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.security.Actor;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;

import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.UUID;

/**
 * Stages and profiles the hackathon CSV data set (ADR-046; Phase 4 LLD §17.1, increment H-5). Each file goes to
 * mdm_stage through {@code mdm_stage.stage_file}, which the loader role owns, so the API never writes the staging tables
 * itself (CLAUDE.md rule 3). Each file is staged on its own: a file with the wrong header is rejected and the others are
 * still staged. Then {@code mdm_stage.profile} checks the load as a whole. Nothing here changes governed data.
 */
@Service
public class HackathonIntake {

    /** A staged file and its row count. */
    public record StagedFile(String fileName, int rows) {
    }

    /** A file that was not staged, and why. */
    public record RejectedFile(String fileName, String reason) {
    }

    public record Finding(String fileName, Integer lineNo, String severity, String kind, String detail) {
    }

    /** The outcome: what was staged, what was not, and what profiling found (errors block preparing the load). */
    public record IntakeResult(UUID loadId, List<StagedFile> staged, List<RejectedFile> rejected, int errors, int warnings,
                               List<Finding> findings) {
    }

    private final JdbcClient jdbc;
    private final ObjectMapper mapper;

    public HackathonIntake(JdbcClient jdbc, ObjectMapper mapper) {
        this.jdbc = jdbc;
        this.mapper = mapper;
    }

    /** The file names of the data set, in load order. */
    public List<String> knownFiles() {
        return jdbc.sql("SELECT file_name FROM mdm_stage.hx_file ORDER BY load_order").query(String.class).list();
    }

    /** Stages the files (name to content) under {@code loadId}, then profiles the load. Unknown names are rejected. */
    public IntakeResult stage(Actor actor, UUID loadId, Map<String, byte[]> files) {
        Set<String> known = Set.copyOf(knownFiles());
        List<StagedFile> staged = new ArrayList<>();
        List<RejectedFile> rejected = new ArrayList<>();
        for (Map.Entry<String, byte[]> f : new TreeMap<>(files).entrySet()) {
            String name = f.getKey().strip().toLowerCase(Locale.ROOT);
            if (!known.contains(name)) {
                rejected.add(new RejectedFile(f.getKey(), "Not part of the data set; expected one of " + String.join(", ", knownFiles())));
                continue;
            }
            List<List<String>> lines;
            try {
                lines = CsvReader.read(f.getValue());
            } catch (IllegalArgumentException e) {
                rejected.add(new RejectedFile(name, e.getMessage()));
                continue;
            }
            if (lines.isEmpty()) {
                rejected.add(new RejectedFile(name, "The file is empty: it needs at least its header line"));
                continue;
            }
            try {
                int rows = jdbc.sql("""
                        SELECT mdm_stage.stage_file(:load, :file, :sha, :actor, CAST(:header AS text[]), CAST(:rows AS jsonb))
                        """).param("load", loadId).param("file", name).param("sha", sha256(f.getValue()))
                        .param("actor", actor.userId()).param("header", lines.get(0).toArray(String[]::new))
                        .param("rows", json(lines.subList(1, lines.size()))).query(Integer.class).single();
                staged.add(new StagedFile(name, rows));
            } catch (DataAccessException e) {
                rejected.add(new RejectedFile(name, reason(e)));
            }
        }
        jdbc.sql("SELECT mdm_stage.profile(:load)").param("load", loadId).query(Integer.class).single();
        List<Finding> findings = findings(loadId);
        int errors = (int) findings.stream().filter(x -> "error".equals(x.severity())).count();
        int warnings = (int) findings.stream().filter(x -> "warning".equals(x.severity())).count();
        return new IntakeResult(loadId, staged, rejected, errors, warnings, findings);
    }

    /** What profiling found for a load: errors first, then by file and line. */
    public List<Finding> findings(UUID loadId) {
        return jdbc.sql("""
                SELECT file_name, line_no, severity, kind, detail FROM mdm_stage.profile_finding WHERE load_id = :load
                ORDER BY CASE severity WHEN 'error' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, file_name NULLS FIRST, line_no NULLS FIRST,
                         finding_id
                """).param("load", loadId)
                .query((rs, i) -> new Finding(rs.getString(1), (Integer) rs.getObject(2), rs.getString(3), rs.getString(4), rs.getString(5)))
                .list();
    }

    private String json(List<List<String>> rows) {
        try {
            return mapper.writeValueAsString(rows);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException(e);
        }
    }

    private static String sha256(byte[] bytes) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /** The guard's own words for N2812 and N2813; anything else is not a file problem and is raised. */
    private static String reason(DataAccessException e) {
        Throwable t = e;
        while (t != null && !(t instanceof SQLException)) {
            t = t.getCause();
        }
        if (t instanceof SQLException sql && ("N2812".equals(sql.getSQLState()) || "N2813".equals(sql.getSQLState()))) {
            String message = sql.getMessage();
            int hint = message.indexOf("\n");
            return (hint < 0 ? message : message.substring(0, hint)).replaceFirst("^ERROR: ", "");
        }
        throw e;
    }
}
