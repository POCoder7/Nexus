package com.mdm.api.common;

/**
 * ETags are the request's {@code row_version} (ADR-015). Writes to a draft must send {@code If-Match}; a missing
 * header is 428, a stale one 412, so two editors never silently overwrite each other.
 */
public final class ETags {

    private ETags() {
    }

    public static String of(int rowVersion) {
        return "\"" + rowVersion + "\"";
    }

    /** Parses {@code If-Match} ({@code "3"} or {@code W/"3"}); throws 428 when absent and 400 when malformed. */
    public static int require(String ifMatch) {
        if (ifMatch == null || ifMatch.isBlank()) {
            throw new PreconditionRequiredException();
        }
        String v = ifMatch.trim();
        if (v.startsWith("W/")) {
            v = v.substring(2);
        }
        v = v.replace("\"", "");
        try {
            return Integer.parseInt(v);
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("If-Match must be the ETag returned by the last read or write");
        }
    }

    public static void check(int expected, int actual) {
        if (expected != actual) {
            throw new PreconditionFailedException(actual);
        }
    }

    /** 428: the write needs If-Match. */
    public static class PreconditionRequiredException extends RuntimeException {
        public PreconditionRequiredException() {
            super("Send If-Match with the ETag you last read, so a change made by someone else is not overwritten.");
        }
    }

    /** 412: the resource changed since the caller read it. */
    public static class PreconditionFailedException extends RuntimeException {
        private final int current;

        public PreconditionFailedException(int current) {
            super("This was changed by someone else. Reload to see the latest version.");
            this.current = current;
        }

        public int current() {
            return current;
        }
    }
}
