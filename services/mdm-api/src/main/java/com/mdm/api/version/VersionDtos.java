package com.mdm.api.version;

import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Request and response bodies for the versions API (VER-01, VER-02; Phase 3 LLD V.5, ADR-037). */
public final class VersionDtos {

    private VersionDtos() {
    }

    /** A person named on a version (creator, submitter, finalizer). Null when the version predates V11. */
    public record PersonRef(UUID id, String displayName) {
    }

    /**
     * One lifecycle move offered from the version's status, for the caller: {@code allowed}, or {@code whyNot} in words.
     * The rules match the database guards; the database stays the last word.
     */
    public record VersionTransition(String to, boolean allowed, String whyNot) {
    }

    /** Whether the caller may change the name and description now, and if not, why. */
    public record VersionEdit(boolean allowed, String whyNot) {
    }

    /** Requests in the version by status. Requests that are submitted, in review or approved block a submit (N2704). */
    public record OpenRequests(long draft, long submitted, long inReview, long approved) {

        public long inFlight() {
            return submitted + inReview + approved;
        }
    }

    /**
     * A version: a name, a business date and, once frozen, the recorded time of its picture ({@code recordedAsOf}).
     * {@code revision} is the ETag. {@code openRequests} is filled on the single read only.
     */
    public record VersionView(String name, String status, LocalDate businessAsOf, Instant recordedAsOf, String baseVersion,
                              String description, Instant createdAt, PersonRef createdBy, Instant submittedAt,
                              PersonRef submittedBy, Instant finalizedAt, PersonRef finalizedBy, int revision,
                              List<VersionTransition> transitions, VersionEdit edit, OpenRequests openRequests) {
    }

    /** {@code businessAsOf} may be left out when copying: the copy then takes its base's business date. */
    public record CreateVersion(String name, LocalDate businessAsOf, String baseVersion, String description) {
    }

    /** Partial update: a null field keeps the stored value; an empty description clears it. */
    public record UpdateVersion(String name, String description) {
    }

    /** {@code to}: submitted (submit), working (reopen), finalized or expired. The reason is optional and logged. */
    public record VersionTransitionRequest(String to, String reason) {
    }
}
