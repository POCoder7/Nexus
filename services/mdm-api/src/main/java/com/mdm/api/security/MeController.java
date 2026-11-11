package com.mdm.api.security;

import com.mdm.api.common.BusinessClock;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.List;

/** Who am I, what may I do, and what is "today" for the business (Phase 1 LLD §5.1; Phase 3 extends it). */
@RestController
@RequestMapping("/api/v1/me")
public class MeController {

    private final EntitlementService entitlements;
    private final BusinessClock clock;

    public MeController(EntitlementService entitlements, BusinessClock clock) {
        this.entitlements = entitlements;
        this.clock = clock;
    }

    public record MeView(Actor actor, LocalDate businessToday, String businessTimeZone, List<Grant> grants) {
    }

    @GetMapping
    public MeView me(Actor actor) {
        return new MeView(actor, clock.today(), clock.zone().getId(), entitlements.grants(actor));
    }
}
