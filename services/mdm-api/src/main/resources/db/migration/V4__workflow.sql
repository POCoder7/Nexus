-- =============================================================================
-- AI-enabled MDM — 04: WORKFLOW LAYER (DRG equivalent), schema "wf"
--
-- Separation rules
--   * mdm never references wf. The core data model works without this layer.
--   * wf reads mdm (ids, users, properties, validation results, hierarchy_tree)
--     but never writes to it. Writing back is the job of the bridge
--     (05_wf_mdm_bridge.sql), which can be dropped or replaced on its own.
--   * The database holds configuration, state and invariants (who may act,
--     separation of duties, human-only decisions, history). Timers, escalations
--     and notifications run in an orchestration engine (e.g. Temporal or Camunda)
--     that reads and writes these tables and consumes wf.event_outbox.
--
-- DRG concept                         -> wf object
-- ------------------------------------------------------------------------------
-- Workflow model (+ model filters)    -> workflow_model (versioned) + model_scope
-- Workflow task                       -> workflow_task + task_property + task_validation
-- Submit / Enrich / Approve / Commit  -> workflow_stage.stage_type
-- Submit stage allowable tasks        -> submit_task
-- Approval groups, workflow method    -> user_group, stage_group, approval_method
-- Node access groups                  -> stage_access_scope
-- Separation of Duties                -> workflow_stage.separation_of_duties + sod_violation()
-- Re-approval after push-back         -> workflow_stage.reapproval + instance_stage.iteration
-- Conditional stages / split requests -> workflow_stage.condition + split_instance()
-- Claim / unclaim, claim duration     -> instance_stage.claimed_by / claim_expires_at
-- Request / stage durations (SLA)     -> request_duration, stage_duration, v_sla_status
-- Notifications                       -> workflow_stage.notify + event_outbox
-- Request history                     -> instance_action (append-only)
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS wf;
SET search_path = wf, mdm, public;

CREATE TYPE wf.stage_type      AS ENUM ('submit', 'enrich', 'approve', 'commit');
CREATE TYPE wf.approval_method AS ENUM ('any_group', 'all_groups', 'sequential_groups');
CREATE TYPE wf.reapproval_mode AS ENUM ('current_stage', 'all_subsequent');
CREATE TYPE wf.notify_mode     AS ENUM ('none', 'assignees', 'submitter', 'assignees_and_submitter');
CREATE TYPE wf.instance_status AS ENUM ('draft', 'in_flight', 'pushed_back', 'committed', 'rejected', 'withdrawn');
CREATE TYPE wf.stage_status    AS ENUM ('pending', 'active', 'claimed', 'completed', 'skipped', 'rejected');
CREATE TYPE wf.wf_action       AS ENUM (
  'submit', 'claim', 'unclaim', 'reassign', 'enrich', 'approve', 'reject', 'push_back',
  'commit', 'withdraw', 'comment', 'escalate', 'split', 'condition_evaluated',
  'sla_breached', 'ai_suggestion'
);

-- =============================================================================
-- CONFIGURATION
-- =============================================================================
CREATE TABLE wf.user_group (
  group_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_code  text NOT NULL UNIQUE,
  name        text NOT NULL,
  description text,
  is_active   boolean NOT NULL DEFAULT true
);

-- Group membership decides who may approve requests and policies, so its history must be reconstructable (D-33):
-- bitemporal like the core facts, by business date (ADR-018). Rows are never updated or deleted; a membership ends by
-- closing its recorded_period and re-stating the period it was true. Changes go through governed membership changes
-- (V9, CR-10); only the owner writes directly (bootstrap, tests).
CREATE TABLE wf.user_group_member (
  group_id        uuid NOT NULL REFERENCES wf.user_group,
  user_id         uuid NOT NULL REFERENCES mdm.app_user,
  valid_period    daterange NOT NULL DEFAULT daterange(mdm.business_today(), NULL),
  recorded_period tstzrange NOT NULL DEFAULT tstzrange(now(), NULL),
  granted_by      uuid REFERENCES mdm.app_user,
  change_id       uuid,                                 -- the governed change that wrote the row (V9); NULL for bootstrap rows
  EXCLUDE USING gist (group_id WITH =, user_id WITH =, valid_period WITH &&) WHERE (upper_inf(recorded_period))
);
CREATE INDEX ON wf.user_group_member (user_id) WHERE upper_inf(recorded_period);
CREATE TRIGGER user_group_member_guard BEFORE UPDATE OR DELETE ON wf.user_group_member
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_bitemporal_guard();   -- raises only; writes nothing in mdm

-- The one membership test (D-15): every check of who belongs to a group uses it, on the business day it concerns.
CREATE FUNCTION wf.is_member(p_group uuid, p_user uuid, p_on date)
RETURNS boolean LANGUAGE sql STABLE SET search_path = wf, mdm, public AS $$
  SELECT EXISTS (SELECT 1 FROM wf.user_group_member m
                 WHERE m.group_id = p_group AND m.user_id = p_user
                   AND m.valid_period @> p_on AND upper_inf(m.recorded_period))
$$;

-- What a participant may do in a stage: allowed actions and editable properties.
CREATE TABLE wf.workflow_task (
  task_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_code       text NOT NULL UNIQUE,
  label           text NOT NULL,
  instructions    text,
  allowed_actions mdm.change_action[] NOT NULL DEFAULT '{}',
  is_active       boolean NOT NULL DEFAULT true
);

CREATE TABLE wf.task_property (
  task_id      uuid NOT NULL REFERENCES wf.workflow_task ON DELETE CASCADE,
  property_id  uuid NOT NULL REFERENCES mdm.property_definition,
  is_required  boolean NOT NULL DEFAULT false,
  is_read_only boolean NOT NULL DEFAULT false,
  sort_seq     int,
  PRIMARY KEY (task_id, property_id),
  CHECK (NOT (is_required AND is_read_only))
);

CREATE TABLE wf.task_validation (
  task_id  uuid NOT NULL REFERENCES wf.workflow_task ON DELETE CASCADE,
  rule_id  uuid NOT NULL REFERENCES mdm.validation_rule,
  blocking boolean NOT NULL DEFAULT true,     -- false = warning only
  PRIMARY KEY (task_id, rule_id)
);

-- Models are versioned. In-flight requests stay on the version they started with.
CREATE TABLE wf.workflow_model (
  model_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  model_code       text NOT NULL,
  model_version    int  NOT NULL DEFAULT 1,
  label            text NOT NULL,
  description      text,
  request_duration interval,                  -- request-level SLA
  status           text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'active', 'retired')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid REFERENCES mdm.app_user,
  UNIQUE (model_code, model_version)
);
CREATE UNIQUE INDEX workflow_model_one_active ON wf.workflow_model (model_code) WHERE status = 'active';

-- DRG model filters: which hierarchies / sub-trees / node kinds a model governs.
CREATE TABLE wf.model_scope (
  scope_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  model_id     uuid NOT NULL REFERENCES wf.workflow_model ON DELETE CASCADE,
  hierarchy_id uuid REFERENCES mdm.hierarchy,
  top_node_id  uuid REFERENCES mdm.node,
  node_kind    mdm.node_kind,
  node_filter  jsonb NOT NULL DEFAULT '[]'     -- same format as mdm.export_profile.node_filter
);

CREATE TABLE wf.workflow_stage (
  stage_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  model_id             uuid NOT NULL REFERENCES wf.workflow_model ON DELETE CASCADE,
  seq                  int  NOT NULL,
  stage_type           wf.stage_type NOT NULL,
  label                text NOT NULL,
  task_id              uuid REFERENCES wf.workflow_task,   -- one task for enrich/approve; none for submit/commit
  approval_method      wf.approval_method NOT NULL DEFAULT 'any_group',
  separation_of_duties boolean NOT NULL DEFAULT false,
  reapproval           wf.reapproval_mode NOT NULL DEFAULT 'all_subsequent',
  notify               wf.notify_mode NOT NULL DEFAULT 'assignees',
  claim_duration       interval,
  stage_duration       interval,
  -- NULL = always included. Otherwise e.g.
  --   {"type":"property","property":"Custom.AllowBudgeting","op":"=","value":true}
  --   {"type":"validation_failed","rule_code":"OWN_SUM_LE_100"}
  --   {"type":"any"|"all","conditions":[ ... ]}
  condition            jsonb,
  split_on_condition   boolean NOT NULL DEFAULT false,      -- matching items move to their own request
  ai_assist            boolean NOT NULL DEFAULT true,       -- AI may pre-fill and suggest, never decide
  UNIQUE (model_id, seq),
  CHECK ((stage_type IN ('enrich', 'approve')) = (task_id IS NOT NULL)),
  CHECK (stage_type <> 'submit' OR (seq = 1 AND condition IS NULL)),
  CHECK (stage_type <> 'commit' OR condition IS NULL),
  CHECK (condition IS NOT NULL OR NOT split_on_condition)
);
CREATE UNIQUE INDEX workflow_stage_one_submit ON wf.workflow_stage (model_id) WHERE stage_type = 'submit';
CREATE UNIQUE INDEX workflow_stage_one_commit ON wf.workflow_stage (model_id) WHERE stage_type = 'commit';

CREATE TABLE wf.submit_task (
  model_id uuid NOT NULL REFERENCES wf.workflow_model ON DELETE CASCADE,
  task_id  uuid NOT NULL REFERENCES wf.workflow_task,
  PRIMARY KEY (model_id, task_id)
);

CREATE TABLE wf.stage_group (
  stage_id uuid NOT NULL REFERENCES wf.workflow_stage ON DELETE CASCADE,
  group_id uuid NOT NULL REFERENCES wf.user_group,
  seq      int  NOT NULL DEFAULT 1,           -- order for sequential_groups
  PRIMARY KEY (stage_id, group_id)
);

-- DRG node access: participants may only act on items under these sub-trees.
CREATE TABLE wf.stage_access_scope (
  stage_id     uuid NOT NULL REFERENCES wf.workflow_stage ON DELETE CASCADE,
  hierarchy_id uuid NOT NULL REFERENCES mdm.hierarchy,
  top_node_id  uuid NOT NULL REFERENCES mdm.node,
  PRIMARY KEY (stage_id, hierarchy_id, top_node_id)
);

-- Model checks, run when a model is activated.
CREATE FUNCTION wf.validate_model(p_model_id uuid)
RETURNS TABLE (issue text) LANGUAGE sql STABLE SET search_path = wf, mdm, public AS $$
  SELECT 'Model needs exactly one submit stage'::text
  WHERE (SELECT count(*) FROM wf.workflow_stage WHERE model_id = p_model_id AND stage_type = 'submit') <> 1
  UNION ALL
  SELECT 'Model needs exactly one commit stage'
  WHERE (SELECT count(*) FROM wf.workflow_stage WHERE model_id = p_model_id AND stage_type = 'commit') <> 1
  UNION ALL
  SELECT 'Commit must be the last stage'
  WHERE (SELECT seq FROM wf.workflow_stage WHERE model_id = p_model_id AND stage_type = 'commit')
        IS DISTINCT FROM (SELECT max(seq) FROM wf.workflow_stage WHERE model_id = p_model_id)
  UNION ALL
  SELECT 'Submit stage needs at least one allowed task'
  WHERE NOT EXISTS (SELECT 1 FROM wf.submit_task WHERE model_id = p_model_id)
  UNION ALL
  SELECT format('Stage "%s" has no participating groups', s.label)
  FROM wf.workflow_stage s
  WHERE s.model_id = p_model_id AND s.stage_type <> 'submit'
    AND NOT EXISTS (SELECT 1 FROM wf.stage_group g WHERE g.stage_id = s.stage_id)
$$;

CREATE FUNCTION wf.trg_model_status() RETURNS trigger
LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
DECLARE issues text;
BEGIN
  IF OLD.status = NEW.status THEN
    IF OLD.status <> 'draft' THEN
      RAISE EXCEPTION 'Model % v% is %; create a new version to change it', NEW.model_code, NEW.model_version, NEW.status USING ERRCODE = 'N2205', HINT = 'wf.model_frozen';
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.status = 'draft' AND NEW.status = 'active' THEN
    SELECT string_agg(issue, '; ') INTO issues FROM wf.validate_model(NEW.model_id);
    IF issues IS NOT NULL THEN
      RAISE EXCEPTION 'Model % cannot be activated: %', NEW.model_code, issues USING ERRCODE = 'N2206', HINT = 'wf.model_invalid';
    END IF;
  ELSIF NOT (OLD.status = 'active' AND NEW.status = 'retired') THEN
    RAISE EXCEPTION 'Invalid model status change % -> %', OLD.status, NEW.status USING ERRCODE = 'N2207', HINT = 'wf.model_status';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER workflow_model_status BEFORE UPDATE ON wf.workflow_model
  FOR EACH ROW EXECUTE FUNCTION wf.trg_model_status();

-- Stages and their children are frozen once the model leaves draft.
CREATE FUNCTION wf.trg_model_frozen() RETURNS trigger
LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
DECLARE
  v_stage uuid;
  v_model uuid;
  v_status text;
BEGIN
  IF TG_TABLE_NAME IN ('workflow_stage', 'submit_task', 'model_scope') THEN
    v_model := CASE WHEN TG_OP = 'DELETE' THEN (to_jsonb(OLD)->>'model_id')::uuid
                    ELSE (to_jsonb(NEW)->>'model_id')::uuid END;
  ELSE
    v_stage := CASE WHEN TG_OP = 'DELETE' THEN (to_jsonb(OLD)->>'stage_id')::uuid
                    ELSE (to_jsonb(NEW)->>'stage_id')::uuid END;
    SELECT model_id INTO v_model FROM wf.workflow_stage WHERE stage_id = v_stage;
  END IF;
  SELECT status INTO v_status FROM wf.workflow_model WHERE model_id = v_model;
  IF v_status <> 'draft' THEN
    RAISE EXCEPTION 'Model is %; create a new model version to change it', v_status USING ERRCODE = 'N2205', HINT = 'wf.model_frozen';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['workflow_stage', 'submit_task', 'model_scope', 'stage_group', 'stage_access_scope'] LOOP
    EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE OR DELETE ON wf.%I
                    FOR EACH ROW EXECUTE FUNCTION wf.trg_model_frozen()', t || '_frozen', t);
  END LOOP;
END $$;

-- =============================================================================
-- RUNTIME STATE
-- =============================================================================
CREATE TABLE wf.workflow_instance (
  instance_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  change_request_id  uuid NOT NULL REFERENCES mdm.change_request,
  model_id           uuid NOT NULL REFERENCES wf.workflow_model,   -- pinned model version
  parent_instance_id uuid REFERENCES wf.workflow_instance,         -- set when created by a conditional split
  status             wf.instance_status NOT NULL DEFAULT 'draft',
  current_seq        int,
  submitted_by       uuid REFERENCES mdm.app_user,
  submitted_at       timestamptz,
  due_at             timestamptz,
  closed_at          timestamptz,
  engine_ref         text                                           -- id in the orchestration engine
);
CREATE UNIQUE INDEX workflow_instance_one_root ON wf.workflow_instance (change_request_id)
  WHERE parent_instance_id IS NULL;

-- Each change item belongs to exactly one instance; splitting moves items between instances.
CREATE TABLE wf.instance_item (
  change_item_id uuid PRIMARY KEY REFERENCES mdm.change_item,
  instance_id    uuid NOT NULL REFERENCES wf.workflow_instance
);
CREATE INDEX ON wf.instance_item (instance_id);

CREATE TABLE wf.instance_stage (
  instance_stage_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  instance_id       uuid NOT NULL REFERENCES wf.workflow_instance,
  stage_id          uuid NOT NULL REFERENCES wf.workflow_stage,
  seq               int  NOT NULL,
  iteration         int  NOT NULL DEFAULT 1,    -- increments when re-approval is required after push-back
  status            wf.stage_status NOT NULL DEFAULT 'pending',
  included          boolean,                    -- condition result; NULL = not yet evaluated
  claimed_by        uuid REFERENCES mdm.app_user,
  claimed_at        timestamptz,
  claim_expires_at  timestamptz,
  started_at        timestamptz,
  due_at            timestamptz,
  completed_at      timestamptz,
  UNIQUE (instance_id, stage_id, iteration)
);

-- One decision per participating group per stage iteration. For enrich stages,
-- 'approve' means "enrichment complete".
CREATE TABLE wf.stage_group_decision (
  instance_stage_id uuid NOT NULL REFERENCES wf.instance_stage,
  group_id          uuid NOT NULL REFERENCES wf.user_group,
  decided_by        uuid NOT NULL REFERENCES mdm.app_user,
  decision          text NOT NULL CHECK (decision IN ('approve', 'reject', 'push_back')),
  comment           text,
  decided_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (instance_stage_id, group_id)
);

-- Full request history (DRG request audit). Append-only.
CREATE TABLE wf.instance_action (
  action_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  instance_id       uuid NOT NULL REFERENCES wf.workflow_instance,
  instance_stage_id uuid REFERENCES wf.instance_stage,
  actor_id          uuid NOT NULL REFERENCES mdm.app_user,
  actor_kind        mdm.requester_kind NOT NULL,
  action            wf.wf_action NOT NULL,
  comment           text,
  payload           jsonb NOT NULL DEFAULT '{}',
  ai_model          text,
  ai_confidence     numeric(5,4) CHECK (ai_confidence BETWEEN 0 AND 1),
  occurred_at       timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ON wf.instance_action (instance_id, occurred_at);

-- Integration and notification events for the engine, notifier and bridge.
CREATE TABLE wf.event_outbox (
  event_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_type   text NOT NULL,       -- instance_started, stage_status_changed, instance_split, instance_closed
  instance_id  uuid REFERENCES wf.workflow_instance,
  payload      jsonb NOT NULL DEFAULT '{}',
  created_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
  processed_at timestamptz
);
CREATE INDEX ON wf.event_outbox (created_at) WHERE processed_at IS NULL;

-- =============================================================================
-- INVARIANTS (enforced in the database whatever the engine does)
-- =============================================================================

-- Separation of duties: on a stage with SoD enabled, nobody who submitted or
-- approved another stage of this request (including split parents) may act.
CREATE FUNCTION wf.sod_violation(p_instance_stage_id uuid, p_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path = wf, mdm, public AS $$
WITH RECURSIVE
me AS (
  SELECT ist.instance_id, ist.stage_id, ws.separation_of_duties
  FROM wf.instance_stage ist
  JOIN wf.workflow_stage ws ON ws.stage_id = ist.stage_id
  WHERE ist.instance_stage_id = p_instance_stage_id
),
lineage(instance_id) AS (
  SELECT instance_id FROM me
  UNION
  SELECT i.parent_instance_id
  FROM wf.workflow_instance i
  JOIN lineage l ON l.instance_id = i.instance_id
  WHERE i.parent_instance_id IS NOT NULL
)
SELECT coalesce((SELECT separation_of_duties FROM me), false)
   AND (
     EXISTS (SELECT 1
             FROM wf.instance_action a
             JOIN wf.instance_stage s ON s.instance_stage_id = a.instance_stage_id
             WHERE a.instance_id IN (SELECT instance_id FROM lineage)
               AND a.actor_id = p_user_id
               AND a.action IN ('submit', 'approve', 'commit')
               AND s.stage_id <> (SELECT stage_id FROM me))
     OR EXISTS (SELECT 1
                FROM wf.stage_group_decision d
                JOIN wf.instance_stage s ON s.instance_stage_id = d.instance_stage_id
                WHERE s.instance_id IN (SELECT instance_id FROM lineage)
                  AND d.decided_by = p_user_id
                  AND d.decision = 'approve'
                  AND s.stage_id <> (SELECT stage_id FROM me))
   )
$$;

-- Node access: every item in the instance must fall under the stage's scope (if any).
CREATE FUNCTION wf.items_in_scope(p_instance_stage_id uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path = wf, mdm, public AS $$
SELECT NOT EXISTS (SELECT 1
                   FROM wf.stage_access_scope sc
                   JOIN wf.instance_stage ist ON ist.stage_id = sc.stage_id
                   WHERE ist.instance_stage_id = p_instance_stage_id)
    OR NOT EXISTS (
         SELECT 1
         FROM wf.instance_stage ist
         JOIN wf.instance_item ii ON ii.instance_id = ist.instance_id
         JOIN mdm.change_item ci  ON ci.change_item_id = ii.change_item_id
         WHERE ist.instance_stage_id = p_instance_stage_id
           AND coalesce(ci.node_id, ci.target_parent_id) IS NOT NULL
           AND NOT EXISTS (
             SELECT 1
             FROM wf.stage_access_scope sc
             CROSS JOIN LATERAL mdm.hierarchy_tree(sc.hierarchy_id, current_date, now(), sc.top_node_id) t
             WHERE sc.stage_id = ist.stage_id
               AND t.node_id IN (ci.node_id, ci.target_parent_id)))
$$;

-- Can this user act on this stage right now?
CREATE FUNCTION wf.can_act(p_instance_stage_id uuid, p_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path = wf, mdm, public AS $$
SELECT coalesce((
  SELECT u.is_active
     AND u.kind = 'human'
     AND i.status = 'in_flight'
     AND ist.status IN ('active', 'claimed')
     AND (ist.claimed_by IS NULL OR ist.claimed_by = p_user_id OR ist.claim_expires_at < now())
     -- requester and submitter never approve or commit their own request
     AND NOT (ws.stage_type IN ('approve', 'commit')
              AND (cr.requester_id = p_user_id OR i.submitted_by = p_user_id))
     AND NOT wf.sod_violation(p_instance_stage_id, p_user_id)
     AND wf.items_in_scope(p_instance_stage_id)
     AND EXISTS (
       SELECT 1
       FROM wf.stage_group sg
       WHERE sg.stage_id = ist.stage_id
         AND wf.is_member(sg.group_id, p_user_id, mdm.business_today())
         AND NOT EXISTS (SELECT 1 FROM wf.stage_group_decision d
                         WHERE d.instance_stage_id = ist.instance_stage_id AND d.group_id = sg.group_id)
         AND (ws.approval_method <> 'sequential_groups' OR sg.seq = (
               SELECT min(sg2.seq) FROM wf.stage_group sg2
               WHERE sg2.stage_id = ist.stage_id
                 AND NOT EXISTS (SELECT 1 FROM wf.stage_group_decision d2
                                 WHERE d2.instance_stage_id = ist.instance_stage_id
                                   AND d2.group_id = sg2.group_id))))
  FROM wf.instance_stage ist
  JOIN wf.workflow_stage ws    ON ws.stage_id = ist.stage_id
  JOIN wf.workflow_instance i  ON i.instance_id = ist.instance_id
  JOIN mdm.change_request cr   ON cr.change_request_id = i.change_request_id
  JOIN mdm.app_user u          ON u.user_id = p_user_id
  WHERE ist.instance_stage_id = p_instance_stage_id
), false)
$$;

-- Outcome of a stage from its group decisions.
CREATE FUNCTION wf.stage_outcome(p_instance_stage_id uuid)
RETURNS text LANGUAGE sql STABLE SET search_path = wf, mdm, public AS $$
SELECT CASE
  WHEN bool_or(d.decision = 'reject')    THEN 'rejected'
  WHEN bool_or(d.decision = 'push_back') THEN 'pushed_back'
  WHEN ws.approval_method = 'any_group' AND bool_or(d.decision = 'approve') THEN 'approved'
  WHEN ws.approval_method <> 'any_group'
   AND count(d.group_id) FILTER (WHERE d.decision = 'approve')
       = (SELECT count(*) FROM wf.stage_group sg WHERE sg.stage_id = ws.stage_id) THEN 'approved'
  ELSE 'pending'
END
FROM wf.instance_stage ist
JOIN wf.workflow_stage ws ON ws.stage_id = ist.stage_id
LEFT JOIN wf.stage_group_decision d ON d.instance_stage_id = ist.instance_stage_id
WHERE ist.instance_stage_id = p_instance_stage_id
GROUP BY ws.approval_method, ws.stage_id
$$;

-- Decisions: group member + can_act, checked at insert. Decisions are final (append-only).
CREATE FUNCTION wf.trg_decision_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
BEGIN
  IF NOT wf.is_member(NEW.group_id, NEW.decided_by, mdm.business_today()) THEN
    RAISE EXCEPTION 'User % is not a member of the deciding group', NEW.decided_by USING ERRCODE = 'N1015', HINT = 'wf.not_group_member';
  END IF;
  IF NOT wf.can_act(NEW.instance_stage_id, NEW.decided_by) THEN
    RAISE EXCEPTION 'User % cannot act on this stage (claim, group order, separation of duties or node access)',
      NEW.decided_by USING ERRCODE = 'N1016', HINT = 'wf.cannot_act';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER stage_group_decision_guard BEFORE INSERT ON wf.stage_group_decision
  FOR EACH ROW EXECUTE FUNCTION wf.trg_decision_guard();
CREATE TRIGGER stage_group_decision_append_only BEFORE UPDATE OR DELETE ON wf.stage_group_decision
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_append_only();

-- History: actor kind must be truthful; decisions are human-only; AI entries carry model + confidence.
CREATE FUNCTION wf.trg_action_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
DECLARE k mdm.requester_kind;
BEGIN
  SELECT kind INTO k FROM mdm.app_user WHERE user_id = NEW.actor_id;
  IF k IS DISTINCT FROM NEW.actor_kind THEN
    RAISE EXCEPTION 'actor_kind % does not match the user record (%)', NEW.actor_kind, k USING ERRCODE = 'N1017', HINT = 'wf.actor_kind_mismatch';
  END IF;
  IF NEW.action IN ('claim', 'approve', 'reject', 'push_back', 'commit') AND k <> 'human' THEN
    RAISE EXCEPTION 'Action % can only be performed by a human', NEW.action USING ERRCODE = 'N1002', HINT = 'human_only';
  END IF;
  IF k = 'ai_agent' AND (NEW.ai_model IS NULL OR NEW.ai_confidence IS NULL) THEN
    RAISE EXCEPTION 'AI actions must record ai_model and ai_confidence' USING ERRCODE = 'N1018', HINT = 'ai.model_required';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER instance_action_guard BEFORE INSERT ON wf.instance_action
  FOR EACH ROW EXECUTE FUNCTION wf.trg_action_guard();
CREATE TRIGGER instance_action_append_only BEFORE UPDATE OR DELETE ON wf.instance_action
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_append_only();

-- Every stage status change becomes an event (drives notifications and the engine).
CREATE FUNCTION wf.trg_stage_event() RETURNS trigger
LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
BEGIN
  INSERT INTO wf.event_outbox (event_type, instance_id, payload)
  VALUES ('stage_status_changed', NEW.instance_id,
          jsonb_build_object('instance_stage_id', NEW.instance_stage_id, 'stage_id', NEW.stage_id,
                             'iteration', NEW.iteration, 'from', OLD.status, 'to', NEW.status));
  RETURN NEW;
END $$;
CREATE TRIGGER instance_stage_event AFTER UPDATE OF status ON wf.instance_stage
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION wf.trg_stage_event();

-- =============================================================================
-- STAGE RULES: allowed edits, required fields, conditions
-- =============================================================================

-- May this change item be created or edited in this stage?
CREATE FUNCTION wf.item_allowed_in_stage(p_change_item_id uuid, p_instance_stage_id uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path = wf, mdm, public AS $$
SELECT EXISTS (
  SELECT 1
  FROM mdm.change_item ci
  JOIN wf.instance_stage ist ON ist.instance_stage_id = p_instance_stage_id
  JOIN wf.workflow_stage ws  ON ws.stage_id = ist.stage_id
  JOIN LATERAL (
    SELECT ws.task_id AS task_id WHERE ws.task_id IS NOT NULL
    UNION
    SELECT st.task_id FROM wf.submit_task st WHERE ws.stage_type = 'submit' AND st.model_id = ws.model_id
  ) tk ON true
  JOIN wf.workflow_task t ON t.task_id = tk.task_id
  WHERE ci.change_item_id = p_change_item_id
    AND ci.action = ANY (t.allowed_actions)
    AND (ci.action NOT IN ('set_property', 'clear_property')
         OR EXISTS (SELECT 1 FROM wf.task_property tp
                    WHERE tp.task_id = t.task_id AND tp.property_id = ci.property_id
                      AND NOT tp.is_read_only)))
$$;

-- Required properties still missing for the nodes in this stage (blocks enrich completion).
CREATE FUNCTION wf.missing_required_properties(p_instance_stage_id uuid)
RETURNS TABLE (node_id uuid, property_code text)
LANGUAGE sql STABLE SET search_path = wf, mdm, public AS $$
SELECT DISTINCT ci.node_id, pd.property_code
FROM wf.instance_stage ist
JOIN wf.workflow_stage ws  ON ws.stage_id = ist.stage_id
JOIN wf.task_property tp   ON tp.task_id = ws.task_id AND tp.is_required
JOIN mdm.property_definition pd ON pd.property_id = tp.property_id
JOIN wf.instance_item ii   ON ii.instance_id = ist.instance_id
JOIN mdm.change_item ci    ON ci.change_item_id = ii.change_item_id AND ci.node_id IS NOT NULL
WHERE ist.instance_stage_id = p_instance_stage_id
  AND NOT EXISTS (                 -- not supplied in the request...
        SELECT 1 FROM mdm.change_item c2
        WHERE c2.change_request_id = ci.change_request_id AND c2.node_id = ci.node_id
          AND c2.property_id = tp.property_id AND c2.action = 'set_property'
          AND jsonb_typeof(c2.payload->'value') IS DISTINCT FROM 'null')
  AND coalesce(jsonb_typeof(       -- ...and not already stored
        mdm.property_value_asof(ci.node_id, tp.property_id, ci.hierarchy_id, current_date, now())), 'null') = 'null'
$$;

-- Does a change item match a stage condition? Proposed values in the request win over stored values.
CREATE FUNCTION wf.item_condition_matches(p_change_item_id uuid, p_condition jsonb)
RETURNS boolean LANGUAGE plpgsql STABLE SET search_path = wf, mdm, public AS $$
DECLARE
  ci  mdm.change_item%ROWTYPE;
  pid uuid;
  v   jsonb;
  c   jsonb;
BEGIN
  SELECT * INTO ci FROM mdm.change_item WHERE change_item_id = p_change_item_id;

  CASE p_condition->>'type'
    WHEN 'any' THEN
      FOR c IN SELECT * FROM jsonb_array_elements(p_condition->'conditions') LOOP
        IF wf.item_condition_matches(p_change_item_id, c) THEN RETURN true; END IF;
      END LOOP;
      RETURN false;

    WHEN 'all' THEN
      FOR c IN SELECT * FROM jsonb_array_elements(p_condition->'conditions') LOOP
        IF NOT wf.item_condition_matches(p_change_item_id, c) THEN RETURN false; END IF;
      END LOOP;
      RETURN true;

    WHEN 'validation_failed' THEN
      RETURN EXISTS (
        SELECT 1 FROM mdm.validation_result vr
        JOIN mdm.validation_rule r ON r.rule_id = vr.rule_id
        WHERE vr.change_request_id = ci.change_request_id
          AND r.rule_code = p_condition->>'rule_code'
          AND vr.severity = 'error'
          AND (vr.node_id IS NULL OR vr.node_id = ci.node_id));

    WHEN 'property' THEN
      SELECT property_id INTO pid FROM mdm.property_definition WHERE property_code = p_condition->>'property';
      IF pid IS NULL THEN
        RAISE EXCEPTION 'Unknown property in stage condition: %', p_condition->>'property' USING ERRCODE = 'N2208', HINT = 'wf.condition_property';
      END IF;
      SELECT c2.payload->'value' INTO v
      FROM mdm.change_item c2
      WHERE c2.change_request_id = ci.change_request_id AND c2.node_id = ci.node_id
        AND c2.property_id = pid AND c2.action = 'set_property'
      ORDER BY c2.seq DESC LIMIT 1;
      IF NOT FOUND THEN
        v := mdm.property_value_asof(ci.node_id, pid, ci.hierarchy_id, current_date, now());
      END IF;
      IF v = 'null'::jsonb THEN v := NULL; END IF;
      RETURN coalesce(CASE p_condition->>'op'
               WHEN '='        THEN v = p_condition->'value'
               WHEN '<>'       THEN v IS DISTINCT FROM p_condition->'value'
               WHEN 'in'       THEN v IS NOT NULL AND (p_condition->'value') @> jsonb_build_array(v)
               WHEN 'is_null'  THEN v IS NULL
               WHEN 'not_null' THEN v IS NOT NULL
             END, false);
    ELSE
      RAISE EXCEPTION 'Unsupported condition type %', p_condition->>'type' USING ERRCODE = 'N2209', HINT = 'wf.condition_type';
  END CASE;
END $$;

-- =============================================================================
-- LIFECYCLE OPERATIONS (atomic steps the engine calls)
-- =============================================================================

-- Start a request on the active version of a model.
CREATE FUNCTION wf.start_instance(p_change_request_id uuid, p_model_code text, p_submitter uuid)
RETURNS uuid LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
DECLARE
  m          wf.workflow_model%ROWTYPE;
  v_instance uuid;
  v_submit   uuid;
BEGIN
  SELECT * INTO m FROM wf.workflow_model WHERE model_code = p_model_code AND status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No active workflow model %', p_model_code USING ERRCODE = 'N2210', HINT = 'wf.no_active_model';
  END IF;

  INSERT INTO wf.workflow_instance (change_request_id, model_id, status, current_seq,
                                    submitted_by, submitted_at, due_at)
  VALUES (p_change_request_id, m.model_id, 'in_flight', 1,
          p_submitter, now(), now() + m.request_duration)
  RETURNING instance_id INTO v_instance;

  INSERT INTO wf.instance_item (change_item_id, instance_id)
  SELECT change_item_id, v_instance FROM mdm.change_item WHERE change_request_id = p_change_request_id;

  INSERT INTO wf.instance_stage (instance_id, stage_id, seq, status, included, started_at, completed_at)
  SELECT v_instance, s.stage_id, s.seq,
         CASE WHEN s.stage_type = 'submit' THEN 'completed' ELSE 'pending' END::wf.stage_status,
         CASE WHEN s.condition IS NULL THEN true END,
         CASE WHEN s.stage_type = 'submit' THEN now() END,
         CASE WHEN s.stage_type = 'submit' THEN now() END
  FROM wf.workflow_stage s WHERE s.model_id = m.model_id;

  SELECT ist.instance_stage_id INTO v_submit
  FROM wf.instance_stage ist JOIN wf.workflow_stage s ON s.stage_id = ist.stage_id
  WHERE ist.instance_id = v_instance AND s.stage_type = 'submit';

  INSERT INTO wf.instance_action (instance_id, instance_stage_id, actor_id, actor_kind, action)
  SELECT v_instance, v_submit, p_submitter, u.kind, 'submit' FROM mdm.app_user u WHERE u.user_id = p_submitter;

  INSERT INTO wf.event_outbox (event_type, instance_id, payload)
  VALUES ('instance_started', v_instance,
          jsonb_build_object('change_request_id', p_change_request_id, 'model', p_model_code,
                             'model_version', m.model_version));
  RETURN v_instance;
END $$;

-- Conditional split: items matching the stage condition move to a child request
-- that includes the stage; the parent continues without it. Returns the child id,
-- or NULL when all or none of the items match (no split needed).
CREATE FUNCTION wf.split_instance(p_instance_id uuid, p_stage_id uuid, p_actor_id uuid)
RETURNS uuid LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
DECLARE
  v_cond  jsonb;
  inst    wf.workflow_instance%ROWTYPE;
  v_child uuid;
  n_match int;
  n_total int;
BEGIN
  SELECT condition INTO v_cond FROM wf.workflow_stage WHERE stage_id = p_stage_id AND split_on_condition;
  IF v_cond IS NULL THEN
    RAISE EXCEPTION 'Stage % is not a splitting conditional stage', p_stage_id USING ERRCODE = 'N2211', HINT = 'wf.not_splitting';
  END IF;
  SELECT * INTO inst FROM wf.workflow_instance WHERE instance_id = p_instance_id FOR UPDATE;

  SELECT count(*) FILTER (WHERE wf.item_condition_matches(ii.change_item_id, v_cond)), count(*)
    INTO n_match, n_total
  FROM wf.instance_item ii WHERE ii.instance_id = p_instance_id;

  IF n_match = 0 OR n_match = n_total THEN
    UPDATE wf.instance_stage SET included = (n_match > 0),
                                 status = CASE WHEN n_match = 0 THEN 'skipped'::wf.stage_status ELSE status END
    WHERE instance_id = p_instance_id AND stage_id = p_stage_id;
    RETURN NULL;
  END IF;

  INSERT INTO wf.workflow_instance (change_request_id, model_id, parent_instance_id, status, current_seq,
                                    submitted_by, submitted_at, due_at)
  VALUES (inst.change_request_id, inst.model_id, inst.instance_id, 'in_flight', inst.current_seq,
          inst.submitted_by, inst.submitted_at, inst.due_at)
  RETURNING instance_id INTO v_child;

  -- child inherits the stage state so far (latest iteration of each stage, no claims)
  INSERT INTO wf.instance_stage (instance_id, stage_id, seq, iteration, status, included,
                                 started_at, due_at, completed_at)
  SELECT v_child, s.stage_id, s.seq, s.iteration, s.status,
         CASE WHEN s.stage_id = p_stage_id THEN true ELSE s.included END,
         s.started_at, s.due_at, s.completed_at
  FROM wf.instance_stage s
  WHERE s.instance_id = p_instance_id
    AND s.iteration = (SELECT max(x.iteration) FROM wf.instance_stage x
                       WHERE x.instance_id = s.instance_id AND x.stage_id = s.stage_id);

  UPDATE wf.instance_item ii SET instance_id = v_child
  WHERE ii.instance_id = p_instance_id AND wf.item_condition_matches(ii.change_item_id, v_cond);

  UPDATE wf.instance_stage SET included = false, status = 'skipped'
  WHERE instance_id = p_instance_id AND stage_id = p_stage_id;

  INSERT INTO wf.instance_action (instance_id, actor_id, actor_kind, action, payload)
  SELECT p_instance_id, p_actor_id, u.kind, 'split',
         jsonb_build_object('child_instance_id', v_child, 'stage_id', p_stage_id, 'items_moved', n_match)
  FROM mdm.app_user u WHERE u.user_id = p_actor_id;

  INSERT INTO wf.event_outbox (event_type, instance_id, payload)
  VALUES ('instance_split', p_instance_id, jsonb_build_object('child_instance_id', v_child));
  RETURN v_child;
END $$;

-- Close an instance. Committing requires an approved commit stage and all included stages complete.
CREATE FUNCTION wf.close_instance(p_instance_id uuid, p_outcome wf.instance_status,
                                  p_actor_id uuid, p_comment text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SET search_path = wf, mdm, public AS $$
DECLARE
  v_commit_stage uuid;
  k              mdm.requester_kind;
BEGIN
  IF p_outcome NOT IN ('committed', 'rejected', 'withdrawn') THEN
    RAISE EXCEPTION 'Outcome must be committed, rejected or withdrawn' USING ERRCODE = 'N2212', HINT = 'wf.bad_outcome';
  END IF;

  IF p_outcome = 'committed' THEN
    SELECT ist.instance_stage_id INTO v_commit_stage
    FROM wf.instance_stage ist JOIN wf.workflow_stage ws ON ws.stage_id = ist.stage_id
    WHERE ist.instance_id = p_instance_id AND ws.stage_type = 'commit'
    ORDER BY ist.iteration DESC LIMIT 1;

    IF wf.stage_outcome(v_commit_stage) IS DISTINCT FROM 'approved' THEN
      RAISE EXCEPTION 'Commit stage has not been approved' USING ERRCODE = 'N2213', HINT = 'wf.commit_not_approved';
    END IF;
    IF EXISTS (
      SELECT 1 FROM wf.instance_stage ist JOIN wf.workflow_stage ws ON ws.stage_id = ist.stage_id
      WHERE ist.instance_id = p_instance_id
        AND ws.stage_type IN ('enrich', 'approve')
        AND ist.included IS DISTINCT FROM false
        AND ist.iteration = (SELECT max(x.iteration) FROM wf.instance_stage x
                             WHERE x.instance_id = ist.instance_id AND x.stage_id = ist.stage_id)
        AND ist.status <> 'completed') THEN
      RAISE EXCEPTION 'Not all required stages are complete' USING ERRCODE = 'N2214', HINT = 'wf.stages_incomplete';
    END IF;
  END IF;

  UPDATE wf.workflow_instance SET status = p_outcome, closed_at = now()
  WHERE instance_id = p_instance_id AND status IN ('draft', 'in_flight', 'pushed_back');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Instance % is not open', p_instance_id USING ERRCODE = 'N2215', HINT = 'wf.instance_not_open';
  END IF;

  SELECT kind INTO k FROM mdm.app_user WHERE user_id = p_actor_id;
  INSERT INTO wf.instance_action (instance_id, instance_stage_id, actor_id, actor_kind, action, comment)
  VALUES (p_instance_id, v_commit_stage, p_actor_id, k,
          CASE p_outcome WHEN 'committed' THEN 'commit' WHEN 'rejected' THEN 'reject' ELSE 'withdraw' END::wf.wf_action,
          p_comment);

  INSERT INTO wf.event_outbox (event_type, instance_id, payload)
  VALUES ('instance_closed', p_instance_id, jsonb_build_object('outcome', p_outcome, 'actor_id', p_actor_id));
END $$;

-- =============================================================================
-- VIEWS FOR THE APP
-- =============================================================================

-- A user's inbox: stages they can act on now, soonest due first.
CREATE FUNCTION wf.worklist(p_user_id uuid)
RETURNS TABLE (instance_stage_id uuid, instance_id uuid, change_request_id uuid, title text,
               stage_label text, stage_type wf.stage_type, stage_status wf.stage_status,
               due_at timestamptz, claimed_by uuid)
LANGUAGE sql STABLE SET search_path = wf, mdm, public AS $$
SELECT ist.instance_stage_id, i.instance_id, i.change_request_id, cr.title,
       ws.label, ws.stage_type, ist.status, ist.due_at, ist.claimed_by
FROM wf.instance_stage ist
JOIN wf.workflow_stage ws   ON ws.stage_id = ist.stage_id
JOIN wf.workflow_instance i ON i.instance_id = ist.instance_id
JOIN mdm.change_request cr  ON cr.change_request_id = i.change_request_id
WHERE ist.status IN ('active', 'claimed')
  AND wf.can_act(ist.instance_stage_id, p_user_id)
ORDER BY ist.due_at NULLS LAST
$$;

CREATE VIEW wf.v_sla_status AS
SELECT i.instance_id, i.change_request_id, cr.title,
       ist.instance_stage_id, ws.label AS stage_label, ist.status AS stage_status, ist.claimed_by,
       ist.due_at AS stage_due_at, i.due_at AS request_due_at,
       (ist.due_at < now() AND ist.status IN ('active', 'claimed')) AS stage_overdue,
       (i.due_at  < now()) AS request_overdue
FROM wf.workflow_instance i
JOIN mdm.change_request cr ON cr.change_request_id = i.change_request_id
JOIN wf.instance_stage ist ON ist.instance_id = i.instance_id AND ist.seq = i.current_seq
JOIN wf.workflow_stage ws  ON ws.stage_id = ist.stage_id
WHERE i.status IN ('in_flight', 'pushed_back')
  AND ist.iteration = (SELECT max(x.iteration) FROM wf.instance_stage x
                       WHERE x.instance_id = ist.instance_id AND x.stage_id = ist.stage_id);
