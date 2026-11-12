package com.mdm.api.workflow;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.PostgresIntegrationTest;
import com.mdm.api.common.ItemValidationException;
import com.mdm.api.security.Actor;
import com.mdm.api.workflow.admin.ModelDefinitionLoader;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.dao.DataAccessException;

import java.io.InputStream;
import java.sql.SQLException;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** GOV-01 (Phase 2 increment 2-7): a definition file becomes a draft version; a second administrator activates it. */
class ModelDefinitionLoaderTest extends PostgresIntegrationTest {

    @Autowired
    ModelDefinitionLoader loader;
    @Autowired
    ObjectMapper mapper;

    Actor admin1;
    Actor admin2;

    @BeforeEach
    void seed() {
        UUID a1 = ensureUser("ml_admin1", "human");
        UUID a2 = ensureUser("ml_admin2", "human");
        grant("ml_admin1", "WORKFLOW_ADMIN", null, null);
        grant("ml_admin2", "WORKFLOW_ADMIN", null, null);
        admin1 = new Actor(a1, "ml_admin1", "ml_admin1", "human");
        admin2 = new Actor(a2, "ml_admin2", "ml_admin2", "human");
        ownerJdbc().sql("""
                INSERT INTO wf.user_group (group_code, name) VALUES ('T_APPROVERS', 'Approvers'), ('T_COMMITTERS', 'Committers')
                ON CONFLICT (group_code) DO NOTHING
                """).update();
    }

    @Test
    void aDefinitionFileBecomesADraftThatASecondAdministratorActivates() throws Exception {
        UUID model;
        try (InputStream in = getClass().getResourceAsStream("/workflow/t_add_leaf.json")) {
            model = loader.load(in, admin1);
        }
        assertThat(status(model)).isEqualTo("draft");
        assertThatThrownBy(() -> loader.activate(model, admin1))
                .isInstanceOf(DataAccessException.class)
                .satisfies(e -> assertThat(sqlState(e)).isEqualTo("N1014"));
        loader.activate(model, admin2);
        assertThat(status(model)).isEqualTo("active");
        assertThat(ownerJdbc().sql("SELECT count(*) FROM wf.workflow_stage WHERE model_id = :m").param("m", model)
                .query(Integer.class).single()).isEqualTo(3);
    }

    @Test
    void aMalformedDefinitionIsRefusedBeforeAnythingIsWritten() throws Exception {
        assertThatThrownBy(() -> loader.load(mapper.readTree("{\"code\": \"T_BAD\", \"label\": \"Bad\", \"stages\": []}"), admin1))
                .isInstanceOf(ItemValidationException.class);
        assertThatThrownBy(() -> loader.load(new java.io.ByteArrayInputStream("not json".getBytes()), admin1))
                .isInstanceOf(ItemValidationException.class);
        assertThat(ownerJdbc().sql("SELECT count(*) FROM wf.workflow_model WHERE model_code = 'T_BAD'")
                .query(Integer.class).single()).isZero();
    }

    private String status(UUID model) {
        return ownerJdbc().sql("SELECT status FROM wf.workflow_model WHERE model_id = :m").param("m", model).query(String.class).single();
    }

    private static String sqlState(Throwable e) {
        Throwable c = e;
        while (c != null && !(c instanceof SQLException)) {
            c = c.getCause();
        }
        return c == null ? null : ((SQLException) c).getSQLState();
    }
}
