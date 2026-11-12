package com.mdm.api.workflow.admin;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.common.ItemValidationException;
import com.mdm.api.security.Actor;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.io.IOException;
import java.io.InputStream;
import java.util.UUID;

/**
 * GOV-01: workflow models are loaded from definition files (JSON) as new draft versions and activated by a second
 * workflow administrator (Phase 2 LLD §3.1, §4.11). The database does the work and the checks ({@code wf.load_model},
 * {@code wf.activate_model}, {@code wf.trg_model_status}); this class only reads the file and checks its outline, so
 * a malformed file gets a clear 400 before anything is written.
 *
 * <p>Definition outline: {@code {code, label, description?, requestDuration?, tasks: [{code, label, allowedActions,
 * properties: [{code, required?, readOnly?}]}], submitTasks: [code], stages: [{seq, type, label, task?, groups: [code],
 * approvalMethod?, separationOfDuties?, claimDuration?, stageDuration?, condition?, scopes: [{hierarchy, topNode}]}]}}.
 */
@Service
public class ModelDefinitionLoader {

    private final JdbcClient jdbc;
    private final ObjectMapper mapper;

    public ModelDefinitionLoader(JdbcClient jdbc, ObjectMapper mapper) {
        this.jdbc = jdbc;
        this.mapper = mapper;
    }

    /** Loads a definition as the next draft version of its model; returns the new model id. */
    @Transactional
    public UUID load(InputStream definition, Actor actor) {
        JsonNode json;
        try {
            json = mapper.readTree(definition);
        } catch (IOException e) {
            throw ItemValidationException.field("definition", "is not valid JSON");
        }
        return load(json, actor);
    }

    @Transactional
    public UUID load(JsonNode definition, Actor actor) {
        requireText(definition, "code");
        requireText(definition, "label");
        JsonNode stages = definition.path("stages");
        if (!stages.isArray() || stages.isEmpty()) {
            throw ItemValidationException.field("definition.stages", "needs at least one stage");
        }
        for (JsonNode stage : stages) {
            if (!stage.path("seq").isInt() || !stage.hasNonNull("type") || !stage.hasNonNull("label")) {
                throw ItemValidationException.field("definition.stages", "every stage needs seq, type and label");
            }
        }
        return jdbc.sql("SELECT wf.load_model(CAST(:definition AS jsonb), :actor)")
                .param("definition", definition.toString()).param("actor", actor.userId())
                .query(UUID.class).single();
    }

    /** Activates a draft version; the database refuses the creator (N1014) and invalid models (N2206). */
    @Transactional
    public void activate(UUID modelId, Actor actor) {
        jdbc.sql("SELECT wf.activate_model(:model, :actor)").param("model", modelId).param("actor", actor.userId())
                .query((rs, i) -> 0).single();
    }

    private static void requireText(JsonNode definition, String field) {
        if (!definition.path(field).isTextual() || definition.path(field).asText().isBlank()) {
            throw ItemValidationException.field("definition." + field, "is required");
        }
    }
}
