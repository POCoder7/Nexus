package com.mdm.api.workflow;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.common.NotFoundException;
import com.mdm.api.hierarchy.HierarchyRepository;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import com.mdm.api.security.ForbiddenException;
import com.mdm.api.security.Permission;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Arrays;
import java.util.List;
import java.util.UUID;

/**
 * The properties a model's submit task lets the requester set, with required flags (Phase 3 LLD §5.1; GOV-03
 * infrastructure). The add-leaf form is built from this. The server still validates on submit: a required flag here
 * helps the user, it does not enforce anything.
 */
@RestController
@RequestMapping("/api/v1/workflow/models")
public class SubmitFormController {

    public record FormProperty(String code, String label, String dataType, String scope, String category, boolean required,
                               boolean readOnly, Integer maxLength, JsonNode defaultValue, List<String> listValues) {
    }

    public record SubmitForm(String modelCode, int modelVersion, String label, List<String> allowedActions,
                             List<FormProperty> properties) {
    }

    private final JdbcClient jdbc;
    private final ObjectMapper mapper;
    private final EntitlementService entitlements;
    private final HierarchyRepository hierarchies;

    public SubmitFormController(JdbcClient jdbc, ObjectMapper mapper, EntitlementService entitlements, HierarchyRepository hierarchies) {
        this.jdbc = jdbc;
        this.mapper = mapper;
        this.entitlements = entitlements;
        this.hierarchies = hierarchies;
    }

    /**
     * {@code hierarchy} (optional) is the hierarchy the form is for; the caller must be able to read it (local properties
     * are set per hierarchy by the item, so the same list applies).
     * Only the active version of the model is described: that is the one a submit would start.
     */
    @GetMapping("/{code}/submit-form")
    public SubmitForm getSubmitForm(Actor actor, @PathVariable String code, @RequestParam(required = false) String hierarchy) {
        if (!entitlements.hasAny(actor, Permission.PROPOSE)) {
            throw new ForbiddenException("entitlement.missing",
                    "You don't have the propose changes permission. Ask an administrator for a steward role.");
        }
        if (hierarchy != null) {
            hierarchies.findIdByCode(hierarchy).filter(id -> entitlements.canRead(actor, id))
                    .orElseThrow(() -> new NotFoundException("Hierarchy " + hierarchy + " not found"));
        }
        record Model(UUID id, int version, String label) {
        }
        Model model = jdbc.sql("SELECT model_id, model_version, label FROM wf.workflow_model WHERE model_code = :c AND status = 'active'")
                .param("c", code)
                .query((rs, i) -> new Model(rs.getObject("model_id", UUID.class), rs.getInt("model_version"), rs.getString("label")))
                .optional()
                .orElseThrow(() -> new NotFoundException("No active workflow model " + code));

        List<String> actions = jdbc.sql("""
                SELECT DISTINCT unnest(t.allowed_actions)::text AS action
                FROM wf.submit_task st JOIN wf.workflow_task t ON t.task_id = st.task_id
                WHERE st.model_id = :m AND t.is_active
                ORDER BY 1
                """).param("m", model.id()).query(String.class).list();

        // A property on several submit tasks is required if any task requires it, read-only only if every task says so.
        List<FormProperty> properties = jdbc.sql("""
                SELECT pd.property_code, pd.label, pd.data_type::text AS data_type, pd.scope::text AS scope, pd.category_code,
                       bool_or(tp.is_required) AS required, bool_and(tp.is_read_only) AS read_only, pd.max_length,
                       pd.default_value::text AS default_value, min(tp.sort_seq) AS sort_seq,
                       (SELECT array_agg(lv.list_value ORDER BY lv.list_value) FROM mdm.property_list_value lv
                        WHERE lv.property_id = pd.property_id AND lv.is_active) AS list_values
                FROM wf.submit_task st
                JOIN wf.workflow_task t ON t.task_id = st.task_id AND t.is_active
                JOIN wf.task_property tp ON tp.task_id = t.task_id
                JOIN mdm.property_definition pd ON pd.property_id = tp.property_id
                WHERE st.model_id = :m AND pd.origin = 'stored'
                GROUP BY pd.property_id
                ORDER BY min(tp.sort_seq) NULLS LAST, pd.property_code
                """).param("m", model.id())
                .query((rs, i) -> {
                    java.sql.Array lv = rs.getArray("list_values");
                    String dv = rs.getString("default_value");
                    Integer maxLength = rs.getObject("max_length", Integer.class);
                    return new FormProperty(rs.getString("property_code"), rs.getString("label"), rs.getString("data_type"),
                            rs.getString("scope"), rs.getString("category_code"), rs.getBoolean("required"),
                            rs.getBoolean("read_only"), maxLength, readJson(dv),
                            lv == null ? null : Arrays.asList((String[]) lv.getArray()));
                })
                .list();
        return new SubmitForm(code, model.version(), model.label(), actions, properties);
    }

    private JsonNode readJson(String s) {
        try {
            return s == null ? null : mapper.readTree(s);
        } catch (java.io.IOException e) {
            throw new IllegalStateException("Invalid default value JSON", e);
        }
    }
}
