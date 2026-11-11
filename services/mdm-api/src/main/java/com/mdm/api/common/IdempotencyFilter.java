package com.mdm.api.common;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.mdm.api.security.Actor;
import com.mdm.api.security.ActorFilter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ReadListener;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletInputStream;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletRequestWrapper;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ProblemDetail;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import org.springframework.web.util.ContentCachingResponseWrapper;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.List;
import java.util.Optional;

/**
 * Idempotent POSTs (ADR-015, overview §8.3). With an {@value #HEADER} header, the first call reserves the key
 * (status 0 = in progress), runs, and stores its response; a repeat with the same key and body gets the stored
 * response; the same key with a different body is 422; a repeat while the first is still running is 409.
 * 5xx responses are not stored, so a failed call can be retried with the same key.
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 20)
public class IdempotencyFilter extends OncePerRequestFilter {

    public static final String HEADER = "Idempotency-Key";
    private static final List<String> REPLAYED_HEADERS = List.of("ETag", "Location");

    private final JdbcClient jdbc;
    private final ObjectMapper mapper;

    public IdempotencyFilter(JdbcClient jdbc, ObjectMapper mapper) {
        this.jdbc = jdbc;
        this.mapper = mapper;
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        return !"POST".equals(request.getMethod()) || request.getHeader(HEADER) == null
                || !request.getRequestURI().startsWith("/api/");
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        Actor actor = (Actor) request.getAttribute(ActorFilter.ATTRIBUTE);
        String key = request.getHeader(HEADER).trim();
        if (actor == null) {
            chain.doFilter(request, response);   // ActorFilter has already answered 401
            return;
        }
        if (key.length() < 8 || key.length() > 128) {
            problem(response, HttpStatus.BAD_REQUEST, Problems.INVALID_REQUEST, "Idempotency-Key must be 8 to 128 characters.");
            return;
        }
        CachedBodyRequest cached = new CachedBodyRequest(request);
        String hash = sha256(request.getMethod() + " " + request.getRequestURI() + "?"
                + (request.getQueryString() == null ? "" : request.getQueryString()) + "\n"
                + new String(cached.body, StandardCharsets.UTF_8));

        int reserved = jdbc.sql("""
                INSERT INTO mdm.idempotency_key (actor_id, idem_key, request_hash, response_status, response_body)
                VALUES (:actor, :key, :hash, 0, '{}'::jsonb)
                ON CONFLICT (actor_id, idem_key) DO NOTHING
                """).param("actor", actor.userId()).param("key", key).param("hash", hash).update();
        if (reserved == 0) {
            replayOrRefuse(actor, key, hash, response);
            return;
        }

        ContentCachingResponseWrapper wrapped = new ContentCachingResponseWrapper(response);
        boolean stored = false;
        try {
            chain.doFilter(cached, wrapped);
            int status = wrapped.getStatus();
            if (status < 500) {
                ObjectNode saved = mapper.createObjectNode();
                ObjectNode headers = saved.putObject("headers");
                for (String h : REPLAYED_HEADERS) {
                    String v = wrapped.getHeader(h);
                    if (v != null) {
                        headers.put(h, v);
                    }
                }
                byte[] body = wrapped.getContentAsByteArray();
                saved.put("contentType", wrapped.getContentType());
                saved.set("body", body.length == 0 ? null : mapper.readTree(body));
                jdbc.sql("""
                        UPDATE mdm.idempotency_key SET response_status = :status, response_body = CAST(:body AS jsonb)
                        WHERE actor_id = :actor AND idem_key = :key
                        """).param("status", status).param("body", mapper.writeValueAsString(saved))
                        .param("actor", actor.userId()).param("key", key).update();
                stored = true;
            }
        } finally {
            if (!stored) {
                jdbc.sql("DELETE FROM mdm.idempotency_key WHERE actor_id = :actor AND idem_key = :key")
                        .param("actor", actor.userId()).param("key", key).update();
            }
            wrapped.copyBodyToResponse();
        }
    }

    private void replayOrRefuse(Actor actor, String key, String hash, HttpServletResponse response) throws IOException {
        record Stored(String hash, int status, String body) {
        }
        Optional<Stored> stored = jdbc.sql("""
                SELECT request_hash, response_status, response_body::text AS body
                FROM mdm.idempotency_key WHERE actor_id = :actor AND idem_key = :key
                """).param("actor", actor.userId()).param("key", key)
                .query((rs, i) -> new Stored(rs.getString("request_hash"), rs.getInt("response_status"), rs.getString("body")))
                .optional();
        if (stored.isEmpty()) {
            problem(response, HttpStatus.CONFLICT, Problems.IDEMPOTENCY, "The first request with this Idempotency-Key failed. Retry it.");
            return;
        }
        if (!stored.get().hash().equals(hash)) {
            problem(response, HttpStatus.UNPROCESSABLE_ENTITY, Problems.IDEMPOTENCY,
                    "This Idempotency-Key was already used for a different request. Use a new key for a new request.");
            return;
        }
        if (stored.get().status() == 0) {
            problem(response, HttpStatus.CONFLICT, Problems.IDEMPOTENCY, "The first request with this Idempotency-Key is still running.");
            return;
        }
        JsonNode saved = mapper.readTree(stored.get().body());
        response.setStatus(stored.get().status());
        saved.path("headers").properties().forEach(e -> response.setHeader(e.getKey(), e.getValue().asText()));
        response.setHeader("Idempotent-Replayed", "true");
        JsonNode body = saved.get("body");
        if (body != null && !body.isNull()) {
            String type = saved.path("contentType").asText(MediaType.APPLICATION_JSON_VALUE);
            response.setContentType(type.isEmpty() ? MediaType.APPLICATION_JSON_VALUE : type);
            mapper.writeValue(response.getOutputStream(), body);
        }
    }

    private void problem(HttpServletResponse response, HttpStatus status, String type, String detail) throws IOException {
        ProblemDetail p = Problems.of(status, type, detail);
        response.setStatus(status.value());
        response.setContentType(MediaType.APPLICATION_PROBLEM_JSON_VALUE);
        mapper.writeValue(response.getOutputStream(), p);
    }

    private static String sha256(String s) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(s.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /** Reads the body once so it can be hashed and still be read by the controller. */
    static final class CachedBodyRequest extends HttpServletRequestWrapper {
        final byte[] body;

        CachedBodyRequest(HttpServletRequest request) throws IOException {
            super(request);
            this.body = request.getInputStream().readAllBytes();
        }

        @Override
        public ServletInputStream getInputStream() {
            ByteArrayInputStream in = new ByteArrayInputStream(body);
            return new ServletInputStream() {
                @Override public boolean isFinished() { return in.available() == 0; }
                @Override public boolean isReady() { return true; }
                @Override public void setReadListener(ReadListener listener) { throw new UnsupportedOperationException(); }
                @Override public int read() { return in.read(); }
            };
        }

        @Override
        public java.io.BufferedReader getReader() {
            return new java.io.BufferedReader(new java.io.InputStreamReader(getInputStream(), StandardCharsets.UTF_8));
        }
    }
}
