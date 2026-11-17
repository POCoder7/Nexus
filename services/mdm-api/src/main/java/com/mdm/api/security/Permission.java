package com.mdm.api.security;

/** What a role allows (Phase 1 LLD §3.1; later phases add permissions, CONSISTENCY_REVIEW CR-11; ADR-042 adds the last three). */
public enum Permission {
    READ,
    PROPOSE,
    DECIDE,
    ADMIN_WORKFLOW,
    ADMIN_POLICY,
    ADMIN_SYSTEM,
    /** Create versions and move them through their lifecycle (VER-01, VER-02; V11, ADR-037). */
    ADMIN_VERSION,
    /** Decide a workflow stage in place of its group, with a reason (ADR-042 D4; Phase 5 LLD §19.5). */
    OVERRIDE_WORKFLOW,
    /** Publish output to downstream systems (used from Phase 8). */
    PUBLISH,
    /** Read published output only: export files and the change-event feed (CONSUMER; guards no endpoint until Phase 8). */
    READ_PUBLISHED
}
