-- =============================================================================
-- V11 — Versions (VER-01 create and copy, VER-02 lifecycle; ADR-037; Phase 3 LLD "Third scope extension: versions").
--
-- A version is a named slice of the one bitemporal store: a business date and, from submit on, a recorded time (the
-- pin). Its picture is the data valid on the business date as recorded at the pin, or as recorded now while it is
-- working. No rows are copied, and working versions are not isolated from each other (ADR-037 D2).
-- V1 to V10 are unchanged; validate_change_request is replaced at the end of this file to add one warning.
-- =============================================================================

SET search_path = mdm, public;

-- -----------------------------------------------------------------------------
-- Role (ADR-037 D4). What it may do is fixed in code: VERSION_ADMIN → READ, ADMIN_VERSION (RolePermissions).
-- -----------------------------------------------------------------------------
INSERT INTO mdm.role VALUES ('VERSION_ADMIN', 'Create versions and move them through their lifecycle');

-- -----------------------------------------------------------------------------
-- Version columns. revision is the ETag source (ADR-015). The V1 CHECK (finalized means pinned) stays; this one ties
-- the pin and the submit and finalize fields to the status, so no row can claim a status its fields contradict.
-- -----------------------------------------------------------------------------
ALTER TABLE mdm.version
  ADD COLUMN created_at   timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN created_by   uuid REFERENCES mdm.app_user,
  ADD COLUMN submitted_at timestamptz,
  ADD COLUMN submitted_by uuid REFERENCES mdm.app_user,
  ADD COLUMN revision     int NOT NULL DEFAULT 1,
  ADD CONSTRAINT version_lifecycle_fields CHECK (
        ((status = 'working') = (recorded_as_of IS NULL))
    AND ((status = 'working') = (submitted_by IS NULL))
    AND ((status IN ('finalized', 'expired')) = (finalized_by IS NOT NULL)));

COMMENT ON COLUMN mdm.version.recorded_as_of IS
  'The pin: set at submit (clock time, under the freeze lock), cleared at reopen, kept at finalize and expire (ADR-037).';
COMMENT ON COLUMN mdm.version.revision IS 'Bumped by every update (trg_version_guard); the API ETag (ADR-015).';

-- -----------------------------------------------------------------------------
-- Transition log: who moved which version, when, and why. Written only by the version guard; append-only.
-- -----------------------------------------------------------------------------
CREATE TABLE mdm.version_transition (
  transition_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id    uuid NOT NULL REFERENCES mdm.version,
  from_status   version_status NOT NULL,
  to_status     version_status NOT NULL,
  actor_id      uuid NOT NULL REFERENCES mdm.app_user,
  reason        text,
  pinned_at     timestamptz,                       -- the version's recorded_as_of after the transition
  recorded_at   timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX version_transition_version ON mdm.version_transition (version_id, recorded_at);
CREATE TRIGGER version_transition_append_only BEFORE UPDATE OR DELETE ON mdm.version_transition
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_append_only();
COMMENT ON TABLE mdm.version_transition IS 'Version status changes (VER-02, ADR-037). Append-only; written by trg_version_guard.';

-- -----------------------------------------------------------------------------
-- The user's chosen working version (V.5 /me). UI data, not governed: a stale choice (the version left working) is
-- ignored by the API, which falls back to the latest working version.
-- -----------------------------------------------------------------------------
ALTER TABLE mdm.user_preference ADD COLUMN working_version_id uuid REFERENCES mdm.version;
GRANT INSERT (working_version_id), UPDATE (working_version_id) ON mdm.user_preference TO nexus_api;

-- R1: a requester may move a draft to another version. cr_frozen_content (N2102) still refuses it on any request that
-- is not a draft, and cr_version_working (below) refuses a target that is not working.
GRANT UPDATE (version_id) ON mdm.change_request TO nexus_api;

-- -----------------------------------------------------------------------------
-- The freeze lock (ADR-037 R2). Submit takes it exclusively before it pins; an apply takes it shared when the request
-- becomes applied. Key (11, 37): migration V11, ADR-037. Nothing else in Nexus uses advisory locks.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Version guard (LLD V.4). Every rule holds for the owner too: the functions below are the intended path, and a
-- direct write is held to the same lifecycle.
-- -----------------------------------------------------------------------------
CREATE FUNCTION mdm.trg_version_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE
  v_actor  uuid := nullif(current_setting('mdm.actor_id', true), '')::uuid;
  v_move   text;
  v_sub    int;
  v_rev    int;
  v_app    int;
  v_parts  text[] := '{}';
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Version % is never deleted; expire it instead', OLD.version_name
      USING ERRCODE = 'N2705', HINT = 'version.no_delete';
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'working' OR NEW.recorded_as_of IS NOT NULL OR NEW.submitted_at IS NOT NULL
       OR NEW.submitted_by IS NOT NULL OR NEW.finalized_at IS NOT NULL OR NEW.finalized_by IS NOT NULL THEN
      RAISE EXCEPTION 'A new version starts as working, with no recorded time and no submit or finalize details'
        USING ERRCODE = 'N2706', HINT = 'version.must_start_working';
    END IF;
    NEW.revision := 1;
    RETURN NEW;
  END IF;

  -- UPDATE. Identity and creation details never change.
  IF (NEW.version_id, NEW.created_at, NEW.created_by) IS DISTINCT FROM (OLD.version_id, OLD.created_at, OLD.created_by) THEN
    RAISE EXCEPTION 'The identity and creation details of version % never change', OLD.version_name
      USING ERRCODE = 'N2702', HINT = 'version.frozen';
  END IF;
  -- The business date and the base belong to a working version (before and after this update).
  IF (NEW.business_as_of, NEW.base_version_id) IS DISTINCT FROM (OLD.business_as_of, OLD.base_version_id)
     AND NOT (OLD.status = 'working' AND NEW.status = 'working') THEN
    RAISE EXCEPTION 'The business date and base of version % change only while it is working (it is %)', OLD.version_name, OLD.status
      USING ERRCODE = 'N2702', HINT = 'version.frozen';
  END IF;
  -- Name and description change while working or submitted; a finalized or expired version keeps them for ever.
  IF (NEW.version_name, NEW.description) IS DISTINCT FROM (OLD.version_name, OLD.description)
     AND NOT (OLD.status IN ('working', 'submitted') AND NEW.status IN ('working', 'submitted')) THEN
    RAISE EXCEPTION 'The name and description of version % cannot change: it is %', OLD.version_name, OLD.status
      USING ERRCODE = 'N2702', HINT = 'version.frozen';
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    v_move := OLD.status::text || '>' || NEW.status::text;
    IF v_move NOT IN ('working>submitted', 'submitted>working', 'submitted>finalized', 'finalized>expired') THEN
      RAISE EXCEPTION 'Version % cannot move from % to %', OLD.version_name, OLD.status, NEW.status
        USING ERRCODE = 'N2701', HINT = 'version.status_transition';
    END IF;
    -- People only, identified and active (D4): nobody moves a version anonymously or as an agent.
    IF v_actor IS NULL OR NOT EXISTS (SELECT 1 FROM mdm.app_user u
                                      WHERE u.user_id = v_actor AND u.kind = 'human' AND u.is_active) THEN
      RAISE EXCEPTION 'A version changes status only by an identified, active person'
        USING ERRCODE = 'N1030', HINT = 'version.actor_not_human';
    END IF;

    IF v_move = 'working>submitted' THEN
      -- R1: drafts do not block; anything already on its way to the facts does.
      SELECT count(*) FILTER (WHERE c.status = 'submitted'), count(*) FILTER (WHERE c.status = 'in_review'),
             count(*) FILTER (WHERE c.status = 'approved')
        INTO v_sub, v_rev, v_app
        FROM mdm.change_request c WHERE c.version_id = OLD.version_id AND c.status IN ('submitted', 'in_review', 'approved');
      IF v_sub + v_rev + v_app > 0 THEN
        IF v_sub > 0 THEN v_parts := v_parts || (v_sub || ' submitted'); END IF;
        IF v_rev > 0 THEN v_parts := v_parts || (v_rev || ' in review'); END IF;
        IF v_app > 0 THEN v_parts := v_parts || (v_app || ' approved'); END IF;
        RAISE EXCEPTION '% in this version % still in flight (%)',
          CASE WHEN v_sub + v_rev + v_app = 1 THEN '1 request' ELSE (v_sub + v_rev + v_app) || ' requests' END,
          CASE WHEN v_sub + v_rev + v_app = 1 THEN 'is' ELSE 'are' END, array_to_string(v_parts, ', ')
          USING ERRCODE = 'N2704', HINT = 'version.requests_open',
                DETAIL = format('submitted=%s in_review=%s approved=%s', v_sub, v_rev, v_app);
      END IF;
      IF NEW.recorded_as_of IS NULL OR NEW.recorded_as_of > clock_timestamp() OR NEW.submitted_at IS NULL
         OR NEW.submitted_by IS DISTINCT FROM v_actor OR NEW.finalized_at IS NOT NULL THEN
        RAISE EXCEPTION 'Submitting version % pins it now and records who submitted it; nothing else changes', OLD.version_name
          USING ERRCODE = 'N2702', HINT = 'version.frozen';
      END IF;
    ELSIF v_move = 'submitted>working' THEN
      IF NEW.recorded_as_of IS NOT NULL OR NEW.submitted_at IS NOT NULL OR NEW.submitted_by IS NOT NULL
         OR NEW.finalized_at IS NOT NULL THEN
        RAISE EXCEPTION 'Reopening version % clears its pin and submit details', OLD.version_name
          USING ERRCODE = 'N2702', HINT = 'version.frozen';
      END IF;
    ELSIF v_move = 'submitted>finalized' THEN
      IF OLD.submitted_by = v_actor THEN               -- four eyes (D4)
        RAISE EXCEPTION 'You submitted version %; another version administrator must finalize it', OLD.version_name
          USING ERRCODE = 'N1029', HINT = 'version.self_finalize';
      END IF;
      IF (NEW.recorded_as_of, NEW.submitted_at, NEW.submitted_by) IS DISTINCT FROM (OLD.recorded_as_of, OLD.submitted_at, OLD.submitted_by)
         OR NEW.finalized_at IS NULL OR NEW.finalized_by IS DISTINCT FROM v_actor THEN
        RAISE EXCEPTION 'Finalizing version % keeps its pin and records who finalized it', OLD.version_name
          USING ERRCODE = 'N2702', HINT = 'version.frozen';
      END IF;
    ELSE                                               -- finalized > expired: the status only
      IF (NEW.recorded_as_of, NEW.submitted_at, NEW.submitted_by, NEW.finalized_at, NEW.finalized_by)
         IS DISTINCT FROM (OLD.recorded_as_of, OLD.submitted_at, OLD.submitted_by, OLD.finalized_at, OLD.finalized_by) THEN
        RAISE EXCEPTION 'Expiring version % changes only its status', OLD.version_name
          USING ERRCODE = 'N2702', HINT = 'version.frozen';
      END IF;
    END IF;

    INSERT INTO mdm.version_transition (version_id, from_status, to_status, actor_id, reason, pinned_at)
    VALUES (OLD.version_id, OLD.status, NEW.status, v_actor,
            nullif(current_setting('mdm.version_reason', true), ''), NEW.recorded_as_of);
  ELSE
    -- No status change: the pin and the submit and finalize details stay as their transitions set them.
    IF (NEW.recorded_as_of, NEW.submitted_at, NEW.submitted_by, NEW.finalized_at, NEW.finalized_by)
       IS DISTINCT FROM (OLD.recorded_as_of, OLD.submitted_at, OLD.submitted_by, OLD.finalized_at, OLD.finalized_by) THEN
      RAISE EXCEPTION 'The pin and the submit and finalize details of version % change only with its status', OLD.version_name
        USING ERRCODE = 'N2702', HINT = 'version.frozen';
    END IF;
  END IF;

  NEW.revision := OLD.revision + 1;
  RETURN NEW;
END $$;
CREATE TRIGGER version_guard BEFORE INSERT OR UPDATE OR DELETE ON mdm.version
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_version_guard();

-- -----------------------------------------------------------------------------
-- Requests live in working versions (LLD V.4, R4), and a frozen picture never gains rows (R2).
-- SECURITY DEFINER: FOR SHARE needs UPDATE on mdm.version, which no application role has.
-- -----------------------------------------------------------------------------
CREATE FUNCTION mdm.trg_cr_version_working() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm, public AS $$
DECLARE
  v_status version_status;
  v_name   text;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.version_id IS NOT DISTINCT FROM OLD.version_id
     AND NOT (NEW.status IS DISTINCT FROM OLD.status AND NEW.status IN ('submitted', 'in_review', 'approved', 'applied')) THEN
    RETURN NEW;                                        -- withdrawing, rejecting or failing stays possible in any version
  END IF;

  IF TG_OP = 'UPDATE' AND NEW.status = 'applied' AND OLD.status IS DISTINCT FROM NEW.status THEN
    -- R2: wait for any submit that is pinning now, then refuse if a pin fell after this transaction began; this
    -- transaction's facts are recorded from its start, so they would appear in that frozen picture. 40001 is not a
    -- rule failure in apply_change_request, so ApplyService retries it in a new transaction, after the pin.
    PERFORM pg_advisory_xact_lock_shared(11, 37);
    IF EXISTS (SELECT 1 FROM mdm.version v WHERE v.recorded_as_of > now()) THEN
      RAISE EXCEPTION 'A version was frozen while this request was being applied; the apply is retried'
        USING ERRCODE = '40001', HINT = 'version.frozen_during_apply';
    END IF;
  END IF;

  -- FOR SHARE serializes with a concurrent submit of the same version (its UPDATE waits, or this read sees its result).
  SELECT v.status, v.version_name INTO v_status, v_name FROM mdm.version v WHERE v.version_id = NEW.version_id FOR SHARE;
  IF v_status IS DISTINCT FROM 'working' THEN
    RAISE EXCEPTION 'Version % is %, not working: requests cannot be raised in it, moved to it or advanced in it', v_name, v_status
      USING ERRCODE = 'N2703', HINT = 'version.not_working';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER cr_version_working BEFORE INSERT OR UPDATE OF version_id, status ON mdm.change_request
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_cr_version_working();
REVOKE EXECUTE ON FUNCTION mdm.trg_cr_version_working() FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- Functions (LLD V.4): the only way the API changes a version. Each sets mdm.actor_id, so the guard and the audit
-- see the caller.
-- -----------------------------------------------------------------------------
CREATE FUNCTION mdm.is_version_admin(p_user uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path = mdm, public AS $$
  SELECT EXISTS (SELECT 1 FROM mdm.user_role ur JOIN mdm.app_user u ON u.user_id = ur.user_id
                 WHERE ur.user_id = p_user AND ur.role_code = 'VERSION_ADMIN' AND ur.hierarchy_id IS NULL
                   AND ur.valid_period @> mdm.business_today() AND upper_inf(ur.recorded_period)
                   AND u.kind = 'human' AND u.is_active)
$$;

CREATE FUNCTION mdm.version_require_admin(p_actor uuid)
RETURNS void LANGUAGE plpgsql STABLE SET search_path = mdm, public AS $$
BEGIN
  IF p_actor IS NULL OR NOT mdm.is_version_admin(p_actor) THEN
    RAISE EXCEPTION 'Only a version administrator can create or change versions'
      USING ERRCODE = 'N1028', HINT = 'version.not_admin';
  END IF;
END $$;

CREATE FUNCTION mdm.create_version(p_name text, p_business_as_of date, p_base_version_id uuid, p_description text,
                                   p_actor uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm, public AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM mdm.version_require_admin(p_actor);
  PERFORM set_config('mdm.actor_id', p_actor::text, true);
  -- "Copy from" records the base only: no rows are copied (ADR-037 D2).
  INSERT INTO mdm.version (version_name, business_as_of, base_version_id, description, created_by)
  VALUES (p_name, p_business_as_of, p_base_version_id, p_description, p_actor)
  RETURNING version_id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION mdm.update_version(p_version_id uuid, p_name text, p_description text, p_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm, public AS $$
BEGIN
  PERFORM mdm.version_require_admin(p_actor);
  PERFORM set_config('mdm.actor_id', p_actor::text, true);
  UPDATE mdm.version SET version_name = p_name, description = p_description WHERE version_id = p_version_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Version % not found', p_version_id USING ERRCODE = 'P0002';
  END IF;
END $$;

CREATE FUNCTION mdm.transition_version(p_version_id uuid, p_to_status text, p_reason text, p_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm, public AS $$
DECLARE v mdm.version%ROWTYPE;
BEGIN
  PERFORM mdm.version_require_admin(p_actor);
  IF p_to_status IS NULL OR p_to_status NOT IN ('working', 'submitted', 'finalized', 'expired') THEN
    RAISE EXCEPTION 'A version cannot move to %', coalesce(p_to_status, 'nothing')
      USING ERRCODE = 'N2701', HINT = 'version.status_transition';
  END IF;
  IF p_to_status = 'submitted' THEN
    -- R2: exclusive, so no apply is between its last fact write and its commit while the pin is taken.
    PERFORM pg_advisory_xact_lock(11, 37);
  END IF;
  SELECT * INTO v FROM mdm.version WHERE version_id = p_version_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Version % not found', p_version_id USING ERRCODE = 'P0002';
  END IF;
  IF v.status::text = p_to_status THEN
    RAISE EXCEPTION 'Version % is already %', v.version_name, v.status
      USING ERRCODE = 'N2701', HINT = 'version.status_transition';
  END IF;

  PERFORM set_config('mdm.actor_id', p_actor::text, true);
  PERFORM set_config('mdm.version_reason', coalesce(p_reason, ''), true);
  CASE p_to_status
    WHEN 'submitted' THEN
      UPDATE mdm.version SET status = 'submitted', recorded_as_of = clock_timestamp(), submitted_at = clock_timestamp(),
                             submitted_by = p_actor
      WHERE version_id = p_version_id;
    WHEN 'working' THEN
      UPDATE mdm.version SET status = 'working', recorded_as_of = NULL, submitted_at = NULL, submitted_by = NULL
      WHERE version_id = p_version_id;
    WHEN 'finalized' THEN
      UPDATE mdm.version SET status = 'finalized', finalized_at = clock_timestamp(), finalized_by = p_actor
      WHERE version_id = p_version_id;
    ELSE
      UPDATE mdm.version SET status = 'expired' WHERE version_id = p_version_id;
  END CASE;
  PERFORM set_config('mdm.version_reason', '', true);
END $$;

REVOKE EXECUTE ON FUNCTION mdm.is_version_admin(uuid), mdm.version_require_admin(uuid),
                           mdm.create_version(text, date, uuid, text, uuid), mdm.update_version(uuid, text, text, uuid),
                           mdm.transition_version(uuid, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mdm.is_version_admin(uuid), mdm.create_version(text, date, uuid, text, uuid),
                          mdm.update_version(uuid, text, text, uuid), mdm.transition_version(uuid, text, text, uuid)
  TO nexus_api;

-- -----------------------------------------------------------------------------
-- NEXUS.VERSION_DATE (LLD V.5): a change that takes effect after its version's business date is not in that version's
-- picture. A warning, never run as an expression (level 'version', the NEXUS.TRIAL_APPLY pattern); the finding is
-- added by validate_change_request below.
-- -----------------------------------------------------------------------------
INSERT INTO mdm.validation_rule (rule_code, description, level, severity, engine, expression) VALUES
  ('NEXUS.VERSION_DATE', 'The change takes effect on or before its version''s business date, so it shows in that version (ADR-037)',
   'version', 'warning', 'sql', 'SELECT NULL::uuid AS node_id, NULL::uuid AS hierarchy_id, NULL::text AS message WHERE false');

-- validate_change_request: V1's function unchanged, except for the block marked "V11". CREATE OR REPLACE keeps its
-- owner (nexus_apply, V7) and its EXECUTE grants (V7, V9).
CREATE OR REPLACE FUNCTION mdm.validate_change_request(p_change_request_id uuid, p_as_of date)
RETURNS TABLE (rule_code text, severity text, node_id uuid, hierarchy_id uuid, message text, evaluated_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm, public AS $$
#variable_conflict use_column
DECLARE
  cr          mdm.change_request%ROWTYPE;
  it          mdm.change_item%ROWTYPE;
  r           mdm.validation_rule%ROWTYPE;
  v_at        timestamptz := clock_timestamp();
  v_trial     uuid;
  v_found     jsonb := '[]';
  v_seq       int;
  v_state     text;
  v_msg       text;
  v_detail    text;
  v_affected  uuid[];
  v_touched   uuid[];
  v_depth     int;
  v_vname     text;                                          -- V11
  v_vdate     date;                                          -- V11
BEGIN
  SELECT * INTO cr FROM mdm.change_request c WHERE c.change_request_id = p_change_request_id FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Change request % not found', p_change_request_id USING ERRCODE = 'N2102', HINT = 'change_request.not_found';
  END IF;
  IF cr.status NOT IN ('draft', 'submitted', 'in_review') THEN
    RAISE EXCEPTION 'Change request % is % and is no longer validated', p_change_request_id, cr.status
      USING ERRCODE = 'N2101', HINT = 'change_request.status_transition';
  END IF;
  SELECT rule_id INTO v_trial FROM mdm.validation_rule WHERE validation_rule.rule_code = 'NEXUS.TRIAL_APPLY';
  SELECT coalesce(max(setting_value::int), 50) INTO v_depth FROM mdm.system_setting WHERE setting_key = 'max_hierarchy_depth';

  -- Nodes the request touches, and their current parents (a parent losing a child can break a rule too).
  SELECT array_agg(DISTINCT x) INTO v_affected FROM (
    SELECT i.node_id AS x FROM mdm.apply_items_of(cr) i
    UNION SELECT i.target_parent_id FROM mdm.apply_items_of(cr) i
    UNION SELECT rel.parent_node_id FROM mdm.apply_items_of(cr) i
          JOIN mdm.hierarchy_relationship rel ON rel.child_node_id = i.node_id AND rel.hierarchy_id = i.hierarchy_id
           AND rel.valid_period @> cr.effective_from AND upper_inf(rel.recorded_period)) s WHERE x IS NOT NULL;
  SELECT array_agg(DISTINCT i.hierarchy_id) INTO v_touched FROM mdm.apply_items_of(cr) i WHERE i.hierarchy_id IS NOT NULL;

  BEGIN                                                          -- the trial: always rolled back (N9999)
    PERFORM set_config('mdm.change_request_id', p_change_request_id::text, true);
    PERFORM set_config('mdm.apply_date', cr.effective_from::text, true);
    PERFORM mdm.apply_check_limit(cr);
    FOR it IN SELECT * FROM mdm.apply_items_of(cr) LOOP
      v_seq := it.seq;
      PERFORM mdm.apply_item(it);
    END LOOP;
    v_seq := NULL;

    -- after the trial: new hierarchies, and everything below the touched nodes (moves carry descendants along)
    v_touched := coalesce(v_touched, '{}') || coalesce((SELECT array_agg(h.hierarchy_id) FROM mdm.hierarchy h
                   JOIN mdm.apply_items_of(cr) i ON i.action = 'add_hierarchy' AND h.top_node_id = i.node_id), '{}');
    WITH RECURSIVE down(node_id, depth) AS (
      SELECT unnest(coalesce(v_affected, '{}')), 0
      UNION
      SELECT rel.child_node_id, down.depth + 1 FROM mdm.hierarchy_relationship rel JOIN down ON rel.parent_node_id = down.node_id
      WHERE rel.hierarchy_id = ANY (v_touched) AND rel.valid_period @> cr.effective_from AND upper_inf(rel.recorded_period)
        AND down.depth < v_depth
    )
    SELECT array_agg(DISTINCT down.node_id) INTO v_affected FROM down;

    FOR r IN SELECT * FROM mdm.validation_rule vr
             WHERE vr.is_active AND vr.level IN ('node', 'hierarchy')
               AND (vr.hierarchy_id IS NULL OR vr.hierarchy_id = ANY (v_touched))
             ORDER BY vr.rule_code LOOP
      IF r.engine <> 'sql' THEN
        v_found := v_found || jsonb_build_object('rule_id', r.rule_id, 'severity', 'warning',
                     'message', format('Rule %s was not run: engine %s is not available yet (OD-19)', r.rule_code, r.engine));
        CONTINUE;
      END IF;
      BEGIN                                                      -- a broken rule is a finding, not a failed validation
        EXECUTE format('SELECT coalesce(jsonb_agg(jsonb_build_object(''node_id'', q.node_id, ''hierarchy_id'', q.hierarchy_id,
                                                   ''message'', q.message)), ''[]'')
                        FROM (%s) AS q(node_id, hierarchy_id, message)   -- the rule contract is positional
                        WHERE q.node_id = ANY ($3) OR (q.node_id IS NULL AND q.hierarchy_id = ANY ($4))', r.expression)
          INTO v_detail USING p_as_of, now(), v_affected, v_touched;
        SELECT v_found || coalesce(jsonb_agg(f || jsonb_build_object('rule_id', r.rule_id, 'severity', r.severity)), '[]')
          INTO v_found FROM jsonb_array_elements(v_detail::jsonb) f;
      EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_found := v_found || jsonb_build_object('rule_id', r.rule_id, 'severity', 'error',
                     'message', format('Rule %s could not be evaluated: %s', r.rule_code, v_msg));
      END;
    END LOOP;
    RAISE EXCEPTION 'trial rollback' USING ERRCODE = 'N9999';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
    IF v_state = 'N9999' THEN
      NULL;
    ELSIF mdm.apply_is_rule_failure(v_state) THEN
      SELECT coalesce(jsonb_build_object('node_id', i.node_id, 'hierarchy_id', i.hierarchy_id), '{}') INTO v_detail
      FROM mdm.apply_items_of(cr) i WHERE i.seq = v_seq;
      v_found := v_found || (coalesce(v_detail::jsonb, '{}') || jsonb_build_object('rule_id', v_trial, 'severity', 'error',
                   'message', v_state || ' (item ' || coalesce(v_seq::text, '-') || '): ' || v_msg));
    ELSE
      RAISE;
    END IF;
  END;

  -- V11 (ADR-037, LLD V.5): NEXUS.VERSION_DATE. A change dated after its version's business date is not in that
  -- version's picture. The request is still valid, so this is a warning; an administrator may deactivate the rule.
  SELECT vr.* INTO r FROM mdm.validation_rule vr WHERE vr.rule_code = 'NEXUS.VERSION_DATE' AND vr.is_active;
  IF FOUND THEN
    SELECT v.version_name, v.business_as_of INTO v_vname, v_vdate FROM mdm.version v WHERE v.version_id = cr.version_id;
    IF cr.effective_from > v_vdate THEN
      v_found := v_found || jsonb_build_object('rule_id', r.rule_id, 'severity', r.severity,
                   'message', format('This change takes effect on %s, after version %s''s date (%s), so it will not show in that version',
                                     to_char(cr.effective_from, 'FMDD Mon YYYY'), v_vname, to_char(v_vdate, 'FMDD Mon YYYY')));
    END IF;
  END IF;
  -- end V11

  INSERT INTO mdm.validation_result (rule_id, change_request_id, node_id, hierarchy_id, severity, message, evaluated_at)
  SELECT (f ->> 'rule_id')::uuid, p_change_request_id, (f ->> 'node_id')::uuid,
         (SELECT h.hierarchy_id FROM mdm.hierarchy h WHERE h.hierarchy_id = (f ->> 'hierarchy_id')::uuid),  -- a trial-only hierarchy is gone
         (f ->> 'severity')::validation_severity, f ->> 'message', v_at
  FROM jsonb_array_elements(v_found) f;

  RETURN QUERY
  SELECT vr.rule_code, (f ->> 'severity'), (f ->> 'node_id')::uuid, (f ->> 'hierarchy_id')::uuid, f ->> 'message', v_at
  FROM jsonb_array_elements(v_found) f JOIN mdm.validation_rule vr ON vr.rule_id = (f ->> 'rule_id')::uuid
  ORDER BY (f ->> 'severity') = 'error' DESC, vr.rule_code;
END $$;

