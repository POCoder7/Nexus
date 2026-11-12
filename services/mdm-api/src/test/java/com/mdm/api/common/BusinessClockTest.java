package com.mdm.api.common;

import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.ZoneOffset;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** ADR-018: "today" is the business date in America/New_York, whatever the JVM or database zone is. */
class BusinessClockTest {

    private static BusinessClock at(String instant) {
        return new BusinessClock(Clock.fixed(Instant.parse(instant), ZoneOffset.UTC), () -> ZoneId.of("America/New_York"), "");
    }

    @Test
    void winterUsesEst() {
        assertThat(at("2027-01-12T03:30:00Z").today()).isEqualTo(LocalDate.of(2027, 1, 11));  // 22:30 EST
        assertThat(at("2027-01-12T05:00:00Z").today()).isEqualTo(LocalDate.of(2027, 1, 12));  // 00:00 EST
    }

    @Test
    void summerUsesEdt() {
        assertThat(at("2027-07-12T03:30:00Z").today()).isEqualTo(LocalDate.of(2027, 7, 11));  // 23:30 EDT
        assertThat(at("2027-07-12T04:00:00Z").today()).isEqualTo(LocalDate.of(2027, 7, 12));  // 00:00 EDT
    }

    @Test
    void daylightSavingChangeDays() {
        // 14 Mar 2027: clocks go forward at 02:00 EST; 7 Nov 2027: back at 02:00 EDT.
        assertThat(at("2027-03-14T04:59:00Z").today()).isEqualTo(LocalDate.of(2027, 3, 13));
        assertThat(at("2027-03-14T05:00:00Z").today()).isEqualTo(LocalDate.of(2027, 3, 14));
        assertThat(at("2027-11-07T03:59:00Z").today()).isEqualTo(LocalDate.of(2027, 11, 6));
        assertThat(at("2027-11-07T04:00:00Z").today()).isEqualTo(LocalDate.of(2027, 11, 7));
    }

    @Test
    void aConfiguredZoneThatDisagreesWithTheDatabaseIsRefused() {
        BusinessClock clock = new BusinessClock(Clock.systemUTC(), () -> ZoneId.of("America/New_York"), "Europe/London");
        assertThatThrownBy(clock::zone).isInstanceOf(IllegalStateException.class).hasMessageContaining("business_time_zone");
    }

    @Test
    void aConfiguredZoneThatAgreesIsAccepted() {
        BusinessClock clock = new BusinessClock(Clock.systemUTC(), () -> ZoneId.of("America/New_York"), "America/New_York");
        assertThat(clock.zone()).isEqualTo(ZoneId.of("America/New_York"));
    }
}
