-- =============================================================================
-- V18 — One rule catalogue (ADR-046 D5; Phase 4 LLD §17.5; increment H-4). mdm.validation_rule becomes the one place
-- that lists every data rule: configured rules (SQL expressions, run by validate_change_request) and the database
-- guards (triggers and constraints, enforced on every write). Guard rows describe a guard; they never switch it off.
-- =============================================================================
SET search_path = mdm, public;

-- -----------------------------------------------------------------------------
-- Columns. mode: when a configured rule runs (real_time = interactive requests, import = requests raised by a load,
-- both). enforcement: rule (validate_change_request runs the expression) or guard (the database enforces it; the row
-- names the guard by guard_code, an SQLSTATE such as N2001 or a constraint name). external_code: the customer's id
-- for the rule (the hackathon data set's VR07), so their rule list maps onto this one.
-- -----------------------------------------------------------------------------
ALTER TABLE mdm.validation_rule
  ADD COLUMN rule_name     text,
  ADD COLUMN external_code text UNIQUE,
  ADD COLUMN mode          text NOT NULL DEFAULT 'both' CHECK (mode IN ('real_time', 'import', 'both')),
  ADD COLUMN enforcement   text NOT NULL DEFAULT 'rule' CHECK (enforcement IN ('rule', 'guard')),
  ADD COLUMN guard_code    text UNIQUE,
  ADD CONSTRAINT validation_rule_guard_has_code CHECK ((enforcement = 'guard') = (guard_code IS NOT NULL));

UPDATE mdm.validation_rule SET rule_name = 'Request applies cleanly' WHERE rule_code = 'NEXUS.TRIAL_APPLY';
UPDATE mdm.validation_rule SET rule_name = 'Change shows in its version' WHERE rule_code = 'NEXUS.VERSION_DATE';
UPDATE mdm.validation_rule SET rule_name = 'Ownership at most 100%' WHERE rule_code = 'OWN_SUM_LE_100';

-- -----------------------------------------------------------------------------
-- The data guards, one row each. The expression is the never-matching one NEXUS.TRIAL_APPLY uses: a guard row is
-- never run as a rule. Governance controls (maker-checker, human-only decisions, N1xxx) are controls on decisions, not
-- data rules, and are not listed here.
-- -----------------------------------------------------------------------------
INSERT INTO mdm.validation_rule (rule_code, rule_name, description, level, severity, engine, expression, mode, enforcement, guard_code)
SELECT g.code, g.name, g.description, g.level::mdm.validation_level, 'error', 'sql',
       'SELECT NULL::uuid AS node_id, NULL::uuid AS hierarchy_id, NULL::text AS message WHERE false',
       'real_time', 'guard', g.guard
FROM (VALUES
  ('NEXUS.HIERARCHY_CYCLE',        'No cycles',                    'hierarchy', 'N2001',
   'A node cannot be placed under itself or one of its descendants'),
  ('NEXUS.TOP_NODE',               'Top node stays the top',       'hierarchy', 'N2002',
   'The top node of a hierarchy cannot be placed under another node, removed or deleted'),
  ('NEXUS.SHARED_NOT_ALLOWED',     'Shared nodes allowed',         'hierarchy', 'N2003',
   'A node can have a second (shared) placement only in a hierarchy that allows shared nodes'),
  ('NEXUS.PARENT_IS_LEAF',         'Parent is a limb',             'node',      'N2004',
   'The parent node must be a limb: a leaf cannot have children'),
  ('NEXUS.REMOVE_WITH_CHILDREN',   'Remove only without children', 'hierarchy', 'N2005',
   'A node with children cannot be removed from a hierarchy unless its children are removed with it'),
  ('NEXUS.NODE_REFERENCED',        'Referenced nodes stay',        'node',      'N2006',
   'A node that another node''s property refers to cannot be deleted'),
  ('NEXUS.PARENT_MISSING',         'Parent exists',                'node',      'N2007',
   'The parent node must be in the target hierarchy on the change''s date'),
  ('NEXUS.PROPERTY_SCOPE',         'Property scope',               'node',      'N2020',
   'A global property has no hierarchy; a local property needs one'),
  ('NEXUS.PROPERTY_DERIVED',       'Derived values are not stored','node',      'N2021',
   'A derived property is calculated and cannot be stored'),
  ('NEXUS.PROPERTY_TYPE',          'Property data type',           'node',      'N2022',
   'A value must match its property''s data type and maximum length'),
  ('NEXUS.PROPERTY_LIST_VALUE',    'Value in its list',            'node',      'N2023',
   'A list property''s value must be one of its active list values'),
  ('NEXUS.PROPERTY_NODE_REF',      'Referenced node exists',       'node',      'N2024',
   'A node reference must point to an existing node'),
  ('NEXUS.PROPERTY_NOT_APPLICABLE','Property applies',             'node',      'N2025',
   'A value can be stored only where its property applies: its hierarchies and its kind of node (leaf or limb)'),
  ('NEXUS.STALE_BASE',             'No stale changes',             'node',      'N3001',
   'A change applies only if what it was drafted against has not changed since'),
  ('NEXUS.NODE_NAME_UNIQUE',       'Node name unique',             'node',      'node_attr_node_name_valid_period_excl',
   'A node name (the business key, e.g. a code) belongs to one node at a time'),
  ('NEXUS.HIERARCHY_CODE_UNIQUE',  'Hierarchy code unique',        'hierarchy', 'hierarchy_hierarchy_code_key',
   'A hierarchy code belongs to one hierarchy')
) AS g(code, name, level, guard, description);

-- -----------------------------------------------------------------------------
-- Guard rows are fixed (CLAUDE.md rule 1): only the database owner (migrations) adds or changes them. Anyone else may
-- relabel one (rule_name, description, external_code) and nothing more; no one but the owner deletes one or turns a
-- rule into a guard or back. A new guard; no existing guard changes.
-- -----------------------------------------------------------------------------
CREATE FUNCTION mdm.trg_validation_rule_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = mdm, public AS $$
BEGIN
  IF current_user = (SELECT pg_get_userbyid(c.relowner) FROM pg_class c WHERE c.oid = 'mdm.validation_rule'::regclass) THEN
    RETURN COALESCE(NEW, OLD);
  END IF;
  IF TG_OP = 'DELETE' AND OLD.enforcement = 'guard' THEN
    RAISE EXCEPTION 'Rule % describes a database guard and cannot be deleted', OLD.rule_code
      USING ERRCODE = 'N2811', HINT = 'validation_rule.guard_fixed';
  END IF;
  IF TG_OP = 'INSERT' AND NEW.enforcement = 'guard' THEN
    RAISE EXCEPTION 'Guard rows are added by migrations only (%)', NEW.rule_code
      USING ERRCODE = 'N2811', HINT = 'validation_rule.guard_fixed';
  END IF;
  IF TG_OP = 'UPDATE' AND (OLD.enforcement = 'guard' OR NEW.enforcement = 'guard')
     AND (to_jsonb(NEW) - ARRAY['rule_name', 'description', 'external_code'])
         IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['rule_name', 'description', 'external_code']) THEN
    RAISE EXCEPTION 'Rule % describes a database guard: only its name, description and external code can change', OLD.rule_code
      USING ERRCODE = 'N2811', HINT = 'validation_rule.guard_fixed';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;

CREATE TRIGGER validation_rule_guard BEFORE INSERT OR UPDATE OR DELETE ON mdm.validation_rule
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_validation_rule_guard();
CREATE TRIGGER validation_rule_audit AFTER INSERT OR UPDATE OR DELETE ON mdm.validation_rule
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_audit_row();

-- The API edits rules for an ADMIN (PATCH /admin/validation-rules/{code}, C-3); the trigger above keeps guard rows to
-- their labels. Rules are not deleted through the API: they are deactivated.
GRANT UPDATE (rule_name, description, external_code, is_active, severity, mode, expression, hierarchy_id, rule_version)
  ON mdm.validation_rule TO nexus_api;

-- -----------------------------------------------------------------------------
-- N2007 (ADR-046): "parent not in hierarchy" gets its own code instead of the shared N2105, so its catalogue row
-- (NEXUS.PARENT_MISSING) can name it. The check is unchanged. CREATE OR REPLACE keeps V1's owner and grants.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mdm.apply_require_parent(p_hierarchy uuid, p_parent uuid, p_d date)
RETURNS void LANGUAGE plpgsql SET search_path = mdm, public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM mdm.hierarchy WHERE hierarchy_id = p_hierarchy AND top_node_id = p_parent)
     AND NOT EXISTS (SELECT 1 FROM mdm.hierarchy_relationship r
                     WHERE r.hierarchy_id = p_hierarchy AND r.child_node_id = p_parent
                       AND r.valid_period @> p_d AND upper_inf(r.recorded_period)) THEN
    RAISE EXCEPTION 'Parent % is not in hierarchy % on %', p_parent, p_hierarchy, p_d
      USING ERRCODE = 'N2007', HINT = 'hierarchy.parent_missing';
  END IF;
  IF NOT coalesce((SELECT a.allows_children FROM mdm.node_attr a WHERE a.node_id = p_parent
                   AND a.valid_period @> p_d AND upper_inf(a.recorded_period)), false) THEN
    RAISE EXCEPTION 'Parent % is a leaf on % and cannot have children', p_parent, p_d
      USING ERRCODE = 'N2004', HINT = 'hierarchy.parent_is_leaf';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- validate_change_request: V11's function unchanged, except the blocks marked "V18":
--   * the rule loop runs configured rules only (guard rows are never run), and by mode: real_time rules for
--     interactive requests, import rules for requests a load raised (requester kind system_feed, C-4), both for both;
--   * a guard failure in the trial is reported under the guard's own row (by SQLSTATE, or by constraint name for
--     23P01 and 23505), falling back to NEXUS.TRIAL_APPLY. The finding itself (severity, message, node) is unchanged.
-- CREATE OR REPLACE keeps its owner (nexus_apply, V7) and its EXECUTE grants (V7, V9).
-- -----------------------------------------------------------------------------
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
  v_import    boolean;                                       -- V18
  v_constraint text;                                         -- V18
  v_rule      uuid;                                          -- V18
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
  v_import := cr.requester_kind = 'system_feed';             -- V18

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
    PERFORM set_config('mdm.sandbox_capture', '', true);         -- V12 (5-1b): a validation never writes an overlay
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
               AND vr.enforcement = 'rule'                                                       -- V18
               AND (vr.mode = 'both' OR (vr.mode = 'import') = v_import)                        -- V18
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
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL,
                            v_constraint = CONSTRAINT_NAME;                                     -- V18
    IF v_state = 'N9999' THEN
      NULL;
    ELSIF mdm.apply_is_rule_failure(v_state) THEN
      -- V18: report under the guard's own catalogue row when there is one
      SELECT vr.rule_id INTO v_rule FROM mdm.validation_rule vr
      WHERE vr.enforcement = 'guard'
        AND vr.guard_code = CASE WHEN v_state IN ('23P01', '23505') THEN v_constraint ELSE v_state END;
      SELECT coalesce(jsonb_build_object('node_id', i.node_id, 'hierarchy_id', i.hierarchy_id), '{}') INTO v_detail
      FROM mdm.apply_items_of(cr) i WHERE i.seq = v_seq;
      v_found := v_found || (coalesce(v_detail::jsonb, '{}') || jsonb_build_object('rule_id', coalesce(v_rule, v_trial),
                   'severity', 'error', 'message', v_state || ' (item ' || coalesce(v_seq::text, '-') || '): ' || v_msg));
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
