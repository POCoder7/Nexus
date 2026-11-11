package com.mdm.api.security;

import com.mdm.api.common.BusinessClock;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.SmartInitializingSingleton;
import org.springframework.stereotype.Component;

/**
 * Refuses to start without a way to identify users (Phase 1 LLD §3.1): outside the {@code local} and {@code test}
 * profiles the development adapter does not exist, so until the identity-provider adapter is built (Phase 9, OD-06)
 * the API cannot run in a shared environment. Also checks the business time zone once at startup (CR-01).
 */
@Component
public class StartupGuard implements SmartInitializingSingleton {

    private final ObjectProvider<CurrentActor> currentActor;
    private final BusinessClock businessClock;

    public StartupGuard(ObjectProvider<CurrentActor> currentActor, BusinessClock businessClock) {
        this.currentActor = currentActor;
        this.businessClock = businessClock;
    }

    @Override
    public void afterSingletonsInstantiated() {
        if (currentActor.getIfAvailable() == null) {
            throw new IllegalStateException("No identity adapter (CurrentActor) is configured. The development adapter "
                    + "exists only in the 'local' and 'test' profiles; production identity arrives with OD-06 (Phase 9).");
        }
        businessClock.zone();
    }
}
