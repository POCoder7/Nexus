package com.mdm.api.version;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.PostgresIntegrationTest;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.ResultActions;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.endsWith;
import static org.hamcrest.Matchers.everyItem;
import static org.hamcrest.Matchers.hasItem;
import static org.hamcrest.Matchers.is;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * VER-01 and VER-02 through the API, as the least-privileged API login (Phase 3 LLD V.5, V.7). The database guard is
 * tested in {@code db/tests/22_versions.sql}; this class checks what the API adds (paging, ETags, the reasons it gives,
 * the /me preference, moving a draft) and the two pictures the capabilities promise.
 * <p>
 * Every version here is dated in 2025, before any test's "today", so none of them becomes the latest working version
 * that other test classes (and the UI tests) fall back to.
 */
class VersionApiTest extends PostgresIntegrationTest {

    static final UUID TOP = UUID.fromString("00000000-0000-0000-0000-0000000ea501");
    static final UUID REGION = UUID.fromString("00000000-0000-0000-0000-0000000ea502");
    static final UUID ENTITY = UUID.fromString("00000000-0000-0000-0000-0000000ea503");
    static final String ADMIN = "va_admin";
    static final String ADMIN2 = "va_admin2";
    static final String STEWARD = "va_steward";
    static final String APPROVER = "va_approver";
    static final String VIEWER = "va_viewer";
    static final String NOBODY = "va_nobody";

    @Autowired
    MockMvc mvc;
    @Autowired
    ObjectMapper mapper;

    @BeforeEach
    void seed() {
        JdbcClient jdbc = ownerJdbc();
        if (jdbc.sql("SELECT count(*) FROM mdm.hierarchy WHERE hierarchy_code = 'VA_H'").query(Integer.class).single() == 0) {
            jdbc.sql("INSERT INTO mdm.node (node_id, node_kind) VALUES (:t, 'structural'), (:r, 'structural'), (:e, 'legal_entity')")
                    .param("t", TOP).param("r", REGION).param("e", ENTITY).update();
            jdbc.sql("""
                    INSERT INTO mdm.node_attr (node_id, node_name, allows_children, valid_period)
                    VALUES (:t, 'VA group', true, daterange('2020-01-01', NULL)), (:r, 'VA region', true, daterange('2020-01-01', NULL)),
                           (:e, 'VA entity', false, daterange('2020-01-01', NULL))
                    """).param("t", TOP).param("r", REGION).param("e", ENTITY).update();
            jdbc.sql("INSERT INTO mdm.hierarchy (hierarchy_code, hierarchy_name, top_node_id) VALUES ('VA_H', 'Versions test', :t)")
                    .param("t", TOP).update();
            jdbc.sql("""
                    INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, valid_period)
                    SELECT hierarchy_id, p, c, daterange('2020-01-01', NULL)
                    FROM mdm.hierarchy, (VALUES (CAST(:t AS uuid), CAST(:r AS uuid)), (:r, :e)) AS v(p, c)
                    WHERE hierarchy_code = 'VA_H'
                    """).param("t", TOP).param("r", REGION).param("e", ENTITY).update();
            jdbc.sql("INSERT INTO mdm.property_definition (property_code, label, data_type, scope) VALUES ('VA.Ccy', 'Currency', 'string', 'global')")
                    .update();
            jdbc.sql("""
                    INSERT INTO mdm.property_value (node_id, property_id, value, valid_period)
                    SELECT :e, property_id, '"EUR"', daterange('2020-01-01', NULL) FROM mdm.property_definition WHERE property_code = 'VA.Ccy'
                    """).param("e", ENTITY).update();
        }
        grant(ADMIN, "VERSION_ADMIN", null, null);
        grant(ADMIN2, "VERSION_ADMIN", null, null);
        grant(STEWARD, "STEWARD", "VA_H", null);
        grant(APPROVER, "APPROVER", "VA_H", null);
        grant(VIEWER, "VIEWER", "VA_H", null);
        ensureUser(NOBODY, "human");
    }

    // ------------------------------------------------------------------ create, copy, rename

    @Test
    void createCopyAndRename() throws Exception {
        mvc.perform(post("/api/v1/versions").with(asUser(ADMIN)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"VA created\",\"businessAsOf\":\"2025-03-31\",\"description\":\"Quarter end\"}"))
                .andExpect(status().isCreated())
                .andExpect(header().string("Location", endsWith("/api/v1/versions/VA%20created")))
                .andExpect(header().string("ETag", "\"1\""))
                .andExpect(jsonPath("$.status").value("working"))
                .andExpect(jsonPath("$.businessAsOf").value("2025-03-31"))
                .andExpect(jsonPath("$.recordedAsOf").doesNotExist())
                .andExpect(jsonPath("$.createdBy.displayName").value(ADMIN))
                .andExpect(jsonPath("$.transitions.length()").value(1))
                .andExpect(jsonPath("$.transitions[0].to").value("submitted"))
                .andExpect(jsonPath("$.transitions[0].allowed").value(true))
                .andExpect(jsonPath("$.edit.allowed").value(true))
                .andExpect(jsonPath("$.openRequests.draft").value(0));

        // a copy records its base and, unless told otherwise, takes the base's business date
        mvc.perform(post("/api/v1/versions").with(asUser(ADMIN)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"VA created copy\",\"baseVersion\":\"VA created\"}"))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.baseVersion").value("VA created"))
                .andExpect(jsonPath("$.businessAsOf").value("2025-03-31"));

        createRefused("{\"name\":\"VA created\",\"businessAsOf\":\"2025-03-31\"}", 409);
        createRefused("{\"name\":\"VA unknown base\",\"baseVersion\":\"VA nowhere\"}", 400)
                .andExpect(jsonPath("$.errors[0].field").value("baseVersion"));
        createRefused("{\"name\":\"VA no date\"}", 400).andExpect(jsonPath("$.errors[0].field").value("businessAsOf"));
        createRefused("{\"name\":\"VA a/b\",\"businessAsOf\":\"2025-03-31\"}", 400).andExpect(jsonPath("$.errors[0].field").value("name"));
        createRefused("{\"name\":\"  \",\"businessAsOf\":\"2025-03-31\"}", 400).andExpect(jsonPath("$.errors[0].field").value("name"));
        mvc.perform(post("/api/v1/versions").with(asUser(STEWARD)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"VA by a steward\",\"businessAsOf\":\"2025-03-31\"}"))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.code").value("version.not_admin"));

        // rename and clear the description: If-Match required, stale refused, then one new revision
        mvc.perform(patch("/api/v1/versions/{n}", "VA created").with(asUser(ADMIN)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"VA renamed\"}"))
                .andExpect(status().is(428));
        mvc.perform(patch("/api/v1/versions/{n}", "VA created").with(asUser(ADMIN)).header("If-Match", "\"7\"")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"name\":\"VA renamed\"}"))
                .andExpect(status().isPreconditionFailed())
                .andExpect(header().string("ETag", "\"1\""));
        mvc.perform(patch("/api/v1/versions/{n}", "VA created").with(asUser(ADMIN)).header("If-Match", "\"1\"")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"name\":\"VA renamed\",\"description\":\"\"}"))
                .andExpect(status().isOk())
                .andExpect(header().string("ETag", "\"2\""))
                .andExpect(jsonPath("$.name").value("VA renamed"))
                .andExpect(jsonPath("$.description").doesNotExist());
        mvc.perform(get("/api/v1/versions/{n}", "VA created").with(asUser(VIEWER))).andExpect(status().isNotFound());
        mvc.perform(get("/api/v1/versions/{n}", "VA created copy").with(asUser(VIEWER)))
                .andExpect(jsonPath("$.baseVersion").value("VA renamed"));
        // nothing to change: no write, so the revision stays
        mvc.perform(patch("/api/v1/versions/{n}", "VA renamed").with(asUser(ADMIN)).header("If-Match", "\"2\"")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"name\":\"VA renamed\"}"))
                .andExpect(status().isOk())
                .andExpect(header().string("ETag", "\"2\""));
        mvc.perform(patch("/api/v1/versions/{n}", "VA renamed").with(asUser(STEWARD)).header("If-Match", "\"2\"")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"name\":\"VA stolen\"}"))
                .andExpect(status().isForbidden());
    }

    @Test
    void createIsIdempotentWithAKey() throws Exception {
        String key = "va-key-" + UUID.randomUUID();
        String body = "{\"name\":\"VA once\",\"businessAsOf\":\"2025-02-28\"}";
        mvc.perform(post("/api/v1/versions").with(asUser(ADMIN)).header("Idempotency-Key", key)
                .contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isCreated());
        mvc.perform(post("/api/v1/versions").with(asUser(ADMIN)).header("Idempotency-Key", key)
                        .contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isCreated())
                .andExpect(header().string("Idempotent-Replayed", "true"));
        assertThat(ownerJdbc().sql("SELECT count(*) FROM mdm.version WHERE version_name = 'VA once'").query(Integer.class).single())
                .isEqualTo(1);
    }

    @Test
    void theListIsPagedByBusinessDateThenNameAndNeedsRead() throws Exception {
        create("VA page b", "2001-02-01");
        create("VA page a", "2001-02-01");
        create("VA page c", "2001-01-01");
        List<String> names = new ArrayList<>();
        String cursor = null;
        do {
            var request = get("/api/v1/versions").param("limit", "2").with(asUser(VIEWER));
            if (cursor != null) {
                request = request.param("cursor", cursor);
            }
            JsonNode page = json(mvc.perform(request).andExpect(status().isOk()).andReturn());
            assertThat(page.get("items").size()).isLessThanOrEqualTo(2);
            page.get("items").forEach(v -> names.add(v.get("name").asText()));
            cursor = page.hasNonNull("nextCursor") ? page.get("nextCursor").asText() : null;
        } while (cursor != null);
        assertThat(names).doesNotHaveDuplicates();
        assertThat(names.indexOf("VA page a")).isLessThan(names.indexOf("VA page b"));
        assertThat(names.indexOf("VA page b")).isLessThan(names.indexOf("VA page c"));
        assertThat(names.indexOf("VA page c")).isGreaterThanOrEqualTo(0);

        create("VA page submitted", "2001-03-01");
        transition(ADMIN, "VA page submitted", "submitted").andExpect(status().isOk());
        mvc.perform(get("/api/v1/versions").param("status", "submitted").with(asUser(VIEWER)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items[*].status", everyItem(is("submitted"))))
                .andExpect(jsonPath("$.items[*].name", hasItem("VA page submitted")));
        mvc.perform(get("/api/v1/versions").param("status", "draft").with(asUser(VIEWER))).andExpect(status().isBadRequest());
        mvc.perform(get("/api/v1/versions").param("cursor", "not-a-cursor").with(asUser(VIEWER))).andExpect(status().isBadRequest());
        mvc.perform(get("/api/v1/versions").with(asUser(NOBODY))).andExpect(status().isForbidden());
        mvc.perform(get("/api/v1/versions/{n}", "VA page a").with(asUser(NOBODY))).andExpect(status().isForbidden());
    }

    // ------------------------------------------------------------------ lifecycle

    @Test
    void theLifecycleWithReasonsAndFourEyes() throws Exception {
        create("VA cycle", "2025-04-30");
        mvc.perform(get("/api/v1/versions/{n}", "VA cycle").with(asUser(VIEWER)))
                .andExpect(header().string("ETag", "\"1\""))
                .andExpect(jsonPath("$.transitions[0].allowed").value(false))
                .andExpect(jsonPath("$.transitions[0].whyNot").value("Only a version administrator can submit versions"))
                .andExpect(jsonPath("$.edit.allowed").value(false))
                .andExpect(jsonPath("$.edit.whyNot").value("Only a version administrator can edit versions"));
        transition(VIEWER, "VA cycle", "submitted").andExpect(status().isForbidden()).andExpect(jsonPath("$.code").value("version.not_admin"));

        mvc.perform(post("/api/v1/versions/{n}/transitions", "VA cycle").with(asUser(ADMIN))
                        .contentType(MediaType.APPLICATION_JSON).content("{\"to\":\"submitted\"}"))
                .andExpect(status().is(428));
        mvc.perform(post("/api/v1/versions/{n}/transitions", "VA cycle").with(asUser(ADMIN)).header("If-Match", "\"5\"")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"to\":\"submitted\"}"))
                .andExpect(status().isPreconditionFailed());
        mvc.perform(post("/api/v1/versions/{n}/transitions", "VA cycle").with(asUser(ADMIN)).header("If-Match", "\"1\"")
                        .contentType(MediaType.APPLICATION_JSON).content("{}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.errors[0].field").value("to"));

        JsonNode submitted = json(mvc.perform(post("/api/v1/versions/{n}/transitions", "VA cycle").with(asUser(ADMIN))
                        .header("If-Match", "\"1\"").contentType(MediaType.APPLICATION_JSON)
                        .content("{\"to\":\"submitted\",\"reason\":\"Month end\"}"))
                .andExpect(status().isOk())
                .andExpect(header().string("ETag", "\"2\""))
                .andExpect(jsonPath("$.status").value("submitted"))
                .andExpect(jsonPath("$.recordedAsOf").exists())
                .andExpect(jsonPath("$.submittedBy.displayName").value(ADMIN))
                .andExpect(jsonPath("$.transitions[0].to").value("working"))
                .andExpect(jsonPath("$.transitions[0].allowed").value(true))
                .andExpect(jsonPath("$.transitions[1].to").value("finalized"))
                .andExpect(jsonPath("$.transitions[1].allowed").value(false))
                .andExpect(jsonPath("$.transitions[1].whyNot").value("You submitted this version; another version administrator must finalize it"))
                .andReturn());
        String pin = submitted.get("recordedAsOf").asText();

        // four eyes: the submitter is refused by the database, the second administrator may finalize
        transition(ADMIN, "VA cycle", "finalized").andExpect(status().isForbidden()).andExpect(jsonPath("$.code").value("version.self_finalize"));
        mvc.perform(get("/api/v1/versions/{n}", "VA cycle").with(asUser(ADMIN2)))
                .andExpect(jsonPath("$.transitions[1].allowed").value(true));
        transition(ADMIN2, "VA cycle", "finalized")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("finalized"))
                .andExpect(jsonPath("$.finalizedBy.displayName").value(ADMIN2))
                .andExpect(jsonPath("$.recordedAsOf").value(pin))
                .andExpect(jsonPath("$.edit.allowed").value(false))
                .andExpect(jsonPath("$.edit.whyNot").value("A finalized version can only be expired"));

        mvc.perform(patch("/api/v1/versions/{n}", "VA cycle").with(asUser(ADMIN)).header("If-Match", etag("VA cycle"))
                        .contentType(MediaType.APPLICATION_JSON).content("{\"description\":\"Too late\"}"))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("version.frozen"));
        transition(ADMIN, "VA cycle", "working").andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("version.status_transition"));

        transition(ADMIN, "VA cycle", "expired")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("expired"))
                .andExpect(jsonPath("$.transitions.length()").value(0))
                .andExpect(jsonPath("$.edit.whyNot").value("An expired version cannot be changed"));

        List<String> log = ownerJdbc().sql("""
                SELECT t.from_status || '>' || t.to_status || ':' || coalesce(t.reason, '')
                FROM mdm.version_transition t JOIN mdm.version v USING (version_id)
                WHERE v.version_name = 'VA cycle' ORDER BY t.recorded_at
                """).query(String.class).list();
        assertThat(log).containsExactly("working>submitted:Month end", "submitted>finalized:", "finalized>expired:");
    }

    @Test
    void reopeningClearsThePin() throws Exception {
        create("VA reopen", "2025-05-15");
        transition(ADMIN, "VA reopen", "submitted").andExpect(status().isOk());
        transition(ADMIN, "VA reopen", "working")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("working"))
                .andExpect(jsonPath("$.recordedAsOf").doesNotExist())
                .andExpect(jsonPath("$.submittedBy").doesNotExist())
                .andExpect(jsonPath("$.edit.allowed").value(true));
    }

    @Test
    void submitIsRefusedWhileRequestsAreInFlightAndADraftCanMove() throws Exception {
        create("VA busy", "2025-05-31");
        create("VA busy next", "2025-04-30");
        String inFlight = request("VA busy", "VA in flight", "2025-05-01");
        addItem(inFlight, "{\"action\":\"update_node\",\"hierarchyCode\":\"VA_H\",\"nodeId\":\"" + REGION
                + "\",\"payload\":{\"description\":\"Reviewed in May\"}}");
        submitRequest(inFlight).andExpect(status().isOk()).andExpect(jsonPath("$.status").value("submitted"));
        String draft = request("VA busy", "VA left as draft", "2025-05-01");
        addItem(draft, "{\"action\":\"update_node\",\"hierarchyCode\":\"VA_H\",\"nodeId\":\"" + ENTITY
                + "\",\"payload\":{\"description\":\"Drafted in May\"}}");

        String reason = "1 request in this version is still in flight (1 submitted)";
        mvc.perform(get("/api/v1/versions/{n}", "VA busy").with(asUser(ADMIN)))
                .andExpect(jsonPath("$.openRequests.draft").value(1))
                .andExpect(jsonPath("$.openRequests.submitted").value(1))
                .andExpect(jsonPath("$.transitions[0].allowed").value(false))
                .andExpect(jsonPath("$.transitions[0].whyNot").value(reason));
        mvc.perform(get("/api/v1/versions").param("status", "working").param("limit", "200").with(asUser(ADMIN)))
                .andExpect(jsonPath("$.items[?(@.name == 'VA busy')].transitions[0].whyNot").value(reason));
        transition(ADMIN, "VA busy", "submitted")
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("version.requests_open"))
                .andExpect(jsonPath("$.detail").value(reason));

        // once the request is decided and applied, only the draft is left, and drafts do not block a submit
        decide(inFlight).andExpect(jsonPath("$.status").value("applied"));
        mvc.perform(get("/api/v1/versions/{n}", "VA busy").with(asUser(ADMIN))).andExpect(jsonPath("$.transitions[0].allowed").value(true));
        transition(ADMIN, "VA busy", "submitted").andExpect(status().isOk());

        // VER-02: nothing new is raised in, or advanced in, a submitted version
        submitRequest(draft).andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.code").value("version.not_working"));
        mvc.perform(post("/api/v1/change-requests").with(asUser(STEWARD)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"versionName\":\"VA busy\",\"title\":\"VA too late\"}"))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("version.not_working"));

        // the requester moves the draft to a working version (R1); a non-working or unknown target is refused
        moveDraft(draft, "VA busy").andExpect(jsonPath("$.versionName").value("VA busy"));   // same version: no move
        create("VA busy closed", "2025-04-15");
        transition(ADMIN, "VA busy closed", "submitted").andExpect(status().isOk());
        moveDraft(draft, "VA busy closed").andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.code").value("version.not_working"));
        moveDraft(draft, "VA nowhere").andExpect(status().isBadRequest()).andExpect(jsonPath("$.errors[0].field").value("versionName"));
        moveDraft(draft, "VA busy next").andExpect(status().isOk()).andExpect(jsonPath("$.versionName").value("VA busy next"));
        moveDraft(inFlight, "VA busy next").andExpect(status().isUnprocessableEntity());   // not a draft

        // the moved draft now takes effect after its version's date: a warning, not an error
        mvc.perform(post("/api/v1/change-requests/{id}/validate", draft).with(asUser(STEWARD)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.errors.length()").value(0))
                .andExpect(jsonPath("$.warnings[?(@.ruleCode == 'NEXUS.VERSION_DATE')].message").value(
                        "This change takes effect on 1 May 2025, after version VA busy next's date (30 Apr 2025), so it will not show in that version"));
        submitRequest(draft).andExpect(status().isOk()).andExpect(jsonPath("$.status").value("submitted"));
    }

    // ------------------------------------------------------------------ the pictures (VER-01, VER-02)

    @Test
    void aCopyShowsItsBasesPictureAtCreation() throws Exception {
        create("VA base", "2025-06-30");
        String pin = json(transition(ADMIN, "VA base", "submitted").andExpect(status().isOk()).andReturn()).get("recordedAsOf").asText();
        mvc.perform(post("/api/v1/versions").with(asUser(ADMIN)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"VA base copy\",\"baseVersion\":\"VA base\"}"))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.businessAsOf").value("2025-06-30"));

        // the base is read at its pin, the working copy as recorded now: the same picture
        assertThat(children("2025-06-30", null)).isEqualTo(children("2025-06-30", pin));
        assertThat(children("2025-06-30", null).size()).isEqualTo(1);
        for (UUID node : List.of(TOP, REGION, ENTITY)) {
            assertThat(node(node, "2025-06-30", null)).as(node.toString()).isEqualTo(node(node, "2025-06-30", pin));
        }
    }

    @Test
    void aCorrectionAppliedAfterFinalizeLeavesTheFinalizedPictureUnchanged() throws Exception {
        create("VA fixed", "2025-06-30");
        transition(ADMIN, "VA fixed", "submitted").andExpect(status().isOk());
        String pin = json(transition(ADMIN2, "VA fixed", "finalized").andExpect(status().isOk()).andReturn()).get("recordedAsOf").asText();
        String currencyBefore = currency(node(ENTITY, "2025-06-30", pin));

        // a back-dated correction, raised and applied in another working version after the freeze
        create("VA later", "2025-07-31");
        String fix = request("VA later", "VA currency correction", "2025-01-01");
        addItem(fix, "{\"action\":\"set_property\",\"hierarchyCode\":\"VA_H\",\"nodeId\":\"" + ENTITY
                + "\",\"propertyCode\":\"VA.Ccy\",\"payload\":{\"value\":\"VA-GBP\"}}");
        submitRequest(fix).andExpect(status().isOk());
        decide(fix).andExpect(jsonPath("$.status").value("applied"));

        assertThat(currency(node(ENTITY, "2025-06-30", null))).isEqualTo("VA-GBP");          // as recorded now
        assertThat(currency(node(ENTITY, "2025-06-30", pin))).isEqualTo(currencyBefore)      // the finalized picture
                .isNotEqualTo("VA-GBP");
    }

    // ------------------------------------------------------------------ the working version on /me

    @Test
    void theWorkingVersionPreferenceAndItsFallback() throws Exception {
        create("VA pref fallback", "2025-01-31");
        create("VA pref", "2025-08-31");
        String user = "va_pref_user";
        grant(user, "VIEWER", "VA_H", null);

        mvc.perform(get("/api/v1/me").with(asUser(user))).andExpect(jsonPath("$.workingVersion").value(latestWorking()));
        mvc.perform(put("/api/v1/me/preferences").with(asUser(user)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"workingVersion\":\"VA pref\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.workingVersion").value("VA pref"));
        mvc.perform(get("/api/v1/me").with(asUser(user)))
                .andExpect(jsonPath("$.workingVersion").value("VA pref"))
                .andExpect(jsonPath("$.preferences.workingVersion").value("VA pref"));
        // a partial update keeps the chosen version
        mvc.perform(put("/api/v1/me/preferences").with(asUser(user)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"density\":\"comfortable\"}"))
                .andExpect(jsonPath("$.workingVersion").value("VA pref"));
        mvc.perform(put("/api/v1/me/preferences").with(asUser(user)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"workingVersion\":\"VA nowhere\"}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.errors[0].field").value("workingVersion"));

        // once the chosen version is submitted, /me falls back to the latest working version, and it cannot be chosen
        transition(ADMIN, "VA pref", "submitted").andExpect(status().isOk());
        mvc.perform(get("/api/v1/me").with(asUser(user)))
                .andExpect(jsonPath("$.workingVersion").value(latestWorking()))
                .andExpect(jsonPath("$.preferences.workingVersion").doesNotExist());
        assertThat(latestWorking()).isNotEqualTo("VA pref");
        mvc.perform(put("/api/v1/me/preferences").with(asUser(user)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"workingVersion\":\"VA pref\"}"))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("version.not_working"));
    }

    @Test
    void versionAdministratorsAreListedInTheirPermissions() throws Exception {
        mvc.perform(get("/api/v1/me").with(asUser(ADMIN)))
                .andExpect(jsonPath("$.permissions['*'][*]", hasItem("ADMIN_VERSION")));
    }

    // ------------------------------------------------------------------ helpers

    private void create(String name, String businessAsOf) throws Exception {
        mvc.perform(post("/api/v1/versions").with(asUser(ADMIN)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"" + name + "\",\"businessAsOf\":\"" + businessAsOf + "\"}"))
                .andExpect(status().isCreated());
    }

    private ResultActions createRefused(String body, int status) throws Exception {
        return mvc.perform(post("/api/v1/versions").with(asUser(ADMIN)).contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().is(status));
    }

    private ResultActions transition(String login, String name, String to) throws Exception {
        return mvc.perform(post("/api/v1/versions/{n}/transitions", name).with(asUser(login)).header("If-Match", etag(name))
                .contentType(MediaType.APPLICATION_JSON).content("{\"to\":\"" + to + "\"}"));
    }

    private String etag(String name) throws Exception {
        return mvc.perform(get("/api/v1/versions/{n}", name).with(asUser(VIEWER))).andExpect(status().isOk())
                .andReturn().getResponse().getHeader("ETag");
    }

    private String request(String version, String title, String effectiveFrom) throws Exception {
        MvcResult r = mvc.perform(post("/api/v1/change-requests").with(asUser(STEWARD)).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"versionName\":\"" + version + "\",\"title\":\"" + title + "\",\"effectiveFrom\":\"" + effectiveFrom + "\"}"))
                .andExpect(status().isCreated()).andReturn();
        return json(r).get("id").asText();
    }

    private void addItem(String id, String body) throws Exception {
        mvc.perform(post("/api/v1/change-requests/{id}/items", id).with(asUser(STEWARD)).header("If-Match", requestEtag(id))
                .contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isCreated());
    }

    private ResultActions submitRequest(String id) throws Exception {
        return mvc.perform(post("/api/v1/change-requests/{id}/submit", id).with(asUser(STEWARD)).header("If-Match", requestEtag(id)));
    }

    private ResultActions decide(String id) throws Exception {
        return mvc.perform(post("/api/v1/change-requests/{id}/decision", id).with(asUser(APPROVER)).header("If-Match", requestEtag(id))
                        .contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"approve\",\"note\":\"VA test\"}"))
                .andExpect(status().isOk());
    }

    private ResultActions moveDraft(String id, String version) throws Exception {
        return mvc.perform(patch("/api/v1/change-requests/{id}", id).with(asUser(STEWARD)).header("If-Match", requestEtag(id))
                .contentType(MediaType.APPLICATION_JSON).content("{\"versionName\":\"" + version + "\"}"));
    }

    private String requestEtag(String id) throws Exception {
        return mvc.perform(get("/api/v1/change-requests/{id}", id).with(asUser(STEWARD))).andReturn().getResponse().getHeader("ETag");
    }

    private JsonNode children(String asOf, String recordedAsOf) throws Exception {
        var request = get("/api/v1/hierarchies/VA_H/children").param("parentId", TOP.toString()).param("asOf", asOf).with(asUser(VIEWER));
        if (recordedAsOf != null) {
            request = request.param("recordedAsOf", recordedAsOf);
        }
        return json(mvc.perform(request).andExpect(status().isOk()).andReturn()).get("items");
    }

    private JsonNode node(UUID id, String asOf, String recordedAsOf) throws Exception {
        var request = get("/api/v1/nodes/{id}", id).param("hierarchy", "VA_H").param("asOf", asOf).with(asUser(VIEWER));
        if (recordedAsOf != null) {
            request = request.param("recordedAsOf", recordedAsOf);
        }
        return json(mvc.perform(request).andExpect(status().isOk()).andReturn());
    }

    private static String currency(JsonNode node) {
        for (JsonNode p : node.get("properties")) {
            if ("VA.Ccy".equals(p.get("code").asText())) {
                return p.get("value").asText();
            }
        }
        return null;
    }

    /** /me's fallback rule, read directly: the latest working version by business date, then name. */
    private static String latestWorking() {
        return ownerJdbc().sql("SELECT version_name FROM mdm.version WHERE status = 'working' ORDER BY business_as_of DESC, version_name LIMIT 1")
                .query(String.class).single();
    }

    private JsonNode json(MvcResult r) throws Exception {
        return mapper.readTree(r.getResponse().getContentAsString());
    }
}
