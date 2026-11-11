package com.mdm.api.apply;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.UUID;

/**
 * Applies requests left {@code approved} for over a minute, for example when the API stopped between the decision
 * and its apply (LLD §6.4). Runs shortly after startup and then every minute. Apply is idempotent, so a request that
 * another instance applies at the same moment is simply left as it is. Disabled with {@code mdm.apply.sweep.enabled=false}.
 */
@Component
@EnableScheduling
@ConditionalOnProperty(name = "mdm.apply.sweep.enabled", havingValue = "true", matchIfMissing = true)
public class ApplySweeper {

    private static final Logger log = LoggerFactory.getLogger(ApplySweeper.class);

    private final JdbcClient jdbc;
    private final ApplyService apply;

    public ApplySweeper(JdbcClient jdbc, ApplyService apply) {
        this.jdbc = jdbc;
        this.apply = apply;
    }

    @Scheduled(initialDelayString = "${mdm.apply.sweep.initial-delay-ms:10000}", fixedDelayString = "${mdm.apply.sweep.interval-ms:60000}")
    public void sweep() {
        record Pending(UUID id, UUID decidedBy) {
        }
        List<Pending> pending = jdbc.sql("""
                SELECT change_request_id, decided_by FROM mdm.change_request
                WHERE status = 'approved' AND decided_at < now() - interval '1 minute'
                ORDER BY decided_at LIMIT 100
                """).query((rs, i) -> new Pending(rs.getObject(1, UUID.class), rs.getObject(2, UUID.class))).list();
        for (Pending p : pending) {
            try {
                apply.apply(p.decidedBy(), p.id());
            } catch (RuntimeException e) {
                log.error("change_request.sweep_failed changeRequestId={} alert=true", p.id(), e);
            }
        }
    }
}
