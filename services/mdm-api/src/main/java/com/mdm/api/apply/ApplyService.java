package com.mdm.api.apply;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.NestedExceptionUtils;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.SQLException;
import java.util.Set;
import java.util.UUID;

/**
 * Applies an approved change request (Phase 1 LLD §3.3, §6.4) by calling {@code mdm.apply_change_request} in its own
 * transaction, after the decision has committed. The item logic is SQL (ADR-019); this class only retries
 * serialization failures and deadlocks, up to {@code mdm.apply.tx-retry-max} attempts (TX_RETRY_MAX), and records a
 * request that still cannot be applied as {@code apply_failed} so it does not stay approved for ever.
 */
@Service
public class ApplyService {

    private static final Logger log = LoggerFactory.getLogger(ApplyService.class);
    private static final Set<String> RETRYABLE = Set.of("40001", "40P01");

    public record ApplyResult(String status, String applyError, int rowsWritten) {
    }

    private final JdbcClient jdbc;
    private final TransactionTemplate tx;
    private final int maxAttempts;

    public ApplyService(JdbcClient jdbc, PlatformTransactionManager transactions,
                        @Value("${mdm.apply.tx-retry-max:3}") int maxAttempts) {
        this.jdbc = jdbc;
        this.tx = new TransactionTemplate(transactions);
        this.tx.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        this.maxAttempts = Math.max(1, maxAttempts);
    }

    /** Applies the request as {@code actorId} (the decider). Idempotent: an applied request is left as it is. */
    public ApplyResult apply(UUID actorId, UUID changeRequestId) {
        long started = System.nanoTime();
        for (int attempt = 1; ; attempt++) {
            try {
                Integer rows = tx.execute(s -> jdbc.sql("SELECT mdm.apply_change_request(:cr, :actor)")
                        .param("cr", changeRequestId).param("actor", actorId).query(Integer.class).single());
                ApplyResult result = outcome(changeRequestId, rows == null ? 0 : rows);
                log.info("change_request.{} changeRequestId={} actorId={} rows={} attempt={} durationMs={}",
                        result.status(), changeRequestId, actorId, result.rowsWritten(), attempt,
                        (System.nanoTime() - started) / 1_000_000);
                return result;
            } catch (DataAccessException e) {
                String state = sqlState(e);
                if (!RETRYABLE.contains(state)) {
                    throw e;
                }
                if (attempt >= maxAttempts) {
                    String reason = "SQLSTATE " + state + " after " + attempt + " attempts";
                    tx.executeWithoutResult(s -> jdbc.sql("SELECT mdm.record_apply_failure(:cr, :reason)")
                            .param("cr", changeRequestId).param("reason", reason).query((rs, i) -> 0).single());
                    log.error("change_request.apply_failed changeRequestId={} reason=\"{}\" alert=true", changeRequestId, reason);
                    return outcome(changeRequestId, 0);
                }
                log.warn("change_request.apply_retry changeRequestId={} sqlState={} attempt={}", changeRequestId, state, attempt);
            }
        }
    }

    private ApplyResult outcome(UUID changeRequestId, int rows) {
        return jdbc.sql("SELECT status::text AS status, apply_error FROM mdm.change_request WHERE change_request_id = :cr")
                .param("cr", changeRequestId)
                .query((rs, i) -> new ApplyResult(rs.getString("status"), rs.getString("apply_error"), Math.max(rows, 0)))
                .single();
    }

    private static String sqlState(DataAccessException e) {
        return NestedExceptionUtils.getMostSpecificCause(e) instanceof SQLException sql ? sql.getSQLState() : null;
    }
}
