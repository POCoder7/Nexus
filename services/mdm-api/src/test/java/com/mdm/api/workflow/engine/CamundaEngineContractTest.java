package com.mdm.api.workflow.engine;

import com.mdm.api.workflow.engine.camunda.CamundaWorkflowEngine;
import io.camunda.process.test.api.CamundaSpringProcessTest;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Tag;
import org.springframework.test.context.TestPropertySource;

import java.util.Objects;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * The engine contract (ADR-035) on Camunda 8, using Camunda's process-test engine (Testcontainers). Tagged
 * {@code camunda}: run with {@code ./mvnw -B verify -Dcamunda}. The same scenarios as the in-process driver; Camunda
 * works asynchronously, so {@link #drain()} waits until the requests stop changing.
 */
@Tag("camunda")
@CamundaSpringProcessTest
@TestPropertySource(properties = "mdm.workflow.engine=camunda")
class CamundaEngineContractTest extends WorkflowEngineContract {

    @BeforeEach
    void deployProcess() {
        assertThat(engine).isInstanceOf(CamundaWorkflowEngine.class);
        engine.deploy();
    }

    @Override
    protected void drain() throws Exception {
        String last = null;
        int stable = 0;
        long deadline = System.currentTimeMillis() + 60_000;
        while (System.currentTimeMillis() < deadline) {
            int relayed = relay.poll();
            Thread.sleep(300);
            String now = snapshot();
            stable = relayed == 0 && Objects.equals(now, last) ? stable + 1 : 0;
            if (stable >= 4) {
                return;
            }
            last = now;
        }
        throw new AssertionError("Camunda did not settle within 60 s; last state: " + last);
    }

    /** Everything a step can change for the contract's requests: stage states, instance and request status, events. */
    private String snapshot() {
        return ownerJdbc().sql("""
                SELECT coalesce(string_agg(cr.change_request_id || cr.status || i.status || i.current_seq || st.states, ',' ORDER BY cr.change_request_id), '')
                       || '#' || (SELECT max(event_id) FROM wf.event_outbox)
                FROM mdm.change_request cr
                JOIN wf.workflow_instance i ON i.change_request_id = cr.change_request_id
                CROSS JOIN LATERAL (SELECT string_agg(ist.status::text, '' ORDER BY ist.seq) AS states FROM wf.instance_stage ist
                                    WHERE ist.instance_id = i.instance_id) st
                WHERE cr.title LIKE 'CT %'
                """).query(String.class).single();
    }
}
