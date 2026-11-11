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

  -- the decider: the latest human who committed or rejected; failing that, the
  -- system actor that committed under an approved policy (straight-through commit)
  SELECT a.actor_id, a.actor_kind, (a.payload->>'policy_id')::uuid
    INTO v_decider, v_kind, v_policy
  FROM wf.instance_action a
  JOIN wf.workflow_instance i ON i.instance_id = a.instance_id
  WHERE i.change_request_id = p_change_request_id AND a.action IN ('commit', 'reject')
  ORDER BY (a.actor_kind = 'human') DESC, a.occurred_at DESC
  LIMIT 1;

  UPDATE mdm.change_request cr
  SET status       = v_status,
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
    AND cr.status IS DISTINCT FROM v_status;

  RETURN v_status;
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
