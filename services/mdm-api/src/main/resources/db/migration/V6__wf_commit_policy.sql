-- =============================================================================
-- AI-enabled MDM — 06: COMMIT POLICIES (governed straight-through commit), schema "wf"
-- Requires 01–04. Part of the workflow layer: reads mdm, never writes to it.
--
-- Principle: maker-checker moves from each request to the policy. Humans approve
-- a narrow rule set saying which low-risk requests may commit without a reviewer;
-- the system commits only when every check passes, and records which policy
-- allowed it. Everything else routes to a human.
--
-- Controls built in
--   Preventive : approved policy (maker-checker + approver group), hard limits on
--                actions, protected properties, low risk tier only, no AI-originated
--                requests, validations must pass, freeze windows, daily caps,
--                re-certification date, kill switch.
--   Evidence   : shadow mode records what the policy WOULD have done while humans
--                still decide, and compares the two.
--   Detective  : daily random sampling of auto-commits for human review.
-- =============================================================================
SET search_path = wf, mdm, public;

CREATE TYPE wf.policy_mode    AS ENUM ('disabled', 'shadow', 'active');
CREATE TYPE wf.policy_status  AS ENUM ('draft', 'pending_approval', 'approved', 'retired');
CREATE TYPE wf.policy_outcome AS ENUM ('auto_committed', 'routed_to_human',
                                       'shadow_would_commit', 'shadow_would_route');

-- Group whose members approve commit policies (membership managed by Risk/Audit).
INSERT INTO wf.user_group (group_code, name, description)
VALUES ('POLICY_APPROVERS', 'Commit policy approvers',
        'Approve straight-through commit policies. Typically Risk/Audit-nominated data owners.')
ON CONFLICT (group_code) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Policies
-- -----------------------------------------------------------------------------
CREATE TABLE wf.commit_policy (
  policy_id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  policy_code              text NOT NULL,
  policy_version           int  NOT NULL DEFAULT 1,
  description              text NOT NULL,
  rationale                text NOT NULL,              -- why this is safe; what Audit reviews
  mode                     wf.policy_mode   NOT NULL DEFAULT 'shadow',
  status                   wf.policy_status NOT NULL DEFAULT 'draft',
  allowed_actions          mdm.change_action[] NOT NULL,
  item_conditions          jsonb,                      -- every item must match (wf.item_condition_matches format)
  max_items_per_request    int NOT NULL DEFAULT 50  CHECK (max_items_per_request > 0),
  max_auto_commits_per_day int NOT NULL DEFAULT 500 CHECK (max_auto_commits_per_day > 0),
  kill_switch              boolean NOT NULL DEFAULT false,
  owner_group_id           uuid NOT NULL REFERENCES wf.user_group,   -- may engage the kill switch
  proposed_by              uuid NOT NULL REFERENCES mdm.app_user,
  proposed_at              timestamptz NOT NULL DEFAULT now(),
  approved_by              uuid REFERENCES mdm.app_user,
  approved_at              timestamptz,
  approval_note            text,
  review_due               date,                       -- re-certification; lapses to ineligible
  UNIQUE (policy_code, policy_version),
  -- Hard limits no configuration can override: structural removals, moves,
  -- inactivations and ownership changes always need a human. Also deletes, renames and new hierarchies
  -- (Phase 1: D-36, ADR-026).
  CHECK (NOT (allowed_actions && ARRAY['move_node', 'remove_node', 'inactivate_node',
                                       'add_ownership_edge', 'update_ownership_edge',
                                       'end_ownership_edge',
                                       'delete_node', 'update_node', 'add_hierarchy']::mdm.change_action[])),
  CHECK (cardinality(allowed_actions) > 0),
  CHECK (status <> 'approved' OR (approved_by IS NOT NULL AND approved_by <> proposed_by AND review_due IS NOT NULL))
);
CREATE UNIQUE INDEX commit_policy_one_approved ON wf.commit_policy (policy_code) WHERE status = 'approved';

-- Which workflow models a policy covers (by model code, so it follows model versions).
CREATE TABLE wf.policy_scope (
  policy_id  uuid NOT NULL REFERENCES wf.commit_policy ON DELETE CASCADE,
  model_code text NOT NULL,
  PRIMARY KEY (policy_id, model_code)
);

-- Properties that may never change without a human, whatever a policy says
-- (e.g. consolidation parent, reporting currency, anything feeding regulatory reports).
CREATE TABLE wf.stp_protected_property (
  property_id uuid PRIMARY KEY REFERENCES mdm.property_definition,
  reason      text NOT NULL,
  added_by    uuid NOT NULL REFERENCES mdm.app_user,
  added_at    timestamptz NOT NULL DEFAULT now()
);

-- Periods when straight-through commit is suspended (e.g. period close).
CREATE TABLE wf.freeze_window (
  window_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  label         text NOT NULL,
  window_period tstzrange NOT NULL,
  hierarchy_id  uuid REFERENCES mdm.hierarchy,           -- NULL = all hierarchies
  reason        text,
  created_by    uuid NOT NULL REFERENCES mdm.app_user,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON wf.freeze_window USING gist (window_period);

-- Policy lifecycle log. Append-only.
CREATE TABLE wf.policy_event (
  event_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  policy_id   uuid NOT NULL REFERENCES wf.commit_policy,
  actor_id    uuid NOT NULL REFERENCES mdm.app_user,
  event       text NOT NULL CHECK (event IN ('submitted', 'approved', 'returned', 'retired', 'kill_switch_engaged')),
  note        text,
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TRIGGER policy_event_append_only BEFORE UPDATE OR DELETE ON wf.policy_event
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_append_only();

-- Lifecycle guard: content frozen once submitted; approval checked here, not just in
-- the helper function, so a direct UPDATE cannot bypass it; kill switch is one-way.
CREATE FUNCTION wf.trg_policy_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
DECLARE
  meta text[] := ARRAY['status', 'approved_by', 'approved_at', 'approval_note', 'review_due'];
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN
      RAISE EXCEPTION 'Only draft policies can be deleted' USING ERRCODE = 'N2216', HINT = 'policy.delete_not_draft';
    END IF;
    RETURN OLD;
  END IF;

  IF OLD.kill_switch AND NOT NEW.kill_switch THEN
    RAISE EXCEPTION 'A kill switch can only be cleared by approving a new policy version' USING ERRCODE = 'N1019', HINT = 'policy.kill_switch_one_way';
  END IF;

  IF OLD.status = 'draft' THEN
    IF NEW.status NOT IN ('draft', 'pending_approval') THEN
      RAISE EXCEPTION 'A draft policy must be submitted for approval first' USING ERRCODE = 'N2217', HINT = 'policy.submit_first';
    END IF;
    RETURN NEW;
  END IF;

  IF OLD.status = 'pending_approval' THEN
    IF (to_jsonb(OLD) - meta - 'kill_switch') IS DISTINCT FROM (to_jsonb(NEW) - meta - 'kill_switch') THEN
      RAISE EXCEPTION 'Policy content is frozen while pending approval' USING ERRCODE = 'N2218', HINT = 'policy.frozen_pending';
    END IF;
    IF NEW.status = 'approved' THEN
      IF (SELECT kind FROM mdm.app_user WHERE user_id = NEW.approved_by) IS DISTINCT FROM 'human' THEN
        RAISE EXCEPTION 'Policies must be approved by a human' USING ERRCODE = 'N1002', HINT = 'human_only';
      END IF;
      -- OD-08: an active policy commits without a human. Until Audit-Risk signs off, only shadow (or disabled)
      -- policies can be approved; the owner-only setting policy_activation_allowed lifts this (ADR-023).
      IF NEW.mode = 'active' AND NOT mdm.setting_enabled('policy_activation_allowed') THEN
        RAISE EXCEPTION 'Active policies cannot be approved until Audit-Risk has signed off straight-through commit (OD-08)'
          USING ERRCODE = 'N2225', HINT = 'policy.activation_not_allowed';
      END IF;
      IF NEW.approved_by = NEW.proposed_by THEN
        RAISE EXCEPTION 'Maker-checker violation: the proposer cannot approve their own policy' USING ERRCODE = 'N1001', HINT = 'maker_checker.self_decision';
      END IF;
      IF NOT wf.is_member((SELECT group_id FROM wf.user_group WHERE group_code = 'POLICY_APPROVERS'),
                          NEW.approved_by, mdm.business_today()) THEN
        RAISE EXCEPTION 'Approver is not in POLICY_APPROVERS' USING ERRCODE = 'N1020', HINT = 'policy.not_approver';
      END IF;
      IF EXISTS (SELECT 1 FROM wf.policy_scope s1
                 JOIN wf.policy_scope s2 ON s2.model_code = s1.model_code AND s2.policy_id <> s1.policy_id
                 JOIN wf.commit_policy p2 ON p2.policy_id = s2.policy_id
                 WHERE s1.policy_id = NEW.policy_id AND p2.status = 'approved'
                   AND p2.policy_code <> NEW.policy_code) THEN
        RAISE EXCEPTION 'Another approved policy already covers one of these workflow models' USING ERRCODE = 'N2219', HINT = 'policy.overlapping_scope';
      END IF;
    ELSIF NEW.status NOT IN ('pending_approval', 'draft') THEN
      RAISE EXCEPTION 'Invalid status change % -> %', OLD.status, NEW.status USING ERRCODE = 'N2220', HINT = 'policy.status';
    END IF;
    RETURN NEW;
  END IF;

  -- approved or retired: immutable except kill switch (one-way) and approved -> retired
  IF (to_jsonb(OLD) - 'kill_switch' - 'status') IS DISTINCT FROM (to_jsonb(NEW) - 'kill_switch' - 'status') THEN
    RAISE EXCEPTION 'Approved policies are immutable; create a new version' USING ERRCODE = 'N2221', HINT = 'policy.immutable';
  END IF;
  IF OLD.status <> NEW.status AND NOT (OLD.status = 'approved' AND NEW.status = 'retired') THEN
    RAISE EXCEPTION 'Invalid status change % -> %', OLD.status, NEW.status USING ERRCODE = 'N2220', HINT = 'policy.status';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER commit_policy_guard BEFORE UPDATE OR DELETE ON wf.commit_policy
  FOR EACH ROW EXECUTE FUNCTION wf.trg_policy_guard();

CREATE FUNCTION wf.trg_policy_scope_frozen() RETURNS trigger
LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
BEGIN
  IF (SELECT status FROM wf.commit_policy
      WHERE policy_id = COALESCE(NEW.policy_id, OLD.policy_id)) <> 'draft' THEN
    RAISE EXCEPTION 'Policy scope can only change while the policy is a draft' USING ERRCODE = 'N2222', HINT = 'policy.scope_frozen';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
CREATE TRIGGER policy_scope_frozen BEFORE INSERT OR UPDATE OR DELETE ON wf.policy_scope
  FOR EACH ROW EXECUTE FUNCTION wf.trg_policy_scope_frozen();

-- -----------------------------------------------------------------------------
-- Lifecycle helpers
-- -----------------------------------------------------------------------------
CREATE FUNCTION wf.submit_commit_policy(p_policy_id uuid, p_actor uuid)
RETURNS void LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
BEGIN
  UPDATE wf.commit_policy SET status = 'pending_approval'
  WHERE policy_id = p_policy_id AND status = 'draft' AND proposed_by = p_actor;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Only the proposer can submit a draft policy' USING ERRCODE = 'N1022', HINT = 'policy.not_proposer';
  END IF;
  INSERT INTO wf.policy_event (policy_id, actor_id, event) VALUES (p_policy_id, p_actor, 'submitted');
END $$;

CREATE FUNCTION wf.approve_commit_policy(p_policy_id uuid, p_approver uuid, p_note text,
                                         p_review_months int DEFAULT 12)
RETURNS void LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
DECLARE v_code text;
BEGIN
  SELECT policy_code INTO v_code FROM wf.commit_policy
  WHERE policy_id = p_policy_id AND status = 'pending_approval' FOR UPDATE;
  IF v_code IS NULL THEN
    RAISE EXCEPTION 'Policy % is not pending approval', p_policy_id USING ERRCODE = 'N2223', HINT = 'policy.not_pending';
  END IF;

  -- retire the currently approved version of the same policy, if any
  UPDATE wf.commit_policy SET status = 'retired'
  WHERE policy_code = v_code AND status = 'approved' AND policy_id <> p_policy_id;

  UPDATE wf.commit_policy
  SET status = 'approved', approved_by = p_approver, approved_at = now(), approval_note = p_note,
      review_due = (mdm.business_today() + make_interval(months => p_review_months))::date   -- ADR-018 business day
  WHERE policy_id = p_policy_id;

  INSERT INTO wf.policy_event (policy_id, actor_id, event, note) VALUES (p_policy_id, p_approver, 'approved', p_note);
END $$;

-- Any member of the owner group or POLICY_APPROVERS can stop a policy immediately.
CREATE FUNCTION wf.engage_kill_switch(p_policy_code text, p_actor uuid, p_reason text)
RETURNS void LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
DECLARE v_policy uuid;
BEGIN
  SELECT p.policy_id INTO v_policy
  FROM wf.commit_policy p
  WHERE p.policy_code = p_policy_code AND p.status = 'approved'
    -- D-15: membership on the business day, start date included (this check used to ignore valid_from)
    AND (wf.is_member(p.owner_group_id, p_actor, mdm.business_today())
         OR wf.is_member((SELECT group_id FROM wf.user_group WHERE group_code = 'POLICY_APPROVERS'),
                         p_actor, mdm.business_today()));
  IF v_policy IS NULL THEN
    RAISE EXCEPTION 'No approved policy % that user % may stop', p_policy_code, p_actor USING ERRCODE = 'N1023', HINT = 'policy.kill_switch_not_allowed';
  END IF;
  UPDATE wf.commit_policy SET kill_switch = true WHERE policy_id = v_policy;
  INSERT INTO wf.policy_event (policy_id, actor_id, event, note)
  VALUES (v_policy, p_actor, 'kill_switch_engaged', p_reason);
  INSERT INTO wf.event_outbox (event_type, payload)
  VALUES ('kill_switch_engaged', jsonb_build_object('policy_code', p_policy_code, 'actor_id', p_actor, 'reason', p_reason));
END $$;

-- -----------------------------------------------------------------------------
-- Evaluation
-- -----------------------------------------------------------------------------
CREATE TABLE wf.policy_evaluation (
  evaluation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  instance_id   uuid NOT NULL REFERENCES wf.workflow_instance,
  policy_id     uuid REFERENCES wf.commit_policy,      -- NULL when no policy covers the model
  policy_mode   wf.policy_mode,
  eligible      boolean NOT NULL,
  outcome       wf.policy_outcome NOT NULL,
  failed_checks text[] NOT NULL DEFAULT '{}',          -- every reason, not just the first
  validated_at  timestamptz,
  evaluated_at  timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ON wf.policy_evaluation (policy_id, evaluated_at);
CREATE TRIGGER policy_evaluation_append_only BEFORE UPDATE OR DELETE ON wf.policy_evaluation
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_append_only();

-- Runs every check and returns all failures. p_validated_at = start time of the
-- full validation run the engine performed immediately before calling this.
CREATE FUNCTION wf.evaluate_commit_policy(p_instance_id uuid, p_validated_at timestamptz)
RETURNS TABLE (policy_id uuid, policy_mode wf.policy_mode, eligible boolean, failed_checks text[])
LANGUAGE plpgsql STABLE SET search_path = wf, mdm, public AS $$
DECLARE
  i       wf.workflow_instance%ROWTYPE;
  cr      mdm.change_request%ROWTYPE;
  m       wf.workflow_model%ROWTYPE;
  p       wf.commit_policy%ROWTYPE;
  f       text[] := '{}';
  n_items int;
BEGIN
  SELECT * INTO i  FROM wf.workflow_instance WHERE instance_id = p_instance_id;
  SELECT * INTO cr FROM mdm.change_request   WHERE change_request_id = i.change_request_id;
  SELECT * INTO m  FROM wf.workflow_model     WHERE model_id = i.model_id;

  SELECT cp.* INTO p
  FROM wf.commit_policy cp
  JOIN wf.policy_scope ps ON ps.policy_id = cp.policy_id
  WHERE cp.status = 'approved' AND ps.model_code = m.model_code
  LIMIT 1;

  IF NOT FOUND THEN
    policy_id := NULL; policy_mode := NULL; eligible := false;
    failed_checks := ARRAY['no approved policy covers this workflow model'];
    RETURN NEXT; RETURN;
  END IF;
  policy_id := p.policy_id; policy_mode := p.mode;

  -- policy state
  IF p.mode = 'disabled' THEN f := array_append(f, 'policy is disabled'); END IF;
  IF p.kill_switch THEN f := array_append(f, 'kill switch engaged'); END IF;
  IF p.review_due < mdm.business_today() THEN f := array_append(f, 'policy re-certification overdue'); END IF;

  -- request
  IF i.status <> 'in_flight' THEN f := array_append(f, 'request is not in flight'); END IF;
  IF cr.requester_kind = 'ai_agent' THEN f := array_append(f, 'AI-originated request'); END IF;
  IF EXISTS (SELECT 1 FROM wf.instance_action a
             WHERE a.instance_id = p_instance_id AND a.actor_kind = 'ai_agent'
               AND a.action IN ('submit', 'enrich')) THEN
    f := array_append(f, 'AI contributed request content');
  END IF;
  IF cr.risk_tier <> 'low' THEN f := array_append(f, format('risk tier is %s', cr.risk_tier)); END IF;

  -- items
  SELECT count(*) INTO n_items FROM wf.instance_item ii WHERE ii.instance_id = p_instance_id;
  IF n_items = 0 THEN f := array_append(f, 'request has no items'); END IF;
  IF n_items > p.max_items_per_request THEN
    f := array_append(f, format('%s items exceeds the limit of %s', n_items, p.max_items_per_request));
  END IF;
  IF EXISTS (SELECT 1 FROM wf.instance_item ii JOIN mdm.change_item ci ON ci.change_item_id = ii.change_item_id
             WHERE ii.instance_id = p_instance_id AND NOT (ci.action = ANY (p.allowed_actions))) THEN
    f := array_append(f, 'contains an action the policy does not allow');
  END IF;
  IF EXISTS (SELECT 1 FROM wf.instance_item ii JOIN mdm.change_item ci ON ci.change_item_id = ii.change_item_id
             JOIN wf.stp_protected_property pp ON pp.property_id = ci.property_id
             WHERE ii.instance_id = p_instance_id) THEN
    f := array_append(f, 'changes a protected property');
  END IF;
  IF p.item_conditions IS NOT NULL AND EXISTS (
       SELECT 1 FROM wf.instance_item ii
       WHERE ii.instance_id = p_instance_id
         AND NOT wf.item_condition_matches(ii.change_item_id, p.item_conditions)) THEN
    f := array_append(f, 'an item does not meet the policy conditions');
  END IF;

  -- validation
  IF p_validated_at IS NULL OR p_validated_at < i.submitted_at THEN
    f := array_append(f, 'validations have not run since submission');
  ELSIF EXISTS (SELECT 1 FROM mdm.validation_result vr
                WHERE vr.change_request_id = cr.change_request_id
                  AND vr.severity = 'error' AND vr.evaluated_at >= p_validated_at) THEN
    f := array_append(f, 'blocking validation errors');
  END IF;

  -- workflow shape: no human stage may still be open
  IF EXISTS (SELECT 1 FROM wf.instance_stage ist JOIN wf.workflow_stage ws ON ws.stage_id = ist.stage_id
             WHERE ist.instance_id = p_instance_id AND ws.stage_type IN ('enrich', 'approve')
               AND ist.included IS DISTINCT FROM false AND ist.status <> 'completed') THEN
    f := array_append(f, 'enrich or approve stages are still open');
  END IF;

  -- context
  IF EXISTS (SELECT 1 FROM wf.freeze_window fw
             WHERE fw.window_period @> now()
               AND (fw.hierarchy_id IS NULL OR fw.hierarchy_id IN (
                     SELECT ci.hierarchy_id FROM wf.instance_item ii
                     JOIN mdm.change_item ci ON ci.change_item_id = ii.change_item_id
                     WHERE ii.instance_id = p_instance_id))) THEN
    f := array_append(f, 'freeze window in effect');
  END IF;
  IF (SELECT count(*) FROM wf.policy_evaluation pe
      WHERE pe.policy_id = p.policy_id AND pe.outcome = 'auto_committed'
        AND pe.evaluated_at >= mdm.business_day_start(mdm.business_today())) >= p.max_auto_commits_per_day THEN   -- business day (ADR-018)
    f := array_append(f, 'daily auto-commit limit reached');
  END IF;

  eligible := cardinality(f) = 0;
  failed_checks := f;
  RETURN NEXT;
END $$;

-- Evaluate, record, and (in active mode, when eligible) commit. Otherwise the request
-- stays with its human Commit stage. The engine calls this right after validation.
CREATE FUNCTION wf.apply_commit_policy(p_instance_id uuid, p_validated_at timestamptz, p_system_actor uuid)
RETURNS wf.policy_outcome LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
DECLARE
  e              record;
  v_outcome      wf.policy_outcome;
  v_eval         uuid;
  v_commit_stage uuid;
BEGIN
  IF (SELECT kind FROM mdm.app_user WHERE user_id = p_system_actor) IS DISTINCT FROM 'system_feed' THEN
    RAISE EXCEPTION 'Policy commits must be recorded by a system actor' USING ERRCODE = 'N1024', HINT = 'policy.system_actor_required';
  END IF;
  PERFORM 1 FROM wf.workflow_instance WHERE instance_id = p_instance_id FOR UPDATE;

  SELECT * INTO e FROM wf.evaluate_commit_policy(p_instance_id, p_validated_at);
  v_outcome := CASE
    WHEN e.policy_mode = 'shadow' AND e.eligible THEN 'shadow_would_commit'
    WHEN e.policy_mode = 'shadow'                THEN 'shadow_would_route'
    WHEN e.policy_mode = 'active' AND e.eligible THEN 'auto_committed'
    ELSE 'routed_to_human'
  END;

  INSERT INTO wf.policy_evaluation (instance_id, policy_id, policy_mode, eligible, outcome, failed_checks, validated_at)
  VALUES (p_instance_id, e.policy_id, e.policy_mode, e.eligible, v_outcome, e.failed_checks, p_validated_at)
  RETURNING evaluation_id INTO v_eval;

  IF v_outcome = 'auto_committed' THEN
    SELECT ist.instance_stage_id INTO v_commit_stage
    FROM wf.instance_stage ist JOIN wf.workflow_stage ws ON ws.stage_id = ist.stage_id
    WHERE ist.instance_id = p_instance_id AND ws.stage_type = 'commit'
    ORDER BY ist.iteration DESC LIMIT 1;

    UPDATE wf.instance_stage
    SET status = 'completed', started_at = coalesce(started_at, now()), completed_at = now()
    WHERE instance_stage_id = v_commit_stage;

    -- the action must exist before the instance closes, so the bridge sees the policy basis
    INSERT INTO wf.instance_action (instance_id, instance_stage_id, actor_id, actor_kind, action, comment, payload)
    VALUES (p_instance_id, v_commit_stage, p_system_actor, 'system_feed', 'commit',
            'Committed under approved commit policy',
            jsonb_build_object('policy_id', e.policy_id, 'policy_evaluation_id', v_eval));

    UPDATE wf.workflow_instance SET status = 'committed', closed_at = now() WHERE instance_id = p_instance_id;

    INSERT INTO wf.event_outbox (event_type, instance_id, payload)
    VALUES ('instance_closed', p_instance_id,
            jsonb_build_object('outcome', 'committed', 'basis', 'approved_policy',
                               'policy_id', e.policy_id, 'policy_evaluation_id', v_eval));
  ELSE
    INSERT INTO wf.event_outbox (event_type, instance_id, payload)
    VALUES ('policy_evaluated', p_instance_id,
            jsonb_build_object('outcome', v_outcome, 'failed_checks', to_jsonb(e.failed_checks)));
  END IF;

  RETURN v_outcome;
END $$;

-- Extends the history guard from 04: the system actor may commit only with a matching,
-- unused 'auto_committed' evaluation for the same instance and policy.
CREATE OR REPLACE FUNCTION wf.trg_action_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
DECLARE k mdm.requester_kind;
BEGIN
  SELECT kind INTO k FROM mdm.app_user WHERE user_id = NEW.actor_id;
  IF k IS DISTINCT FROM NEW.actor_kind THEN
    RAISE EXCEPTION 'actor_kind % does not match the user record (%)', NEW.actor_kind, k USING ERRCODE = 'N1017', HINT = 'wf.actor_kind_mismatch';
  END IF;

  IF NEW.action IN ('claim', 'approve', 'reject', 'push_back', 'commit') AND k <> 'human' THEN
    IF NOT (NEW.action = 'commit' AND k = 'system_feed'
            AND EXISTS (SELECT 1 FROM wf.policy_evaluation pe
                        WHERE pe.evaluation_id = (NEW.payload->>'policy_evaluation_id')::uuid
                          AND pe.instance_id   = NEW.instance_id
                          AND pe.policy_id     = (NEW.payload->>'policy_id')::uuid
                          AND pe.outcome       = 'auto_committed')
            AND NOT EXISTS (SELECT 1 FROM wf.instance_action a
                            WHERE a.action = 'commit'
                              AND a.payload->>'policy_evaluation_id' = NEW.payload->>'policy_evaluation_id')) THEN
      RAISE EXCEPTION 'Action % can only be performed by a human (or by the system under an approved commit policy)',
        NEW.action USING ERRCODE = 'N1002', HINT = 'human_only';
    END IF;
  END IF;

  IF k = 'ai_agent' AND (NEW.ai_model IS NULL OR NEW.ai_confidence IS NULL) THEN
    RAISE EXCEPTION 'AI actions must record ai_model and ai_confidence' USING ERRCODE = 'N1018', HINT = 'ai.model_required';
  END IF;
  RETURN NEW;
END $$;

-- -----------------------------------------------------------------------------
-- Shadow mode: compare what the policy would have done with what humans did
-- -----------------------------------------------------------------------------
CREATE VIEW wf.v_shadow_comparison AS
SELECT pe.evaluation_id, cp.policy_code, cp.policy_version, pe.instance_id,
       pe.outcome AS shadow_outcome, pe.failed_checks, i.status AS final_status,
       pb.pushed_back,
       CASE
         WHEN i.status IN ('draft', 'in_flight', 'pushed_back') THEN 'pending'
         -- policy would have committed, but a human rejected or pushed back: policy too loose
         WHEN pe.outcome = 'shadow_would_commit' AND (i.status <> 'committed' OR pb.pushed_back) THEN 'policy_too_loose'
         -- policy would have routed, and the human passed it cleanly: candidate to widen
         WHEN pe.outcome = 'shadow_would_route' AND i.status = 'committed' AND NOT pb.pushed_back THEN 'policy_may_be_too_strict'
         ELSE 'agree'
       END AS comparison
FROM wf.policy_evaluation pe
JOIN wf.commit_policy cp    ON cp.policy_id = pe.policy_id
JOIN wf.workflow_instance i ON i.instance_id = pe.instance_id
CROSS JOIN LATERAL (
  SELECT EXISTS (SELECT 1 FROM wf.instance_action a
                 WHERE a.instance_id = pe.instance_id AND a.action = 'push_back') AS pushed_back
) pb
WHERE pe.outcome IN ('shadow_would_commit', 'shadow_would_route');

-- The evidence pack for Audit before switching a policy from shadow to active.
CREATE VIEW wf.v_shadow_summary AS
SELECT policy_code, policy_version,
       count(*) FILTER (WHERE comparison <> 'pending')                 AS decided_requests,
       count(*) FILTER (WHERE shadow_outcome = 'shadow_would_commit')  AS would_auto_commit,
       count(*) FILTER (WHERE comparison = 'policy_too_loose')         AS too_loose,
       count(*) FILTER (WHERE comparison = 'policy_may_be_too_strict') AS possibly_too_strict,
       round(100.0 * count(*) FILTER (WHERE comparison = 'policy_too_loose')
             / nullif(count(*) FILTER (WHERE shadow_outcome = 'shadow_would_commit'
                                         AND comparison <> 'pending'), 0), 2) AS too_loose_pct
FROM wf.v_shadow_comparison
GROUP BY policy_code, policy_version;

-- -----------------------------------------------------------------------------
-- Detective control: sample auto-commits for human review
-- -----------------------------------------------------------------------------
CREATE TABLE wf.post_commit_review (
  review_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  evaluation_id uuid NOT NULL UNIQUE REFERENCES wf.policy_evaluation,
  sampled_at    timestamptz NOT NULL DEFAULT now(),
  reviewer_id   uuid REFERENCES mdm.app_user,
  reviewed_at   timestamptz,
  outcome       text CHECK (outcome IN ('ok', 'issue')),
  notes         text,
  CHECK ((outcome IS NULL) = (reviewed_at IS NULL)),
  CHECK (outcome IS NULL OR reviewer_id IS NOT NULL)
);

CREATE FUNCTION wf.trg_review_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
BEGIN
  IF NEW.reviewer_id IS NOT NULL
     AND (SELECT kind FROM mdm.app_user WHERE user_id = NEW.reviewer_id) IS DISTINCT FROM 'human' THEN
    RAISE EXCEPTION 'Post-commit reviews must be done by a human' USING ERRCODE = 'N1002', HINT = 'human_only';
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.outcome IS NOT NULL THEN
    RAISE EXCEPTION 'Completed reviews cannot be changed' USING ERRCODE = 'N2224', HINT = 'policy.review_frozen';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER post_commit_review_guard BEFORE INSERT OR UPDATE ON wf.post_commit_review
  FOR EACH ROW EXECUTE FUNCTION wf.trg_review_guard();

-- Random sample of a business day's auto-commits (at least one when any exist). Returns rows added.
CREATE FUNCTION wf.sample_auto_commits(p_policy_code text, p_day date, p_pct numeric DEFAULT 5)
RETURNS int LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
DECLARE n int;
BEGIN
  INSERT INTO wf.post_commit_review (evaluation_id)
  SELECT pe.evaluation_id
  FROM wf.policy_evaluation pe
  JOIN wf.commit_policy cp ON cp.policy_id = pe.policy_id
  WHERE cp.policy_code = p_policy_code AND pe.outcome = 'auto_committed'
    AND pe.evaluated_at >= mdm.business_day_start(p_day) AND pe.evaluated_at < mdm.business_day_start(p_day + 1)
    AND NOT EXISTS (SELECT 1 FROM wf.post_commit_review r WHERE r.evaluation_id = pe.evaluation_id)
  ORDER BY random()
  LIMIT (SELECT greatest(1, ceil(count(*) * p_pct / 100.0))::int
         FROM wf.policy_evaluation pe2
         JOIN wf.commit_policy cp2 ON cp2.policy_id = pe2.policy_id
         WHERE cp2.policy_code = p_policy_code AND pe2.outcome = 'auto_committed'
           AND pe2.evaluated_at >= mdm.business_day_start(p_day) AND pe2.evaluated_at < mdm.business_day_start(p_day + 1));
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- Daily monitoring: volumes by outcome and review results per policy.
CREATE VIEW wf.v_commit_policy_daily AS
SELECT cp.policy_code, cp.policy_version, mdm.business_date_of(pe.evaluated_at) AS day,   -- business day (ADR-018)
       count(*) FILTER (WHERE pe.outcome = 'auto_committed')       AS auto_committed,
       count(*) FILTER (WHERE pe.outcome = 'routed_to_human')      AS routed_to_human,
       count(*) FILTER (WHERE pe.outcome = 'shadow_would_commit')  AS shadow_would_commit,
       count(*) FILTER (WHERE pe.outcome = 'shadow_would_route')   AS shadow_would_route,
       count(r.review_id)                                          AS sampled,
       count(r.review_id) FILTER (WHERE r.outcome = 'issue')       AS review_issues,
       count(r.review_id) FILTER (WHERE r.outcome IS NULL)         AS reviews_outstanding
FROM wf.policy_evaluation pe
JOIN wf.commit_policy cp ON cp.policy_id = pe.policy_id
LEFT JOIN wf.post_commit_review r ON r.evaluation_id = pe.evaluation_id
GROUP BY cp.policy_code, cp.policy_version, mdm.business_date_of(pe.evaluated_at);
