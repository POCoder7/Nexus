package com.mdm.api.security;

import java.util.UUID;

/** The authenticated user of one request. Roles are looked up per check (they are bitemporal data), never carried here. */
public record Actor(UUID userId, String login, String displayName, String kind) {

    public boolean isHuman() {
        return "human".equals(kind);
    }
}
