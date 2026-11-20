package com.mdm.api.ledger;

import com.mdm.api.common.Cursors;
import com.mdm.api.common.Page;
import com.mdm.api.ledger.LedgerService.Ledger;
import com.mdm.api.ledger.LedgerService.LedgerUpdate;
import com.mdm.api.ledger.LedgerService.Saved;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import com.mdm.api.security.ForbiddenException;
import com.mdm.api.security.Permission;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/** Ledgers (ADR-046 D4): read by every role that can read a hierarchy; created, changed and retired by an ADMIN. */
@RestController
@RequestMapping("/api/v1")
public class LedgerController {

    private final LedgerService ledgers;
    private final EntitlementService entitlements;
    private final Cursors cursors;

    public LedgerController(LedgerService ledgers, EntitlementService entitlements, Cursors cursors) {
        this.ledgers = ledgers;
        this.entitlements = entitlements;
        this.cursors = cursors;
    }

    @GetMapping("/ledgers")
    public Page<Ledger> listLedgers(Actor actor, @RequestParam(defaultValue = "200") int limit,
                                    @RequestParam(required = false) String cursor) {
        cursors.checkLimit(limit);
        if (!entitlements.hasAny(actor, Permission.READ)) {
            throw new ForbiddenException("entitlement.missing", "You don't have read access to any hierarchy.");
        }
        List<String> after = cursors.decode(cursor, 1);
        return Page.of(ledgers.page(after == null ? null : after.get(0), limit), limit, l -> cursors.encode(l.id()));
    }

    /** Creates (201) or replaces (200) a ledger. ADMIN only; audited. */
    @PutMapping("/admin/ledgers/{id}")
    public ResponseEntity<Ledger> saveLedger(Actor actor, @PathVariable String id, @RequestBody LedgerUpdate body) {
        if (!entitlements.hasAny(actor, Permission.ADMIN_SYSTEM)) {
            throw new ForbiddenException("entitlement.missing", "Only an administrator can change ledgers.");
        }
        Saved saved = ledgers.save(actor, id, body);
        return ResponseEntity.status(saved.created() ? HttpStatus.CREATED : HttpStatus.OK).body(saved.ledger());
    }
}
