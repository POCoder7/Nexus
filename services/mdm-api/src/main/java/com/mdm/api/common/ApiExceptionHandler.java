package com.mdm.api.common;

import jakarta.servlet.http.HttpServletRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.web.bind.MissingServletRequestParameterException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;

import java.util.List;
import java.util.Map;

/**
 * Every error is RFC 9457 Problem Details with a stable {@code type} URN and the request's correlation id
 * (overview §9). Database guard and constraint errors are mapped by {@link DbErrorTranslator}.
 */
@RestControllerAdvice
public class ApiExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(ApiExceptionHandler.class);

    private final DbErrorTranslator dbErrors;

    public ApiExceptionHandler(DbErrorTranslator dbErrors) {
        this.dbErrors = dbErrors;
    }

    @ExceptionHandler(NotFoundException.class)
    public ProblemDetail notFound(NotFoundException ex, HttpServletRequest request) {
        return withCorrelation(Problems.of(HttpStatus.NOT_FOUND, Problems.NOT_FOUND, ex.getMessage()), request);
    }

    @ExceptionHandler(IllegalArgumentException.class)
    public ProblemDetail badRequest(IllegalArgumentException ex, HttpServletRequest request) {
        return withCorrelation(Problems.of(HttpStatus.BAD_REQUEST, Problems.INVALID_REQUEST, ex.getMessage()), request);
    }

    @ExceptionHandler(MethodArgumentTypeMismatchException.class)
    public ProblemDetail typeMismatch(MethodArgumentTypeMismatchException ex, HttpServletRequest request) {
        ProblemDetail p = Problems.of(HttpStatus.BAD_REQUEST, Problems.INVALID_REQUEST,
                "Parameter '" + ex.getName() + "' has an invalid value.");
        p.setProperty("errors", List.of(Map.of("field", ex.getName(), "message", "Invalid value")));
        return withCorrelation(p, request);
    }

    @ExceptionHandler(MissingServletRequestParameterException.class)
    public ProblemDetail missingParameter(MissingServletRequestParameterException ex, HttpServletRequest request) {
        ProblemDetail p = Problems.of(HttpStatus.BAD_REQUEST, Problems.INVALID_REQUEST,
                "Parameter '" + ex.getParameterName() + "' is required.");
        p.setProperty("errors", List.of(Map.of("field", ex.getParameterName(), "message", "Required")));
        return withCorrelation(p, request);
    }

    @ExceptionHandler(DataAccessException.class)
    public ProblemDetail database(DataAccessException ex, HttpServletRequest request) {
        return dbErrors.translate(ex)
                .map(p -> withCorrelation(p, request))
                .orElseGet(() -> {
                    // Unexpected database error: log the cause, return no database text to the caller.
                    log.error("Unhandled database error", ex);
                    return withCorrelation(Problems.of(HttpStatus.INTERNAL_SERVER_ERROR, Problems.INTERNAL,
                            "Something went wrong on our side. Quote the correlation id if you contact support."), request);
                });
    }

    private static ProblemDetail withCorrelation(ProblemDetail p, HttpServletRequest request) {
        String id = CorrelationIdFilter.current(request);
        if (id != null) {
            p.setProperty("correlationId", id);
        }
        return p;
    }
}
