package com.mdm.api.ledger;

import com.mdm.api.common.ItemValidationException;
import com.mdm.api.security.Actor;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.regex.Pattern;

/**
 * Ledgers (ADR-046 D4, Phase 4 LLD §17.4): reference data for the finance attributes and rule VR17. Not bitemporal and
 * never deleted; an ADMIN retires a ledger with {@code active = false}. The audit trigger records each change with the
 * caller as actor (set for this transaction only).
 */
@Service
public class LedgerService {

    private static final Pattern ID = Pattern.compile("\\S{1,20}");
    private static final Pattern CURRENCY = Pattern.compile("[A-Z]{3}");

    public record Ledger(String id, String name, String currency, String financeCountry, boolean active) {
    }

    /** The body of {@code PUT /admin/ledgers/{id}}. {@code active} defaults to true. */
    public record LedgerUpdate(String name, String currency, String financeCountry, Boolean active) {
    }

    /** The saved ledger, and whether this call created it. */
    public record Saved(Ledger ledger, boolean created) {
    }

    private final JdbcClient jdbc;

    public LedgerService(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    /** One keyset page by id ({@code limit + 1} rows). */
    public List<Ledger> page(String afterId, int limit) {
        return jdbc.sql("""
                SELECT ledger_id, ledger_name, currency_code, finance_country, is_active FROM mdm.ledger
                WHERE CAST(:after AS text) IS NULL OR ledger_id COLLATE "C" > CAST(:after AS text) COLLATE "C"
                ORDER BY ledger_id COLLATE "C" LIMIT :limit
                """).param("after", afterId).param("limit", limit + 1)
                .query((rs, i) -> new Ledger(rs.getString(1), rs.getString(2), rs.getString(3), rs.getString(4), rs.getBoolean(5)))
                .list();
    }

    /** Creates or replaces a ledger. The caller has been checked for ADMIN. */
    @Transactional
    public Saved save(Actor actor, String id, LedgerUpdate u) {
        if (id == null || !ID.matcher(id).matches()) {
            throw ItemValidationException.field("id", "must be 1 to 20 characters without spaces");
        }
        if (u == null || u.name() == null || u.name().isBlank()) {
            throw ItemValidationException.field("name", "is required");
        }
        if (u.currency() == null || !CURRENCY.matcher(u.currency()).matches()) {
            throw ItemValidationException.field("currency", "must be three upper-case letters, e.g. USD");
        }
        if (u.financeCountry() == null || u.financeCountry().isBlank()) {
            throw ItemValidationException.field("financeCountry", "is required");
        }
        boolean active = u.active() == null || u.active();
        jdbc.sql("SELECT set_config('mdm.actor_id', :a, true)").param("a", actor.userId().toString()).query(String.class).single();
        boolean created = jdbc.sql("""
                INSERT INTO mdm.ledger (ledger_id, ledger_name, currency_code, finance_country, is_active)
                VALUES (:id, :name, :ccy, :country, :active)
                ON CONFLICT (ledger_id) DO UPDATE SET ledger_name = EXCLUDED.ledger_name, currency_code = EXCLUDED.currency_code,
                  finance_country = EXCLUDED.finance_country, is_active = EXCLUDED.is_active
                RETURNING (xmax = 0)
                """).param("id", id).param("name", u.name().strip()).param("ccy", u.currency()).param("country", u.financeCountry().strip())
                .param("active", active).query(Boolean.class).single();
        return new Saved(new Ledger(id, u.name().strip(), u.currency(), u.financeCountry().strip(), active), created);
    }
}
