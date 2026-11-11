package com.mdm.api.common;

import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;

import java.net.URI;

/** Problem Details type URNs (overview §9). One place, so the UI and clients can rely on them. */
public final class Problems {

    public static final String NOT_FOUND = "not-found";
    public static final String INVALID_REQUEST = "invalid-request";
    public static final String VALIDATION_FAILED = "validation-failed";
    public static final String RULE_VIOLATION = "rule-violation";
    public static final String CONFLICT = "conflict";
    public static final String CONSTRAINT_VIOLATION = "constraint-violation";
    public static final String STALE_RESOURCE = "stale-resource";
    public static final String CONFLICT_STALE_BASE = "conflict-stale-base";
    public static final String FORBIDDEN = "forbidden";
    public static final String UNAUTHENTICATED = "unauthenticated";
    public static final String RETRY_LATER = "retry-later";
    public static final String INTERNAL = "internal-error";

    private Problems() {
    }

    public static URI type(String code) {
        return URI.create("urn:nexus:problem:" + code);
    }

    public static ProblemDetail of(HttpStatus status, String type, String detail) {
        ProblemDetail p = ProblemDetail.forStatusAndDetail(status, detail);
        p.setType(type(type));
        return p;
    }
}
