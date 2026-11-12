package com.mdm.api.common;

import com.mdm.api.security.Actor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Clock;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;

/**
 * Client error reports from the UI (Phase 3 LLD §11): status, problem type, correlation id and route only. Anything else
 * the client sends is ignored, the route loses its query string (it can carry search text), and each field is bounded,
 * so no property value or personal data reaches the log. Rate-limited per user; reports are logged, not stored.
 */
@RestController
@RequestMapping("/api/v1/client-errors")
public class ClientErrorController {

    static final int MAX_PER_MINUTE = 20;
    private static final Logger LOG = LoggerFactory.getLogger("nexus.client-error");
    private static final Pattern SAFE = Pattern.compile("[^A-Za-z0-9/:._\\-]");

    public record ClientError(Integer status, String type, String correlationId, String route) {
    }

    /** Thrown when a user exceeds the report rate (429). */
    public static class TooManyReportsException extends RuntimeException {
        public TooManyReportsException() {
            super("Too many error reports; try again in a minute.");
        }
    }

    private final Map<UUID, Deque<Long>> recent = new ConcurrentHashMap<>();
    private final Clock clock;

    public ClientErrorController(Clock clock) {
        this.clock = clock;
    }

    @PostMapping
    public ResponseEntity<Void> reportClientError(Actor actor, @RequestBody ClientError body) {
        allow(actor.userId());
        LOG.warn("client_error user={} status={} type={} correlationId={} route={}", actor.userId(),
                body == null || body.status() == null ? null : Math.max(0, Math.min(999, body.status())),
                clean(body == null ? null : body.type(), 120),
                clean(body == null ? null : body.correlationId(), 64),
                clean(body == null || body.route() == null ? null : body.route().split("[?#]", 2)[0], 200));
        return ResponseEntity.status(HttpStatus.ACCEPTED).build();
    }

    private void allow(UUID user) {
        long now = clock.millis();
        Deque<Long> times = recent.computeIfAbsent(user, u -> new ArrayDeque<>());
        synchronized (times) {
            while (!times.isEmpty() && now - times.peekFirst() >= 60_000) {
                times.pollFirst();
            }
            if (times.size() >= MAX_PER_MINUTE) {
                throw new TooManyReportsException();
            }
            times.addLast(now);
        }
    }

    static String clean(String s, int max) {
        if (s == null) {
            return null;
        }
        String safe = SAFE.matcher(s).replaceAll("_");
        return safe.length() > max ? safe.substring(0, max) : safe;
    }
}
