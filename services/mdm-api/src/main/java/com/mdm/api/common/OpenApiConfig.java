package com.mdm.api.common;

import com.mdm.api.security.Actor;
import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import org.springdoc.core.utils.SpringDocUtils;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * OpenAPI description of the API (BUILD_PROTOCOL step 6). The {@link Actor} parameter is resolved from the identity
 * adapter, never from the request, so it is not part of the documented interface. Served at /v3/api-docs only where
 * {@code springdoc.api-docs.enabled=true} (local and test profiles).
 */
@Configuration
public class OpenApiConfig {

    static {
        SpringDocUtils.getConfig().addRequestWrapperToIgnore(Actor.class);
    }

    @Bean
    public OpenAPI nexusOpenApi() {
        return new OpenAPI().info(new Info()
                .title("Nexus MDM API")
                .version("phase-1")
                .description("Hierarchies, nodes and change requests (core mode). Conventions: ADR-015 (keyset paging, "
                        + "ETag / If-Match, Idempotency-Key), errors as Problem Details with codes (ADR-020). "
                        + "Every /api request needs an authenticated actor."));
    }
}
