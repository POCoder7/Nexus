-- =============================================================================
-- AI-enabled MDM — 05: WORKFLOW ↔ MDM BRIDGE, schema "wf_bridge"
--
-- The only code that writes from the workflow layer into the core model.
-- Dropping this schema (DROP SCHEMA wf_bridge CASCADE) fully decouples the two;
-- replacing it lets you plug in a different workflow product without touching
-- either mdm or wf.
--
-- Responsibilities
--   1. Keep mdm.change_request.status in step with its workflow instance(s).
--   2. Expose exactly which change items are cleared to apply. Only items in
--      committed instances are applied, so after a split, a rejected branch
--      never reaches the data.
-- mdm's own maker-checker trigger still runs on every status update, as a
-- second line of defence behind the workflow rules.
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS wf_bridge;
SET search_path = wf_bridge, wf, mdm, public;

-- SECURITY DEFINER, owned by nexus_bridge (V7): the only role allowed to write decision columns on
-- mdm.change_request (ADR-014, ADR-019, D-04). Callers (the workflow role) cannot write mdm themselves.
CREATE FUNCTION wf_bridge.sync_change_request(p_change_request_id uuid)
RETURNS mdm.cr_status LANGUAGE plpgsql SECURITY DEFINER SET search_path = wf_bridge, wf, mdm, public AS $$
DECLARE
  n_open      int;
  n_committed int;
  n_rejected  int;
  n_total     int;
  v_decider   uuid;
  v_kind      mdm.requester_kind;
  v_policy    uuid;
  v_status    mdm.cr_status;
BEGIN
  SELECT count(*) FILTER (WHERE status IN ('draft', 'in_flight', 'pushed_back')),
         count(*) FILTER (WHERE status = 'committed'),
         count(*) FILTER (WHERE status = 'rejected'),
         count(*)
    INTO n_open, n_committed, n_rejected, n_total
  FROM wf.workflow_instance WHERE change_request_id = p_change_request_id;

  IF n_total = 0 THEN
    RETURN NULL;
  END IF;

  v_status := CASE
    WHEN n_open > 0      THEN 'in_review'
    WHEN n_committed > 0 THEN 'approved'     -- at least one branch committed
    WHEN n_rejected > 0  THEN 'rejected'
    ELSE 'withdrawn'
  END;

  -- The decider (D-06, LLD §7.3). An approved request is decided by whoever committed a COMMITTED instance: the latest
  -- human commit there, else the system commit under an approved policy. A rejected request is decided by the latest
  -- human rejection. The rejecter of one branch is never recorded as the decider of an approved request.
  IF v_status = 'approved' THEN
    SELECT a.actor_id, a.actor_kind, (a.payload->>'policy_id')::uuid
      INTO v_decider, v_kind, v_policy
    FROM wf.instance_action a
    JOIN wf.workflow_instance i ON i.instance_id = a.instance_id
    WHERE i.change_request_id = p_change_request_id AND i.status = 'committed' AND a.action = 'commit'
      AND a.actor_kind IN ('human', 'system_feed')
    ORDER BY (a.actor_kind = 'human') DESC, a.occurred_at DESC
    LIMIT 1;
  ELSIF v_status = 'rejected' THEN
    SELECT a.actor_id, a.actor_kind, NULL::uuid
      INTO v_decider, v_kind, v_policy
    FROM wf.instance_action a
    JOIN wf.workflow_instance i ON i.instance_id = a.instance_id
    WHERE i.change_request_id = p_change_request_id AND i.status = 'rejected' AND a.action = 'reject'
      AND a.actor_kind = 'human'
    ORDER BY a.occurred_at DESC
    LIMIT 1;
  END IF;

  UPDATE mdm.change_request cr
  SET governed_by_workflow = true,        -- set when the first instance starts (ADR-019); Phase 1 apply then uses clearance
      status       = v_status,
      submitted_at = coalesce(cr.submitted_at,
                              (SELECT min(submitted_at) FROM wf.workflow_instance
                               WHERE change_request_id = p_change_request_id)),
      decided_by   = CASE WHEN v_status IN ('approved', 'rejected') THEN v_decider ELSE cr.decided_by END,
      decided_at   = CASE WHEN v_status IN ('approved', 'rejected') THEN now()     ELSE cr.decided_at END,
      decision_basis = CASE WHEN v_status NOT IN ('approved', 'rejected') THEN cr.decision_basis
                            WHEN v_kind = 'system_feed' THEN 'approved_policy'::mdm.decision_basis
                            ELSE 'human_review'::mdm.decision_basis END,
      decision_policy_ref = CASE WHEN v_status IN ('approved', 'rejected') AND v_kind = 'system_feed'
                                 THEN v_policy
                                 WHEN v_status IN ('approved', 'rejected') THEN NULL
                                 ELSE cr.decision_policy_ref END
  WHERE cr.change_request_id = p_change_request_id
    AND (cr.status IS DISTINCT FROM v_status OR NOT cr.governed_by_workflow);

  -- Clearance (ADR-019): exactly the items of committed instances may be applied. A rejected or withdrawn branch of a
  -- split never reaches the data.
  IF v_status = 'approved' THEN
    INSERT INTO mdm.change_item_clearance (change_item_id)
    SELECT ii.change_item_id FROM wf.instance_item ii
    JOIN wf.workflow_instance i ON i.instance_id = ii.instance_id
    WHERE i.change_request_id = p_change_request_id AND i.status = 'committed'
    ON CONFLICT (change_item_id) DO NOTHING;
  END IF;

  RETURN v_status;
END $$;

-- Enrichment (GOV-02, ADR-023): during an Enrich stage, a person who can act on it adds or changes items of the request.
-- The item must be one the stage's task allows (wf.item_allowed_in_stage); it joins the instance so it is applied if the
-- instance commits. SECURITY DEFINER, owned by nexus_bridge: the only path by which items are added after draft
-- (mdm.trg_change_item_draft_only lets nexus_bridge, and nobody else, insert while the request is in_review).
CREATE FUNCTION wf_bridge.add_enrichment_item(p_stage uuid, p_user uuid, p_action mdm.change_action, p_hierarchy uuid,
                                              p_node uuid, p_target_parent uuid, p_property uuid, p_payload jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = wf_bridge, wf, mdm, public AS $$
DECLARE
  v_instance uuid;
  v_cr       uuid;
  v_item     uuid;
BEGIN
  SELECT ist.instance_id, i.change_request_id INTO v_instance, v_cr
  FROM wf.instance_stage ist
  JOIN wf.workflow_stage ws   ON ws.stage_id = ist.stage_id
  JOIN wf.workflow_instance i ON i.instance_id = ist.instance_id
  WHERE ist.instance_stage_id = p_stage AND ws.stage_type = 'enrich';
  IF v_instance IS NULL OR NOT wf.can_act(p_stage, p_user) THEN
    RAISE EXCEPTION 'User % cannot enrich this request in this stage', p_user USING ERRCODE = 'N1016', HINT = 'wf.cannot_act';
  END IF;
  PERFORM 1 FROM mdm.change_request WHERE change_request_id = v_cr FOR UPDATE;   -- serialise seq allocation

  INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, target_parent_id, property_id, payload)
  SELECT v_cr, coalesce(max(seq), 0) + 1, p_action, p_hierarchy, p_node, p_target_parent, p_property, coalesce(p_payload, '{}')
  FROM mdm.change_item WHERE change_request_id = v_cr
  RETURNING change_item_id INTO v_item;
  INSERT INTO wf.instance_item (change_item_id, instance_id) VALUES (v_item, v_instance);

  IF NOT wf.item_allowed_in_stage(v_item, p_stage) THEN
    RAISE EXCEPTION 'This change is not editable in this stage (task does not allow %)', p_action
      USING ERRCODE = 'N1013', HINT = 'wf.item_not_editable';
  END IF;
  INSERT INTO wf.instance_action (instance_id, instance_stage_id, actor_id, actor_kind, action, payload)
  VALUES (v_instance, p_stage, p_user, 'human', 'enrich', jsonb_build_object('change_item_id', v_item));
  RETURN v_item;
END $$;

CREATE FUNCTION wf_bridge.trg_sync() RETURNS trigger
LANGUAGE plpgsql SET search_path = wf_bridge, wf, mdm, public AS $$
BEGIN
  PERFORM wf_bridge.sync_change_request(NEW.change_request_id);
  RETURN NEW;
END $$;

CREATE TRIGGER bridge_sync_change_request
  AFTER INSERT OR UPDATE OF status ON wf.workflow_instance
  FOR EACH ROW EXECUTE FUNCTION wf_bridge.trg_sync();

-- What the MDM apply service may apply: items in committed instances, not yet applied.
CREATE VIEW wf_bridge.v_items_to_apply AS
SELECT ci.change_request_id, ci.change_item_id, ci.seq, ci.action,
       ci.hierarchy_id, ci.node_id, ci.target_parent_id, ci.property_id, ci.payload,
       i.instance_id, i.closed_at AS committed_at
FROM wf.instance_item ii
JOIN wf.workflow_instance i ON i.instance_id = ii.instance_id AND i.status = 'committed'
JOIN mdm.change_item ci     ON ci.change_item_id = ii.change_item_id
JOIN mdm.change_request cr  ON cr.change_request_id = ci.change_request_id
WHERE cr.status = 'approved';                -- becomes 'applied' once the apply service finishes
