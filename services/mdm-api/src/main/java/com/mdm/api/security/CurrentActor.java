package com.mdm.api.security;

import jakarta.servlet.http.HttpServletRequest;

import java.util.Optional;

/**
 * Port: who is making this request (ADR-013, ADR-022, ADR-033). Phase 1 has only the development adapter
 * {@link LocalDevActor}; Phase 9 adds the identity-provider adapter. No other code knows how identity is established.
 */
public interface CurrentActor {

    Optional<Actor> resolve(HttpServletRequest request);
}
