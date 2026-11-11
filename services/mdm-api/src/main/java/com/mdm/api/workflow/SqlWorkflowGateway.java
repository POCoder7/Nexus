package com.mdm.api.workflow;

import com.fasterxml.jackson.databind.JsonNode;
import com.mdm.api.security.Actor;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import java.util.Optional;
import java.util.UUID;

/** {@link WorkflowGateway} over the owner-run {@code wf} / {@code wf_bridge} functions (callable by {@code nexus_api}). */
@Component
public class SqlWorkflowGateway implements WorkflowGateway {

    private final JdbcClient jdbc;

    public SqlWorkflowGateway(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    @Override
    public UUID startInstance(UUID changeRequestId, String modelCode, Actor submitter) {
        return jdbc.sql("SELECT wf.start_instance(:cr, :model, :actor)")
                .param("cr", changeRequestId).param("model", modelCode).param("actor", submitter.userId()).query(UUID.class).single();
    }

    @Override
    public String recordDecision(UUID instanceStageId, Actor actor, String decision, String comment) {
        return jdbc.sql("SELECT wf.record_stage_decision(:stage, :actor, :decision, :comment)")
                .param("stage", instanceStageId).param("actor", actor.userId()).param("decision", decision).param("comment", comment)
                .query(String.class).single();
    }

    @Override
    public void claim(UUID instanceStageId, Actor actor) {
        jdbc.sql("SELECT wf.claim_stage(:stage, :actor)").param("stage", instanceStageId).param("actor", actor.userId())
                .query((rs, i) -> 0).single();
    }

    @Override
    public void unclaim(UUID instanceStageId, Actor actor) {
        jdbc.sql("SELECT wf.unclaim_stage(:stage, :actor)").param("stage", instanceStageId).param("actor", actor.userId())
                .query((rs, i) -> 0).single();
    }

    @Override
    public UUID addEnrichmentItem(UUID instanceStageId, Actor actor, String action, UUID hierarchyId, UUID nodeId,
                                  UUID targetParentId, UUID propertyId, JsonNode payload) {
        return jdbc.sql("""
                SELECT wf_bridge.add_enrichment_item(:stage, :actor, CAST(:action AS mdm.change_action), :h, :n, :t, :p,
                                                     CAST(:payload AS jsonb))
                """)
                .param("stage", instanceStageId).param("actor", actor.userId()).param("action", action).param("h", hierarchyId)
                .param("n", nodeId).param("t", targetParentId).param("p", propertyId)
                .param("payload", payload == null ? "{}" : payload.toString())
                .query(UUID.class).single();
    }

    @Override
    public void withdraw(UUID instanceId, Actor actor) {
        jdbc.sql("SELECT wf.close_instance(:i, 'withdrawn', :actor, NULL)").param("i", instanceId).param("actor", actor.userId())
                .query((rs, i) -> 0).single();
    }

    @Override
    public Optional<UUID> openRootInstance(UUID changeRequestId) {
        return jdbc.sql("""
                SELECT instance_id FROM wf.workflow_instance
                WHERE change_request_id = :cr AND parent_instance_id IS NULL AND status IN ('draft', 'in_flight', 'pushed_back')
                """).param("cr", changeRequestId).query(UUID.class).optional();
    }

    @Override
    public Optional<Refusal> whyCannotAct(UUID instanceStageId, Actor actor) {
        return jdbc.sql("SELECT code, message FROM wf.why_cannot_act(:stage, :actor)")
                .param("stage", instanceStageId).param("actor", actor.userId())
                .query((rs, i) -> new Refusal(rs.getString("code"), rs.getString("message"))).optional();
    }
}
