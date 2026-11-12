package com.mdm.api.common;

import org.springframework.core.NestedExceptionUtils;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.stereotype.Component;

import java.sql.SQLException;
import java.util.Optional;

/**
 * Maps database errors to Problem Details (ADR-020, overview §9).
 * <ul>
 *   <li>{@code N1xxx} control violations → 403, {@code N2xxx} integrity rules → 422, {@code N3xxx} conflicts → 409.
 *       The guard's message is the detail (it describes the caller's own request); its HINT becomes {@code code}.</li>
 *   <li>Constraint violations map to standard classes with a generic detail, because PostgreSQL's text can contain
 *       values from other rows (for example a duplicate name).</li>
 *   <li>Anything else is not translated and surfaces as a 500 with no database text.</li>
 * </ul>
 */
@Component
public class DbErrorTranslator {

    public Optional<ProblemDetail> translate(DataAccessException ex) {
        Throwable cause = NestedExceptionUtils.getMostSpecificCause(ex);
        if (!(cause instanceof SQLException sql) || sql.getSQLState() == null) {
            return Optional.empty();
        }
        String state = sql.getSQLState();
        if (state.startsWith("N1")) {
            return Optional.of(guard(HttpStatus.FORBIDDEN, Problems.FORBIDDEN, sql));
        }
        if (state.startsWith("N2")) {
            return Optional.of(guard(HttpStatus.UNPROCESSABLE_ENTITY, Problems.RULE_VIOLATION, sql));
        }
        if (state.startsWith("N3")) {
            return Optional.of(guard(HttpStatus.CONFLICT, Problems.CONFLICT_STALE_BASE, sql));
        }
        return switch (state) {
            case "23P01", "23505" -> Optional.of(Problems.of(HttpStatus.CONFLICT, Problems.CONFLICT,
                    "This conflicts with existing data (for example the same name or key at overlapping dates)."));
            case "23514", "23503", "22P02" -> Optional.of(Problems.of(HttpStatus.UNPROCESSABLE_ENTITY, Problems.CONSTRAINT_VIOLATION,
                    "The request breaks a data rule (a required value, a reference or a value format)."));
            case "40001", "40P01" -> Optional.of(Problems.of(HttpStatus.SERVICE_UNAVAILABLE, Problems.RETRY_LATER,
                    "The database was busy with a conflicting change. Try again."));
            default -> Optional.empty();
        };
    }

    private static ProblemDetail guard(HttpStatus status, String type, SQLException sql) {
        ProblemDetail p = Problems.of(status, type, serverMessage(sql));
        p.setProperty("sqlState", sql.getSQLState());
        hint(sql).ifPresent(h -> p.setProperty("code", h));
        return p;
    }

    /** PostgreSQL's primary message without the "ERROR: " prefix and the "Hint:/Where:" tail the driver appends. */
    private static String serverMessage(SQLException sql) {
        Object sem = serverErrorMessage(sql);
        if (sem != null) {
            try {
                Object m = sem.getClass().getMethod("getMessage").invoke(sem);
                if (m != null) {
                    return m.toString();
                }
            } catch (ReflectiveOperationException ignored) {
                // fall through to the exception message
            }
        }
        String msg = sql.getMessage();
        if (msg == null) {
            return "";
        }
        int nl = msg.indexOf('\n');
        String first = nl >= 0 ? msg.substring(0, nl) : msg;
        return first.startsWith("ERROR: ") ? first.substring("ERROR: ".length()) : first;
    }

    /**
     * The guard's HINT, read through reflection: the PostgreSQL driver is a runtime-only dependency,
     * so the API does not compile against its classes.
     */
    private static Optional<String> hint(SQLException sql) {
        Object sem = serverErrorMessage(sql);
        if (sem == null) {
            return Optional.empty();
        }
        try {
            Object h = sem.getClass().getMethod("getHint").invoke(sem);
            return Optional.ofNullable(h).map(Object::toString);
        } catch (ReflectiveOperationException e) {
            return Optional.empty();
        }
    }

    private static Object serverErrorMessage(SQLException sql) {
        try {
            return sql.getClass().getMethod("getServerErrorMessage").invoke(sql);
        } catch (ReflectiveOperationException e) {
            return null;
        }
    }
}
