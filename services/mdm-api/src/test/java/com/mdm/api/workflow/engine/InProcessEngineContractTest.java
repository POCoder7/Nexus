package com.mdm.api.workflow.engine;

import com.mdm.api.workflow.engine.inprocess.InProcessWorkflowEngine;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** The engine contract (ADR-035) on the in-process reference driver: the default build's workflow coverage. */
class InProcessEngineContractTest extends WorkflowEngineContract {

    @Override
    protected void drain() {
        assertThat(engine).isInstanceOf(InProcessWorkflowEngine.class);
        for (int i = 0; i < 50 && relay.poll() > 0; i++) {
            // the in-process driver acts synchronously on each relayed event
        }
    }

    /** For this driver, losing processes is what a worker restart does. */
    @Override
    protected void loseProcess(UUID instanceId) {
        ((InProcessWorkflowEngine) engine).restart();
    }

    /**
     * Resilience (LLD §6.5): a step that fails (here, policy evaluation without its system actor) stops the relay at
     * that event. The person's decision is kept; once the cause is fixed, the next poll carries on from the same event.
     */
    @Test
    void aFailingStepKeepsTheDecisionAndResumesWhenFixed() throws Exception {
        String cr = submit("CT_ADD", updateLeaf());
        drain();
        UUID stage = activeStage(cr);
        ownerJdbc().sql("UPDATE mdm.app_user SET is_active = false WHERE login = 'nexus_system'").update();
        try {
            decide(APPROVER, stage, "approve");
            long before = offset();
            relay.poll();                                                       // the step fails
            assertThat(offset()).as("the relay stays before the failed event").isEqualTo(before);
            assertThat(ownerJdbc().sql("SELECT count(*) FROM wf.stage_group_decision WHERE instance_stage_id = :s AND decision = 'approve'")
                    .param("s", stage).query(Integer.class).single()).as("the decision is kept").isEqualTo(1);
        } finally {
            ownerJdbc().sql("UPDATE mdm.app_user SET is_active = true WHERE login = 'nexus_system'").update();
        }
        drain();
        assertThat(currentStage(cr)).isEqualTo("commit/active");
    }
}
