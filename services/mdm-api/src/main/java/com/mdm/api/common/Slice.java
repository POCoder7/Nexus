package com.mdm.api.common;

import java.time.Instant;
import java.time.LocalDate;

/**
 * The bitemporal coordinates of a read (ADR-006, ADR-018, NEW-01): a business date and, optionally, a recorded instant.
 * Without {@code recordedAsOf} the read uses the current belief ({@code upper_inf(recorded_period)}, index-friendly).
 */
public record Slice(LocalDate asOf, Instant recordedAsOf) {

    public static Slice of(LocalDate asOf, Instant recordedAsOf, BusinessClock clock) {
        return new Slice(asOf == null ? clock.today() : asOf, recordedAsOf);
    }

    /**
     * SQL predicate selecting the belief held at this slice's recorded time, for a table alias. The alias is a
     * constant chosen by the repository (never user input); the instant is bound as {@code :rec}.
     */
    public String recorded(String alias) {
        return recordedAsOf == null
                ? "upper_inf(" + alias + ".recorded_period)"
                : alias + ".recorded_period @> CAST(:rec AS timestamptz)";
    }

    public java.sql.Timestamp recBind() {
        return recordedAsOf == null ? null : java.sql.Timestamp.from(recordedAsOf);
    }
}
