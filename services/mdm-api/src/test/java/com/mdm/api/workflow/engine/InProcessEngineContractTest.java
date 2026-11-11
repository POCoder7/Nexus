package com.mdm.api.workflow.engine;

import com.mdm.api.workflow.engine.inprocess.InProcessWorkflowEngine;

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
}
