package com.mdm.api.common;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import java.time.Clock;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.util.function.Supplier;

/**
 * "Today" in the business calendar (ADR-018). The zone has one source of truth, the database row
 * {@code mdm.system_setting('business_time_zone')} (CR-01). An optional {@code mdm.business-time-zone} property may
 * be set as a cross-check; if it disagrees, the application refuses to work instead of using the wrong day.
 * Code never calls {@code LocalDate.now()} or relies on {@code current_date}; it asks this class.
 */
@Component
public class BusinessClock {

    private final Clock clock;
    private final Supplier<ZoneId> databaseZone;
    private final String configuredZone;
    private volatile ZoneId zone;

    @Autowired
    public BusinessClock(Clock clock, JdbcClient jdbc, @Value("${mdm.business-time-zone:}") String configuredZone) {
        this(clock, () -> ZoneId.of(jdbc.sql("SELECT setting_value FROM mdm.system_setting WHERE setting_key = 'business_time_zone'")
                .query(String.class).single()), configuredZone);
    }

    BusinessClock(Clock clock, Supplier<ZoneId> databaseZone, String configuredZone) {
        this.clock = clock;
        this.databaseZone = databaseZone;
        this.configuredZone = configuredZone == null ? "" : configuredZone.trim();
    }

    public ZoneId zone() {
        ZoneId z = zone;
        if (z == null) {
            z = databaseZone.get();
            if (!configuredZone.isEmpty() && !ZoneId.of(configuredZone).equals(z)) {
                throw new IllegalStateException("mdm.business-time-zone (" + configuredZone + ") disagrees with "
                        + "mdm.system_setting business_time_zone (" + z + "); the database value is authoritative (CR-01)");
            }
            zone = z;
        }
        return z;
    }

    public LocalDate today() {
        return LocalDate.ofInstant(clock.instant(), zone());
    }

    public Instant now() {
        return clock.instant();
    }
}
