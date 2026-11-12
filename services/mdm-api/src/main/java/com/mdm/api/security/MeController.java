package com.mdm.api.security;

import com.mdm.api.common.BusinessClock;
import com.mdm.api.common.ItemValidationException;
import com.mdm.api.common.RuleException;
import com.mdm.api.common.NotFoundException;
import com.mdm.api.hierarchy.HierarchyRepository;
import com.mdm.api.security.PreferencesRepository.Preferences;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.EnumSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;

/**
 * Who am I, what may I do, and what is "today" for the business (Phase 1 LLD §5.1, extended in Phase 3 LLD §5.1).
 * {@code permissions} tells the UI which actions to offer per hierarchy ({@code "*"} = every hierarchy). It is a hint
 * for the UI only: every endpoint still checks entitlements, and the database still enforces its guards.
 */
@RestController
@RequestMapping("/api/v1/me")
public class MeController {

    public static final String ALL_HIERARCHIES = "*";

    private final EntitlementService entitlements;
    private final BusinessClock clock;
    private final PreferencesRepository preferences;
    private final HierarchyRepository hierarchies;

    public MeController(EntitlementService entitlements, BusinessClock clock, PreferencesRepository preferences,
                        HierarchyRepository hierarchies) {
        this.entitlements = entitlements;
        this.clock = clock;
        this.preferences = preferences;
        this.hierarchies = hierarchies;
    }

    /**
     * {@code workingVersion}: the version new change requests are raised in, for the context bar: the user's chosen
     * working version while it is still working, otherwise the latest working version (ADR-037).
     */
    public record MeView(Actor actor, LocalDate businessToday, String businessTimeZone, String workingVersion, Preferences preferences,
                         Map<String, Set<Permission>> permissions, List<Grant> grants) {
    }

    /** Partial update: a null field keeps the stored value. */
    public record PreferencesUpdate(String startPage, String lastHierarchyCode, String density, String workingVersion) {
    }

    @GetMapping
    public MeView getMe(Actor actor) {
        List<Grant> grants = entitlements.grants(actor);
        return new MeView(actor, clock.today(), clock.zone().getId(), preferences.workingVersion(actor.userId()).orElse(null),
                preferences.find(actor.userId()), permissions(grants), grants);
    }

    @PutMapping("/preferences")
    public Preferences updatePreferences(Actor actor, @RequestBody PreferencesUpdate body) {
        if (body == null) {
            throw new IllegalArgumentException("A preferences body is required");
        }
        if (body.startPage() != null && !PreferencesRepository.START_PAGES.contains(body.startPage())) {
            throw new IllegalArgumentException("startPage must be one of " + new TreeSet<>(PreferencesRepository.START_PAGES));
        }
        if (body.density() != null && !PreferencesRepository.DENSITIES.contains(body.density())) {
            throw new IllegalArgumentException("density must be one of " + new TreeSet<>(PreferencesRepository.DENSITIES));
        }
        UUID hierarchyId = null;
        if (body.lastHierarchyCode() != null) {
            // same 404 as reading the hierarchy, so a preference cannot reveal that a hierarchy exists
            hierarchyId = hierarchies.findIdByCode(body.lastHierarchyCode())
                    .filter(id -> entitlements.canRead(actor, id))
                    .orElseThrow(() -> new NotFoundException("Hierarchy " + body.lastHierarchyCode() + " not found"));
        }
        UUID versionId = null;
        if (body.workingVersion() != null) {
            PreferencesRepository.VersionStatus v = preferences.versionStatus(body.workingVersion())
                    .orElseThrow(() -> ItemValidationException.field("workingVersion", "unknown version " + body.workingVersion()));
            if (!"working".equals(v.status())) {
                // the same words as the database's N2703: new requests are raised only in working versions
                throw new RuleException("version.not_working", "Version " + body.workingVersion() + " is " + v.status()
                        + ", not working: requests cannot be raised in it, moved to it or advanced in it");
            }
            versionId = v.id();
        }
        preferences.save(actor.userId(), body.startPage(), hierarchyId, body.density(), versionId);
        return preferences.find(actor.userId());
    }

    /** Permissions per hierarchy code, from the role matrix (ADR-022); sub-tree grants count for their hierarchy. */
    static Map<String, Set<Permission>> permissions(List<Grant> grants) {
        Map<String, Set<Permission>> out = new LinkedHashMap<>();
        for (Grant g : grants) {
            String key = g.allHierarchies() ? ALL_HIERARCHIES : g.hierarchyCode();
            Set<Permission> set = out.computeIfAbsent(key, k -> EnumSet.noneOf(Permission.class));
            for (Permission p : Permission.values()) {
                if (RolePermissions.allows(g.roleCode(), p)) {
                    set.add(p);
                }
            }
        }
        return out;
    }
}
