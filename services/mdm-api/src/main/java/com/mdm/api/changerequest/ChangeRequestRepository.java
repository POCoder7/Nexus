package com.mdm.api.changerequest;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mdm.api.changerequest.ChangeRequestDtos.ChangeRequestView;
import com.mdm.api.changerequest.ChangeRequestDtos.ItemView;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/** SQL for change requests and items. Writes are drafts only; status changes go through mdm functions (ADR-019). */
@Repository
public class ChangeRequestRepository {

    private static final String SELECT_REQUEST = """
            SELECT cr.change_request_id, v.version_name, cr.title, cr.rationale, cr.status::text AS status,
                   cr.requester_id, cr.requester_kind::text AS requester_kind, cr.risk_tier::text AS risk_tier,
                   cr.effective_from, cr.origin, cr.created_at, cr.submitted_at, cr.decided_by, cr.decided_at,
                   cr.decision_note, cr.decision_basis::text AS decision_basis, cr.applied_at, cr.apply_error,
                   (SELECT count(*) FROM mdm.change_item ci WHERE ci.change_request_id = cr.change_request_id) AS item_count,
                   cr.row_version, cr.workflow_model_code, cr.is_urgent, cr.governed_by_workflow
            FROM mdm.change_request cr
            JOIN mdm.version v ON v.version_id = cr.version_id
            """;

    private final JdbcClient jdbc;
    private final ObjectMapper mapper;
    private final RowMapper<ChangeRequestView> requestMapper;
    private final RowMapper<ItemView> itemMapper;

    public ChangeRequestRepository(JdbcClient jdbc, ObjectMapper mapper) {
        this.jdbc = jdbc;
        this.mapper = mapper;
        this.requestMapper = (rs, i) -> new ChangeRequestView(
                rs.getObject("change_request_id", UUID.class), rs.getString("version_name"), rs.getString("title"),
                rs.getString("rationale"), rs.getString("status"), rs.getObject("requester_id", UUID.class),
                rs.getString("requester_kind"), rs.getString("risk_tier"), rs.getObject("effective_from", LocalDate.class),
                rs.getString("origin"), instant(rs.getTimestamp("created_at")), instant(rs.getTimestamp("submitted_at")),
                rs.getObject("decided_by", UUID.class), instant(rs.getTimestamp("decided_at")), rs.getString("decision_note"),
                rs.getString("decision_basis"), instant(rs.getTimestamp("applied_at")), rs.getString("apply_error"),
                rs.getInt("item_count"), rs.getInt("row_version"), rs.getString("workflow_model_code"),
                rs.getBoolean("is_urgent"), rs.getBoolean("governed_by_workflow"));
        this.itemMapper = (rs, i) -> new ItemView(
                rs.getObject("change_item_id", UUID.class), rs.getInt("seq"), rs.getString("action"),
                rs.getString("hierarchy_code"), rs.getObject("node_id", UUID.class),
                rs.getObject("target_parent_id", UUID.class), rs.getString("property_code"),
                json(rs.getString("payload")), instant(rs.getTimestamp("created_at")));
    }

    private static Instant instant(Timestamp t) {
        return t == null ? null : t.toInstant();
    }

    private JsonNode json(String s) {
        try {
            return s == null ? null : mapper.readTree(s);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Invalid JSON in change_item.payload", e);
        }
    }

    public Optional<UUID> versionId(String versionName) {
        return jdbc.sql("SELECT version_id FROM mdm.version WHERE version_name = :name").param("name", versionName)
                .query(UUID.class).optional();
    }

    public UUID insert(UUID versionId, String title, String rationale, String riskTier, UUID requesterId,
                       String requesterKind, LocalDate effectiveFrom, String workflowModelCode, boolean urgent) {
        return jdbc.sql("""
                INSERT INTO mdm.change_request (version_id, title, rationale, risk_tier, requester_id, requester_kind,
                                                effective_from, origin, workflow_model_code, is_urgent)
                VALUES (:version, :title, :rationale, CAST(:risk AS mdm.risk_tier), :requester,
                        CAST(:kind AS mdm.requester_kind), :from, 'user', :model, :urgent)
                RETURNING change_request_id
                """)
                .param("version", versionId).param("title", title).param("rationale", rationale).param("risk", riskTier)
                .param("requester", requesterId).param("kind", requesterKind).param("from", effectiveFrom)
                .param("model", workflowModelCode).param("urgent", urgent)
                .query(UUID.class).single();
    }

    /** An active workflow model with this code exists (wf is readable by the API; it never writes it). */
    public boolean activeModelExists(String modelCode) {
        return jdbc.sql("SELECT EXISTS (SELECT 1 FROM wf.workflow_model WHERE model_code = :c AND status = 'active')")
                .param("c", modelCode).query(Boolean.class).single();
    }

    /** Any item of the request is in a hierarchy that requires a workflow (Phase 2 B-3). */
    public boolean requiresWorkflow(UUID requestId) {
        return jdbc.sql("""
                SELECT EXISTS (SELECT 1 FROM mdm.change_item ci JOIN mdm.hierarchy h ON h.hierarchy_id = ci.hierarchy_id
                               WHERE ci.change_request_id = :cr AND h.requires_workflow)
                """).param("cr", requestId).query(Boolean.class).single();
    }

    public UUID startInstance(UUID requestId, String modelCode, UUID submitter) {
        return jdbc.sql("SELECT wf.start_instance(:cr, :model, :actor)")
                .param("cr", requestId).param("model", modelCode).param("actor", submitter).query(UUID.class).single();
    }

    /** The open root workflow instance of a governed request, if any. */
    public Optional<UUID> openRootInstance(UUID requestId) {
        return jdbc.sql("""
                SELECT instance_id FROM wf.workflow_instance
                WHERE change_request_id = :cr AND parent_instance_id IS NULL AND status IN ('draft', 'in_flight', 'pushed_back')
                """).param("cr", requestId).query(UUID.class).optional();
    }

    public void closeInstanceWithdrawn(UUID instanceId, UUID actor) {
        jdbc.sql("SELECT wf.close_instance(:i, 'withdrawn', :actor, NULL)").param("i", instanceId).param("actor", actor)
                .query((rs, i) -> 0).single();
    }

    public Optional<ChangeRequestView> find(UUID id) {
        return jdbc.sql(SELECT_REQUEST + " WHERE cr.change_request_id = :id").param("id", id).query(requestMapper).optional();
    }

    /** Locks the request row for the rest of the transaction (serialises edits; the ETag is checked under the lock). */
    public Optional<ChangeRequestView> lock(UUID id) {
        return jdbc.sql(SELECT_REQUEST + " WHERE cr.change_request_id = :id FOR UPDATE OF cr").param("id", id)
                .query(requestMapper).optional();
    }

    public List<ChangeRequestView> mine(UUID requester, String status, Instant afterCreated, UUID afterId, int limit) {
        return jdbc.sql(SELECT_REQUEST + """
                WHERE cr.requester_id = :requester
                  AND (CAST(:status AS text) IS NULL OR cr.status::text = :status)
                  AND (CAST(:afterCreated AS timestamptz) IS NULL
                       OR (cr.created_at, cr.change_request_id) < (CAST(:afterCreated AS timestamptz), CAST(:afterId AS uuid)))
                ORDER BY cr.created_at DESC, cr.change_request_id DESC
                LIMIT :limit
                """)
                .param("requester", requester).param("status", status)
                .param("afterCreated", afterCreated == null ? null : Timestamp.from(afterCreated)).param("afterId", afterId)
                .param("limit", limit + 1)
                .query(requestMapper).list();
    }

    /** Other people's requests in a status, oldest first (the review queue); entitlements are filtered by the caller. */
    public List<ChangeRequestView> queue(UUID notRequester, String status, Instant afterCreated, UUID afterId, int limit) {
        return jdbc.sql(SELECT_REQUEST + """
                WHERE cr.requester_id <> :me AND cr.status::text = :status
                  AND (CAST(:afterCreated AS timestamptz) IS NULL
                       OR (cr.created_at, cr.change_request_id) > (CAST(:afterCreated AS timestamptz), CAST(:afterId AS uuid)))
                ORDER BY cr.created_at, cr.change_request_id
                LIMIT :limit
                """)
                .param("me", notRequester).param("status", status)
                .param("afterCreated", afterCreated == null ? null : Timestamp.from(afterCreated)).param("afterId", afterId)
                .param("limit", limit)
                .query(requestMapper).list();
    }

    public void decide(UUID requestId, UUID deciderId, String decision, String note) {
        jdbc.sql("SELECT mdm.decide_change_request(:cr, :decider, :decision, :note)")
                .param("cr", requestId).param("decider", deciderId).param("decision", decision).param("note", note)
                .query((rs, i) -> 0).single();
    }

    public void updateDraft(UUID id, String title, String rationale, String riskTier, LocalDate effectiveFrom,
                            String workflowModelCode, Boolean urgent) {
        jdbc.sql("""
                UPDATE mdm.change_request
                SET title = coalesce(:title, title), rationale = coalesce(:rationale, rationale),
                    risk_tier = coalesce(CAST(:risk AS mdm.risk_tier), risk_tier),
                    effective_from = coalesce(CAST(:from AS date), effective_from),
                    workflow_model_code = coalesce(CAST(:model AS text), workflow_model_code),
                    is_urgent = coalesce(CAST(:urgent AS boolean), is_urgent)
                WHERE change_request_id = :id
                """)
                .param("title", title).param("rationale", rationale).param("risk", riskTier).param("from", effectiveFrom)
                .param("model", workflowModelCode).param("urgent", urgent)
                .param("id", id).update();
    }

    public int nextSeq(UUID requestId) {
        return jdbc.sql("SELECT coalesce(max(seq), 0) + 1 FROM mdm.change_item WHERE change_request_id = :id")
                .param("id", requestId).query(Integer.class).single();
    }

    public UUID insertItem(UUID requestId, int seq, String action, UUID hierarchyId, UUID nodeId, UUID targetParentId,
                           UUID propertyId, JsonNode payload) {
        try {
            return jdbc.sql("""
                    INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, target_parent_id,
                                                 property_id, payload)
                    VALUES (:cr, :seq, CAST(:action AS mdm.change_action), :h, :n, :p, :prop, CAST(:payload AS jsonb))
                    RETURNING change_item_id
                    """)
                    .param("cr", requestId).param("seq", seq).param("action", action).param("h", hierarchyId)
                    .param("n", nodeId).param("p", targetParentId).param("prop", propertyId)
                    .param("payload", mapper.writeValueAsString(payload))
                    .query(UUID.class).single();
        } catch (JsonProcessingException e) {
            throw new IllegalStateException(e);
        }
    }

    public int deleteItem(UUID requestId, UUID itemId) {
        return jdbc.sql("DELETE FROM mdm.change_item WHERE change_request_id = :cr AND change_item_id = :id")
                .param("cr", requestId).param("id", itemId).update();
    }

    private static final String SELECT_ITEM = """
            SELECT ci.change_item_id, ci.seq, ci.action::text AS action, h.hierarchy_code, ci.node_id, ci.target_parent_id,
                   pd.property_code, ci.payload::text AS payload, ci.created_at, ci.hierarchy_id, ci.property_id
            FROM mdm.change_item ci
            LEFT JOIN mdm.hierarchy h ON h.hierarchy_id = ci.hierarchy_id
            LEFT JOIN mdm.property_definition pd ON pd.property_id = ci.property_id
            """;

    public Optional<ItemView> item(UUID itemId) {
        return jdbc.sql(SELECT_ITEM + " WHERE ci.change_item_id = :id").param("id", itemId).query(itemMapper).optional();
    }

    public List<ItemView> items(UUID requestId, int afterSeq, int limit) {
        return jdbc.sql(SELECT_ITEM + " WHERE ci.change_request_id = :cr AND ci.seq > :after ORDER BY ci.seq LIMIT :limit")
                .param("cr", requestId).param("after", afterSeq).param("limit", limit + 1).query(itemMapper).list();
    }

    /** All items of a request in order (for capturing expected values across earlier items, LLD §7.3). */
    public List<ItemView> allItems(UUID requestId) {
        return jdbc.sql(SELECT_ITEM + " WHERE ci.change_request_id = :cr ORDER BY ci.seq").param("cr", requestId)
                .query(itemMapper).list();
    }

    /** Hierarchy ids the request's items touch (for read access by people other than the requester). */
    public List<UUID> itemHierarchies(UUID requestId) {
        return jdbc.sql("SELECT DISTINCT hierarchy_id FROM mdm.change_item WHERE change_request_id = :cr AND hierarchy_id IS NOT NULL")
                .param("cr", requestId).query(UUID.class).list();
    }

    public UUID allocateNode(String nodeKind, UUID requestId) {
        return jdbc.sql("SELECT mdm.allocate_node(CAST(:kind AS mdm.node_kind), :cr)")
                .param("kind", nodeKind).param("cr", requestId).query(UUID.class).single();
    }

    /** (hierarchy, node) of each item, for scope checks: the target parent for placements, else the node. */
    public List<UUID[]> itemScopes(UUID requestId) {
        return jdbc.sql("""
                SELECT hierarchy_id, coalesce(target_parent_id, node_id) AS node_id
                FROM mdm.change_item WHERE change_request_id = :cr ORDER BY seq
                """).param("cr", requestId)
                .query((rs, i) -> new UUID[] {rs.getObject("hierarchy_id", UUID.class), rs.getObject("node_id", UUID.class)})
                .list();
    }

    public void submit(UUID requestId, UUID actorId) {
        jdbc.sql("SELECT mdm.submit_change_request(:cr, :actor)").param("cr", requestId).param("actor", actorId)
                .query((rs, i) -> 0).single();
    }

    public void withdraw(UUID requestId, UUID actorId) {
        jdbc.sql("SELECT mdm.withdraw_change_request(:cr, :actor)").param("cr", requestId).param("actor", actorId)
                .query((rs, i) -> 0).single();
    }
}
