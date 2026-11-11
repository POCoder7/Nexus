package com.mdm.api.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.common.CorrelationIdFilter;
import com.mdm.api.common.Problems;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.MDC;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ProblemDetail;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.Optional;

/**
 * Every API request needs an actor (Phase 1 LLD §3.1). The filter resolves it through {@link CurrentActor}, stores it
 * on the request and in the logging MDC, and answers 401 when there is none. It authorises nothing: permission
 * checks are {@link EntitlementService}'s job, and controls such as maker-checker live in the database.
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 10)
public class ActorFilter extends OncePerRequestFilter {

    public static final String ATTRIBUTE = ActorFilter.class.getName() + ".actor";
    static final String MDC_KEY = "actorId";

    private final ObjectProvider<CurrentActor> currentActor;
    private final ObjectMapper mapper;

    public ActorFilter(ObjectProvider<CurrentActor> currentActor, ObjectMapper mapper) {
        this.currentActor = currentActor;
        this.mapper = mapper;
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        return !request.getRequestURI().startsWith("/api/");
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        CurrentActor resolver = currentActor.getIfAvailable();
        Optional<Actor> actor = resolver == null ? Optional.empty() : resolver.resolve(request);
        if (actor.isEmpty()) {
            ProblemDetail p = Problems.of(HttpStatus.UNAUTHORIZED, Problems.UNAUTHENTICATED,
                    "Sign in to use Nexus. If you are signed in, your account is not set up in Nexus yet.");
            String correlationId = CorrelationIdFilter.current(request);
            if (correlationId != null) {
                p.setProperty("correlationId", correlationId);
            }
            response.setStatus(HttpStatus.UNAUTHORIZED.value());
            response.setContentType(MediaType.APPLICATION_PROBLEM_JSON_VALUE);
            mapper.writeValue(response.getOutputStream(), p);
            return;
        }
        request.setAttribute(ATTRIBUTE, actor.get());
        MDC.put(MDC_KEY, actor.get().userId().toString());
        try {
            chain.doFilter(request, response);
        } finally {
            MDC.remove(MDC_KEY);
        }
    }
}
