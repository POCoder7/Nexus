package com.mdm.api.security;

/** What a role allows (Phase 1 LLD §3.1; later phases add permissions, CONSISTENCY_REVIEW CR-11). */
public enum Permission {
    READ,
    PROPOSE,
    DECIDE,
    ADMIN_WORKFLOW,
    ADMIN_POLICY,
    ADMIN_SYSTEM,
    /** Create versions and move them through their lifecycle (VER-01, VER-02; V11, ADR-037). */
    ADMIN_VERSION
}
