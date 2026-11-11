-- =============================================================================
-- Nexus — 09: WORKFLOW, PHASE 2 (new objects; Phase 2 LLD §4, ADR-023, ADR-035)
-- Separation rules as in V4: wf reads mdm, never writes it; only wf_bridge writes across.
-- =============================================================================
SET search_path = wf, mdm, public;

-- -----------------------------------------------------------------------------
-- Configuration audit (LLD §4.2): wf's own append-only log, so wf never writes mdm.audit_log.
-- SECURITY DEFINER trigger owned by the migration owner: no application role can insert audit rows of its own making.
-- -----------------------------------------------------------------------------
CREATE TABLE wf.config_audit (
  audit_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  table_name  text NOT NULL,
  action      text NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
  old_row     jsonb,
  new_row     jsonb,
  actor_id    uuid,                                    -- from the transaction setting wf.actor_id; NULL if not set
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TRIGGER config_audit_append_only BEFORE UPDATE OR DELETE ON wf.config_audit
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_append_only();

CREATE FUNCTION wf.trg_config_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = wf, mdm, public AS $$
BEGIN
  INSERT INTO wf.config_audit (table_name, action, old_row, new_row, actor_id)
  VALUES (TG_TABLE_NAME, TG_OP,
          CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
          CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END,
          nullif(current_setting('wf.actor_id', true), '')::uuid);
  RETURN COALESCE(NEW, OLD);
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['user_group', 'user_group_member', 'workflow_model', 'workflow_stage', 'stage_group',
                           'commit_policy', 'policy_scope', 'stp_protected_property', 'freeze_window'] LOOP
    EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON wf.%I
                    FOR EACH ROW EXECUTE FUNCTION wf.trg_config_audit()', t || '_config_audit', t);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- Governed membership changes (CR-10, ADR-029 pattern): who may approve requests and policies is itself four-eyes.
-- A WORKFLOW_ADMIN proposes, a different WORKFLOW_ADMIN approves; a change to POLICY_APPROVERS needs an approver who
-- is in POLICY_APPROVERS. Approving applies the change; nothing else writes wf.user_group_member.
-- -----------------------------------------------------------------------------
CREATE TABLE wf.membership_change (
  change_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id    uuid NOT NULL REFERENCES wf.user_group,
  user_id     uuid NOT NULL REFERENCES mdm.app_user,
  op          text NOT NULL CHECK (op IN ('add', 'end')),
  valid_from  date NOT NULL,                           -- business date the membership starts or ends
  reason      text NOT NULL,
  proposed_by uuid NOT NULL REFERENCES mdm.app_user,
  proposed_at timestamptz NOT NULL DEFAULT now(),
  status      text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'applied', 'rejected')),
  decided_by  uuid REFERENCES mdm.app_user,
  decided_at  timestamptz,
  CHECK (status = 'pending' OR (decided_by IS NOT NULL AND decided_by <> proposed_by))
);

-- Content is fixed once proposed; the only change is pending → applied | rejected.
CREATE FUNCTION wf.trg_membership_change_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Membership changes are kept; reject a pending change instead' USING ERRCODE = 'N2011', HINT = 'append_only';
  END IF;
  IF OLD.status <> 'pending'
     OR (to_jsonb(NEW) - ARRAY['status', 'decided_by', 'decided_at']) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status', 'decided_by', 'decided_at']) THEN
    RAISE EXCEPTION 'Membership change % can no longer change', OLD.change_id USING ERRCODE = 'N2230', HINT = 'wf.membership_not_pending';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER membership_change_guard BEFORE UPDATE OR DELETE ON wf.membership_change
  FOR EACH ROW EXECUTE FUNCTION wf.trg_membership_change_guard();
CREATE TRIGGER membership_change_config_audit AFTER INSERT OR UPDATE ON wf.membership_change
  FOR EACH ROW EXECUTE FUNCTION wf.trg_config_audit();

-- A human with the WORKFLOW_ADMIN role for all hierarchies on the business day (mdm.user_role, read only).
CREATE FUNCTION wf.is_workflow_admin(p_user uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path = wf, mdm, public AS $$
  SELECT EXISTS (SELECT 1 FROM mdm.user_role ur JOIN mdm.app_user u ON u.user_id = ur.user_id
                 WHERE ur.user_id = p_user AND ur.role_code = 'WORKFLOW_ADMIN' AND ur.hierarchy_id IS NULL
                   AND ur.valid_period @> mdm.business_today() AND upper_inf(ur.recorded_period)
                   AND u.kind = 'human' AND u.is_active)
$$;

CREATE FUNCTION wf.propose_membership_change(p_group uuid, p_user uuid, p_op text, p_valid_from date, p_reason text,
                                             p_proposer uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = wf, mdm, public AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT wf.is_workflow_admin(p_proposer) THEN
    RAISE EXCEPTION 'Only a workflow administrator can propose membership changes' USING ERRCODE = 'N1026', HINT = 'wf.not_workflow_admin';
  END IF;
  IF p_valid_from < mdm.business_today() THEN   -- no retroactive approvers
    RAISE EXCEPTION 'A membership change cannot take effect before today (%)', mdm.business_today()
      USING ERRCODE = 'N2233', HINT = 'wf.membership_backdated';
  END IF;
  PERFORM set_config('wf.actor_id', p_proposer::text, true);
  INSERT INTO wf.membership_change (group_id, user_id, op, valid_from, reason, proposed_by)
  VALUES (p_group, p_user, p_op, p_valid_from, p_reason, p_proposer) RETURNING change_id INTO v_id;
  RETURN v_id;
END $$;

-- Approve (and apply) or reject a pending change. The approver is a different workflow administrator; for
-- POLICY_APPROVERS also a member of POLICY_APPROVERS (the policy approvers vouch for each other).
CREATE FUNCTION wf.decide_membership_change(p_change uuid, p_decider uuid, p_approve boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = wf, mdm, public AS $$
DECLARE
  c     wf.membership_change%ROWTYPE;
  v_row wf.user_group_member%ROWTYPE;
  v_policy_approvers uuid := (SELECT group_id FROM wf.user_group WHERE group_code = 'POLICY_APPROVERS');
BEGIN
  SELECT * INTO c FROM wf.membership_change WHERE change_id = p_change FOR UPDATE;
  IF NOT FOUND OR c.status <> 'pending' THEN
    RAISE EXCEPTION 'Membership change % is not pending', p_change USING ERRCODE = 'N2230', HINT = 'wf.membership_not_pending';
  END IF;
  IF p_decider = c.proposed_by THEN
    RAISE EXCEPTION 'Maker-checker violation: the proposer cannot decide their own membership change'
      USING ERRCODE = 'N1001', HINT = 'maker_checker.self_decision';
  END IF;
  IF NOT wf.is_workflow_admin(p_decider) THEN
    RAISE EXCEPTION 'Only a workflow administrator can decide membership changes' USING ERRCODE = 'N1026', HINT = 'wf.not_workflow_admin';
  END IF;
  IF c.group_id = v_policy_approvers AND NOT wf.is_member(v_policy_approvers, p_decider, mdm.business_today()) THEN
    RAISE EXCEPTION 'Changes to POLICY_APPROVERS need an approver who is in POLICY_APPROVERS'
      USING ERRCODE = 'N1020', HINT = 'policy.not_approver';
  END IF;
  PERFORM set_config('wf.actor_id', p_decider::text, true);

  IF p_approve THEN
    IF c.valid_from < mdm.business_today() THEN
      RAISE EXCEPTION 'Membership change % would now take effect in the past', p_change USING ERRCODE = 'N2233', HINT = 'wf.membership_backdated';
    END IF;
    IF c.op = 'add' THEN
      IF EXISTS (SELECT 1 FROM wf.user_group_member m WHERE m.group_id = c.group_id AND m.user_id = c.user_id
                 AND m.valid_period && daterange(c.valid_from, NULL) AND upper_inf(m.recorded_period)) THEN
        RAISE EXCEPTION 'User % is already a member of the group on or after %', c.user_id, c.valid_from
          USING ERRCODE = 'N2232', HINT = 'wf.membership_exists';
      END IF;
      INSERT INTO wf.user_group_member (group_id, user_id, valid_period, granted_by, change_id)
      VALUES (c.group_id, c.user_id, daterange(c.valid_from, NULL), p_decider, c.change_id);
    ELSE
      SELECT * INTO v_row FROM wf.user_group_member m
      WHERE m.group_id = c.group_id AND m.user_id = c.user_id AND upper_inf(m.recorded_period)
        AND m.valid_period && daterange(c.valid_from, NULL)
      ORDER BY lower(m.valid_period) LIMIT 1 FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'User % is not a member of the group on or after %', c.user_id, c.valid_from
          USING ERRCODE = 'N2231', HINT = 'wf.membership_missing';
      END IF;
      -- end, never update: close the recorded belief and re-state the part before the end date
      UPDATE wf.user_group_member SET recorded_period = tstzrange(lower(recorded_period), now())
      WHERE group_id = v_row.group_id AND user_id = v_row.user_id AND valid_period = v_row.valid_period
        AND upper_inf(recorded_period);
      IF lower(v_row.valid_period) < c.valid_from THEN
        INSERT INTO wf.user_group_member (group_id, user_id, valid_period, granted_by, change_id)
        VALUES (v_row.group_id, v_row.user_id, daterange(lower(v_row.valid_period), c.valid_from), v_row.granted_by, c.change_id);
      END IF;
    END IF;
  END IF;

  UPDATE wf.membership_change
  SET status = CASE WHEN p_approve THEN 'applied' ELSE 'rejected' END, decided_by = p_decider, decided_at = now()
  WHERE change_id = p_change;
END $$;

-- -----------------------------------------------------------------------------
-- Privileges for the objects above (V7 runs before this file; its default privileges gave nexus_wf DML on new wf
-- tables). Membership and its governance are written only by the functions; the audit only by its trigger.
-- -----------------------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE ON wf.user_group_member, wf.membership_change, wf.config_audit FROM nexus_wf;
REVOKE EXECUTE ON FUNCTION wf.propose_membership_change(uuid, uuid, text, date, text, uuid),
                           wf.decide_membership_change(uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION wf.propose_membership_change(uuid, uuid, text, date, text, uuid),
                          wf.decide_membership_change(uuid, uuid, boolean) TO nexus_api;

-- -----------------------------------------------------------------------------
-- Stage decisions, claims and closing (2-3, D-12, D-13): owner-run as nexus_wf (which writes wf), callable by the API
-- (decisions, claims, withdraw) and the worker (close), never directly by anyone else.
-- -----------------------------------------------------------------------------
ALTER FUNCTION wf.record_stage_decision(uuid, uuid, text, text) OWNER TO nexus_wf;
ALTER FUNCTION wf.claim_stage(uuid, uuid) OWNER TO nexus_wf;
ALTER FUNCTION wf.unclaim_stage(uuid, uuid) OWNER TO nexus_wf;
ALTER FUNCTION wf.close_instance(uuid, wf.instance_status, uuid, text) OWNER TO nexus_wf;
REVOKE EXECUTE ON FUNCTION wf.record_stage_decision(uuid, uuid, text, text), wf.claim_stage(uuid, uuid),
                           wf.unclaim_stage(uuid, uuid), wf.close_instance(uuid, wf.instance_status, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION wf.record_stage_decision(uuid, uuid, text, text), wf.claim_stage(uuid, uuid),
                          wf.unclaim_stage(uuid, uuid), wf.close_instance(uuid, wf.instance_status, uuid, text) TO nexus_api;
GRANT EXECUTE ON FUNCTION wf.close_instance(uuid, wf.instance_status, uuid, text) TO nexus_wf;

-- -----------------------------------------------------------------------------
-- Bridge (2-6, ADR-023): enrichment items are written only by wf_bridge.add_enrichment_item, owned by nexus_bridge.
-- -----------------------------------------------------------------------------
GRANT INSERT ON mdm.change_item TO nexus_bridge;              -- guarded: only while in_review, only this role (V1)
GRANT INSERT ON wf.instance_item, wf.instance_action TO nexus_bridge;
ALTER FUNCTION wf_bridge.add_enrichment_item(uuid, uuid, mdm.change_action, uuid, uuid, uuid, uuid, jsonb) OWNER TO nexus_bridge;
REVOKE EXECUTE ON FUNCTION wf_bridge.add_enrichment_item(uuid, uuid, mdm.change_action, uuid, uuid, uuid, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION wf_bridge.add_enrichment_item(uuid, uuid, mdm.change_action, uuid, uuid, uuid, uuid, jsonb) TO nexus_api;

-- -----------------------------------------------------------------------------
-- Stage progression (LLD §4.5, §7.1): the operations the engine calls (ADR-024, ADR-035 WorkflowSteps). Each locks the
-- instance and is idempotent, so a repeated or late call does no harm.
-- -----------------------------------------------------------------------------
CREATE FUNCTION wf.advance_instance(p_instance uuid)
RETURNS TABLE (action text, instance_stage_id uuid, stage_type wf.stage_type, due_at timestamptz)
LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
#variable_conflict use_column
DECLARE
  i     wf.workflow_instance%ROWTYPE;
  cur   record;
  nxt   record;
  v_inc boolean;
BEGIN
  SELECT * INTO i FROM wf.workflow_instance wi WHERE wi.instance_id = p_instance FOR UPDATE;
  IF NOT FOUND OR i.status <> 'in_flight' THEN
    RETURN QUERY SELECT 'none'::text, NULL::uuid, NULL::wf.stage_type, NULL::timestamptz; RETURN;
  END IF;
  SELECT ist.instance_stage_id AS id, ist.status, ws.stage_type AS type, ist.due_at AS due
    INTO cur
  FROM wf.instance_stage ist JOIN wf.workflow_stage ws ON ws.stage_id = ist.stage_id
  WHERE ist.instance_id = p_instance AND ist.seq = i.current_seq
  ORDER BY ist.iteration DESC LIMIT 1;
  IF cur.status IN ('active', 'claimed') THEN
    RETURN QUERY SELECT 'wait'::text, cur.id, cur.type, cur.due; RETURN;
  END IF;
  IF cur.type = 'commit' AND cur.status = 'completed' THEN
    RETURN QUERY SELECT 'none'::text, NULL::uuid, NULL::wf.stage_type, NULL::timestamptz; RETURN;   -- close follows
  END IF;

  LOOP
    SELECT ist.instance_stage_id AS id, ist.seq, ws.stage_type AS type, ws.condition, ws.split_on_condition,
           ws.stage_duration
      INTO nxt
    FROM wf.instance_stage ist JOIN wf.workflow_stage ws ON ws.stage_id = ist.stage_id
    WHERE ist.instance_id = p_instance AND ist.seq > i.current_seq AND ist.status = 'pending'
      AND ist.iteration = (SELECT max(x.iteration) FROM wf.instance_stage x
                           WHERE x.instance_id = ist.instance_id AND x.stage_id = ist.stage_id)
    ORDER BY ist.seq LIMIT 1;
    IF NOT FOUND THEN
      RETURN QUERY SELECT 'none'::text, NULL::uuid, NULL::wf.stage_type, NULL::timestamptz; RETURN;
    END IF;

    IF nxt.condition IS NOT NULL THEN                              -- GOV-04 (outline): evaluate and skip; no splits
      IF nxt.split_on_condition THEN
        RAISE EXCEPTION 'Conditional splits are not enabled (GOV-04 pending a decision)' USING ERRCODE = 'N2202', HINT = 'wf.split_not_enabled';
      END IF;
      SELECT bool_and(wf.item_condition_matches(ii.change_item_id, nxt.condition)) INTO v_inc
      FROM wf.instance_item ii WHERE ii.instance_id = p_instance;
      IF NOT coalesce(v_inc, false) THEN
        UPDATE wf.instance_stage SET status = 'skipped', included = false WHERE instance_stage_id = nxt.id;
        UPDATE wf.workflow_instance SET current_seq = nxt.seq WHERE instance_id = p_instance;
        i.current_seq := nxt.seq;
        CONTINUE;
      END IF;
      UPDATE wf.instance_stage SET included = true WHERE instance_stage_id = nxt.id;
    END IF;

    -- the Commit stage is preceded by one policy evaluation per instance (GOV-12; shadow mode by default)
    IF nxt.type = 'commit' AND NOT EXISTS (SELECT 1 FROM wf.policy_evaluation pe WHERE pe.instance_id = p_instance) THEN
      RETURN QUERY SELECT 'evaluate_policy'::text, nxt.id, nxt.type, NULL::timestamptz; RETURN;
    END IF;

    UPDATE wf.instance_stage
    SET status = 'active', started_at = now(), due_at = now() + nxt.stage_duration
    WHERE instance_stage_id = nxt.id;
    UPDATE wf.workflow_instance SET current_seq = nxt.seq WHERE instance_id = p_instance;
    RETURN QUERY SELECT 'activated'::text, nxt.id, nxt.type, (SELECT s.due_at FROM wf.instance_stage s WHERE s.instance_stage_id = nxt.id);
    RETURN;
  END LOOP;
END $$;

-- An approved stage is completed (the engine calls this after the stage-decided message). Re-checks the outcome, so a
-- forged or early message cannot move a request on.
CREATE FUNCTION wf.complete_stage(p_stage uuid)
RETURNS text LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
DECLARE s wf.instance_stage%ROWTYPE;
BEGIN
  SELECT * INTO s FROM wf.instance_stage WHERE instance_stage_id = p_stage;
  PERFORM 1 FROM wf.workflow_instance WHERE instance_id = s.instance_id FOR UPDATE;
  SELECT * INTO s FROM wf.instance_stage WHERE instance_stage_id = p_stage FOR UPDATE;
  IF s.status = 'completed' THEN
    RETURN 'completed';
  END IF;
  IF wf.stage_outcome(p_stage) IS DISTINCT FROM 'approved' OR s.status NOT IN ('active', 'claimed') THEN
    RAISE EXCEPTION 'Stage % is not approved', p_stage USING ERRCODE = 'N2234', HINT = 'wf.stage_not_approved';
  END IF;
  UPDATE wf.instance_stage SET status = 'completed', completed_at = now() WHERE instance_stage_id = p_stage;
  RETURN 'completed';
END $$;

-- -----------------------------------------------------------------------------
-- Model definitions (GOV-01, LLD §3.1 ModelDefinitionLoader): a JSON definition becomes a new draft version of the
-- model; a second workflow administrator activates it (wf.trg_model_status, N1014). Groups must exist; tasks are
-- created when missing and reused when present. Validation (wf.validate_model) runs at activation.
-- -----------------------------------------------------------------------------
CREATE FUNCTION wf.load_model(p_definition jsonb, p_actor uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = wf, mdm, public AS $$
DECLARE
  v_model uuid;
  v_code  text := p_definition ->> 'code';
  t       jsonb;
  s       jsonb;
  p       jsonb;
  g       text;
  v_task  uuid;
  v_stage uuid;
  v_group uuid;
BEGIN
  IF NOT wf.is_workflow_admin(p_actor) THEN
    RAISE EXCEPTION 'Only a workflow administrator can load models' USING ERRCODE = 'N1026', HINT = 'wf.not_workflow_admin';
  END IF;
  IF v_code IS NULL OR p_definition ->> 'label' IS NULL OR jsonb_typeof(p_definition -> 'stages') <> 'array' THEN
    RAISE EXCEPTION 'A model definition needs code, label and stages' USING ERRCODE = 'N2206', HINT = 'wf.model_invalid';
  END IF;
  PERFORM set_config('wf.actor_id', p_actor::text, true);

  INSERT INTO wf.workflow_model (model_code, model_version, label, description, request_duration, created_by)
  SELECT v_code, coalesce(max(m.model_version), 0) + 1, p_definition ->> 'label', p_definition ->> 'description',
         (p_definition ->> 'requestDuration')::interval, p_actor
  FROM wf.workflow_model m WHERE m.model_code = v_code
  RETURNING model_id INTO v_model;

  FOR t IN SELECT * FROM jsonb_array_elements(coalesce(p_definition -> 'tasks', '[]')) LOOP
    INSERT INTO wf.workflow_task (task_code, label, instructions, allowed_actions)
    VALUES (t ->> 'code', t ->> 'label', t ->> 'instructions',
            ARRAY(SELECT jsonb_array_elements_text(coalesce(t -> 'allowedActions', '[]')))::mdm.change_action[])
    ON CONFLICT (task_code) DO NOTHING
    RETURNING task_id INTO v_task;
    IF v_task IS NOT NULL THEN                                      -- a new task: its properties too
      FOR p IN SELECT * FROM jsonb_array_elements(coalesce(t -> 'properties', '[]')) LOOP
        INSERT INTO wf.task_property (task_id, property_id, is_required, is_read_only, sort_seq)
        SELECT v_task, pd.property_id, coalesce((p ->> 'required')::boolean, false), coalesce((p ->> 'readOnly')::boolean, false),
               (p ->> 'sortSeq')::int
        FROM mdm.property_definition pd WHERE pd.property_code = p ->> 'code';
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Unknown property % in task %', p ->> 'code', t ->> 'code' USING ERRCODE = 'N2208', HINT = 'wf.condition_property';
        END IF;
      END LOOP;
    END IF;
  END LOOP;

  FOR g IN SELECT jsonb_array_elements_text(coalesce(p_definition -> 'submitTasks', '[]')) LOOP
    INSERT INTO wf.submit_task (model_id, task_id) SELECT v_model, task_id FROM wf.workflow_task WHERE task_code = g;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Unknown task % in submitTasks', g USING ERRCODE = 'N2206', HINT = 'wf.model_invalid';
    END IF;
  END LOOP;

  FOR s IN SELECT * FROM jsonb_array_elements(p_definition -> 'stages') LOOP
    INSERT INTO wf.workflow_stage (model_id, seq, stage_type, label, task_id, approval_method, separation_of_duties,
                                   claim_duration, stage_duration, condition, split_on_condition)
    VALUES (v_model, (s ->> 'seq')::int, (s ->> 'type')::wf.stage_type, s ->> 'label',
            (SELECT task_id FROM wf.workflow_task WHERE task_code = s ->> 'task'),
            coalesce(s ->> 'approvalMethod', 'any_group')::wf.approval_method,
            coalesce((s ->> 'separationOfDuties')::boolean, false),
            (s ->> 'claimDuration')::interval, (s ->> 'stageDuration')::interval,
            s -> 'condition', coalesce((s ->> 'splitOnCondition')::boolean, false))
    RETURNING stage_id INTO v_stage;
    FOR g IN SELECT jsonb_array_elements_text(coalesce(s -> 'groups', '[]')) LOOP
      SELECT group_id INTO v_group FROM wf.user_group WHERE group_code = g AND is_active;
      IF v_group IS NULL THEN
        RAISE EXCEPTION 'Unknown or inactive group % in stage %', g, s ->> 'label' USING ERRCODE = 'N2235', HINT = 'wf.unknown_group';
      END IF;
      INSERT INTO wf.stage_group (stage_id, group_id, seq)
      VALUES (v_stage, v_group, (SELECT count(*) + 1 FROM wf.stage_group WHERE stage_id = v_stage));
    END LOOP;
    FOR p IN SELECT * FROM jsonb_array_elements(coalesce(s -> 'scopes', '[]')) LOOP
      INSERT INTO wf.stage_access_scope (stage_id, hierarchy_id, top_node_id)
      SELECT v_stage, h.hierarchy_id, (p ->> 'topNode')::uuid FROM mdm.hierarchy h WHERE h.hierarchy_code = p ->> 'hierarchy';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown hierarchy % in a stage scope', p ->> 'hierarchy' USING ERRCODE = 'N2206', HINT = 'wf.model_invalid';
      END IF;
    END LOOP;
  END LOOP;
  RETURN v_model;
END $$;

-- Activate a draft version: a workflow administrator other than its creator (the trigger enforces N1014 and runs
-- wf.validate_model). The active version of the same code is retired; requests in flight keep the version they started on.
CREATE FUNCTION wf.activate_model(p_model uuid, p_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = wf, mdm, public AS $$
DECLARE v_code text;
BEGIN
  IF NOT wf.is_workflow_admin(p_actor) THEN
    RAISE EXCEPTION 'Only a workflow administrator can activate models' USING ERRCODE = 'N1026', HINT = 'wf.not_workflow_admin';
  END IF;
  SELECT model_code INTO v_code FROM wf.workflow_model WHERE model_id = p_model AND status = 'draft' FOR UPDATE;
  IF v_code IS NULL THEN
    RAISE EXCEPTION 'Model % is not a draft', p_model USING ERRCODE = 'N2207', HINT = 'wf.model_status';
  END IF;
  PERFORM set_config('wf.actor_id', p_actor::text, true);
  UPDATE wf.workflow_model SET status = 'retired' WHERE model_code = v_code AND status = 'active';
  UPDATE wf.workflow_model SET status = 'active', activated_by = p_actor, activated_at = now() WHERE model_id = p_model;
END $$;

ALTER FUNCTION wf.load_model(jsonb, uuid) OWNER TO nexus_wf;
ALTER FUNCTION wf.activate_model(uuid, uuid) OWNER TO nexus_wf;
REVOKE EXECUTE ON FUNCTION wf.load_model(jsonb, uuid), wf.activate_model(uuid, uuid),
                           wf.advance_instance(uuid), wf.complete_stage(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION wf.load_model(jsonb, uuid), wf.activate_model(uuid, uuid) TO nexus_api;
GRANT EXECUTE ON FUNCTION wf.advance_instance(uuid), wf.complete_stage(uuid) TO nexus_wf;   -- the worker's steps
