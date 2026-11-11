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
