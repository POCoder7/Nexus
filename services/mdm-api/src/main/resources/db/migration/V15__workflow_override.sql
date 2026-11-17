-- =============================================================================
-- V15 — Workflow override (ADR-042 D4; Phase 5 LLD §19.5, increment 5-4c).
-- An ADMIN may decide an open stage in place of its groups, with a reason. The override passes over group membership,
-- claims and group order, and nothing else: the ADMIN is never the requester or submitter, is a person, and is bound
-- by separation of duties like any approver. Every override is one decision row per undecided group, marked as an
-- override, plus one 'override' history action carrying the reason.
-- =============================================================================
SET search_path = wf, mdm, public;

ALTER TABLE wf.stage_group_decision ADD COLUMN override boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN wf.stage_group_decision.override IS
  'Written by wf.override_stage: an ADMIN decided for this group (ADR-042 D4); the reason is the comment.';

-- True if the user holds ADMIN over every hierarchy the request's items touch (a whole-hierarchy or every-hierarchy
-- grant; an item without a hierarchy needs every hierarchy). Reads mdm, writes nothing.
CREATE FUNCTION wf.admin_covers_request(p_user uuid, p_change_request uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path = wf, mdm, public AS $$
  SELECT (SELECT is_active FROM mdm.app_user WHERE user_id = p_user)
     AND NOT EXISTS (
       SELECT 1 FROM (SELECT DISTINCT ci.hierarchy_id FROM mdm.change_item ci WHERE ci.change_request_id = p_change_request) h
       WHERE NOT EXISTS (
         SELECT 1 FROM mdm.effective_grants(p_user, mdm.business_today()) g
         WHERE g.role_code = 'ADMIN'
           AND (g.hierarchy_id IS NULL OR (g.hierarchy_id = h.hierarchy_id AND g.top_node_id IS NULL))))
$$;

-- The decision guard (V4), with one exception: an override row is accepted only while wf.override_stage is writing it
-- for that stage (the session setting it makes, as mdm.sandbox_capture in V12). Anything else that marks a row as an
-- override is refused, and an ordinary row is checked as before.
CREATE OR REPLACE FUNCTION wf.trg_decision_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
BEGIN
  IF NEW.override THEN
    IF current_setting('wf.override_stage', true) IS DISTINCT FROM NEW.instance_stage_id::text THEN
      RAISE EXCEPTION 'An override is recorded only by wf.override_stage'
        USING ERRCODE = 'N1031', HINT = 'wf.override_refused.not_through_override';
    END IF;
    RETURN NEW;
  END IF;
  IF NOT wf.is_member(NEW.group_id, NEW.decided_by, mdm.business_today()) THEN
    RAISE EXCEPTION 'User % is not a member of the deciding group', NEW.decided_by USING ERRCODE = 'N1015', HINT = 'wf.not_group_member';
  END IF;
  IF NOT wf.can_act(NEW.instance_stage_id, NEW.decided_by) THEN
    RAISE EXCEPTION 'User % cannot act on this stage (claim, group order, separation of duties or node access)',
      NEW.decided_by USING ERRCODE = 'N1016', HINT = 'wf.cannot_act';
  END IF;
  RETURN NEW;
END $$;

-- An ADMIN's decision in place of the stage's groups. Refusals are N1031 (wf.override_refused.<case>); the decision
-- itself is approve or reject (push-back is GOV-09, not built). Returns the stage outcome; the worker completes the
-- stage from the outbox event, as for any decision.
CREATE FUNCTION wf.override_stage(p_stage uuid, p_actor uuid, p_decision text, p_reason text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = wf, mdm, public AS $$
DECLARE
  s      wf.instance_stage%ROWTYPE;
  i      wf.workflow_instance%ROWTYPE;
  cr     mdm.change_request%ROWTYPE;
  v_type wf.stage_type;
  v_out  text;
  v_n    int;
BEGIN
  IF p_decision IS NULL OR p_decision NOT IN ('approve', 'reject') THEN
    RAISE EXCEPTION 'Decision must be approve or reject' USING ERRCODE = '22023', HINT = 'decision.invalid';
  END IF;
  IF length(btrim(coalesce(p_reason, ''))) < 10 THEN
    RAISE EXCEPTION 'An override needs a reason of at least 10 characters'
      USING ERRCODE = 'N1031', HINT = 'wf.override_refused.reason_required';
  END IF;
  IF (SELECT kind FROM mdm.app_user WHERE user_id = p_actor) IS DISTINCT FROM 'human' THEN
    RAISE EXCEPTION 'Only a person can override a stage' USING ERRCODE = 'N1031', HINT = 'wf.override_refused.not_human';
  END IF;
  SELECT * INTO s FROM wf.instance_stage WHERE instance_stage_id = p_stage FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Stage % not found', p_stage USING ERRCODE = 'N1031', HINT = 'wf.override_refused.stage_closed';
  END IF;
  SELECT * INTO i FROM wf.workflow_instance WHERE instance_id = s.instance_id;
  SELECT * INTO cr FROM mdm.change_request WHERE change_request_id = i.change_request_id;
  SELECT stage_type INTO v_type FROM wf.workflow_stage WHERE stage_id = s.stage_id;
  IF i.status <> 'in_flight' OR s.status NOT IN ('active', 'claimed') OR v_type NOT IN ('approve', 'commit') THEN
    RAISE EXCEPTION 'Only an open approve or commit stage can be overridden'
      USING ERRCODE = 'N1031', HINT = 'wf.override_refused.stage_closed';
  END IF;
  IF NOT wf.admin_covers_request(p_actor, cr.change_request_id) THEN
    RAISE EXCEPTION 'Only an ADMIN for every hierarchy of the request can override its stages'
      USING ERRCODE = 'N1031', HINT = 'wf.override_refused.not_admin';
  END IF;
  IF p_actor IN (cr.requester_id, i.submitted_by) THEN
    RAISE EXCEPTION 'Nobody overrides a stage of their own request'
      USING ERRCODE = 'N1031', HINT = 'wf.override_refused.own_request';
  END IF;
  IF wf.sod_violation(p_stage, p_actor) THEN
    RAISE EXCEPTION 'You decided another stage of this request; separation of duties applies to an override too'
      USING ERRCODE = 'N1031', HINT = 'wf.override_refused.separation_of_duties';
  END IF;

  PERFORM set_config('wf.override_stage', p_stage::text, true);
  INSERT INTO wf.stage_group_decision (instance_stage_id, group_id, decided_by, decision, comment, override)
  SELECT p_stage, sg.group_id, p_actor, p_decision, btrim(p_reason), true
  FROM wf.stage_group sg
  WHERE sg.stage_id = s.stage_id
    AND NOT EXISTS (SELECT 1 FROM wf.stage_group_decision d WHERE d.instance_stage_id = p_stage AND d.group_id = sg.group_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM set_config('wf.override_stage', '', true);
  IF v_n = 0 THEN
    RAISE EXCEPTION 'Every group has already decided this stage' USING ERRCODE = 'N1031', HINT = 'wf.override_refused.stage_closed';
  END IF;

  INSERT INTO wf.instance_action (instance_id, instance_stage_id, actor_id, actor_kind, action, comment, payload)
  VALUES (s.instance_id, p_stage, p_actor, 'human', 'override', btrim(p_reason),
          jsonb_build_object('decision', p_decision, 'groups', v_n));
  v_out := wf.stage_outcome(p_stage);
  INSERT INTO wf.event_outbox (event_type, instance_id, payload)
  VALUES ('stage_decision_recorded', s.instance_id, jsonb_build_object('instance_stage_id', p_stage, 'outcome', v_out, 'override', true));
  RETURN v_out;
END $$;
ALTER FUNCTION wf.override_stage(uuid, uuid, text, text) OWNER TO nexus_wf;
REVOKE EXECUTE ON FUNCTION wf.override_stage(uuid, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION wf.override_stage(uuid, uuid, text, text) TO nexus_api;
