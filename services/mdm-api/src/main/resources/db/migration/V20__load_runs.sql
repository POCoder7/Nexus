-- =============================================================================
-- V20 — Load runs for the hackathon CSV data set (ADR-046; Phase 4 LLD §4.3, §6.1, §17.6 to §17.8; increment H-6).
-- A staged, clean load becomes a load run. One ADMIN prepares it (a manifest: the staged files' hashes, the target
-- version and the rule library); a second ADMIN approves the manifest; apply writes the configuration under the
-- approved run and drafts, submits, decides (as the approver) and applies one change request per step. Facts reach
-- mdm only through change requests (CLAUDE.md rule 3).
-- =============================================================================
SET search_path = mdm, public;

-- The loader's own identity: the requester of the data requests a load raises (requester kind system_feed, so import
-- rules run, C-4). It holds no role and decides nothing.
INSERT INTO mdm.app_user (login, display_name, kind) VALUES ('system.loader', 'Data loader', 'system_feed')
ON CONFLICT (login) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Load runs
-- -----------------------------------------------------------------------------
CREATE TABLE mdm.load_run (
  load_run_id         uuid PRIMARY KEY,                     -- the staging load_id (mdm_stage.intake_batch)
  kind                text NOT NULL DEFAULT 'csv_dataset' CHECK (kind IN ('csv_dataset')),
  status              text NOT NULL DEFAULT 'prepared'
                      CHECK (status IN ('prepared', 'approved', 'applying', 'applied', 'failed', 'cancelled')),
  target_version_name text NOT NULL,
  manifest_sha256     char(64) NOT NULL,
  plan                jsonb NOT NULL,                       -- what apply will do, step by step, with counts and skips
  prepared_by         uuid NOT NULL REFERENCES mdm.app_user,
  prepared_at         timestamptz NOT NULL DEFAULT now(),
  approved_by         uuid REFERENCES mdm.app_user,
  approved_at         timestamptz,
  finished_at         timestamptz,
  report              jsonb,                                -- reconciliation and per-step outcome
  error               text,
  CHECK (approved_by IS NULL OR approved_by <> prepared_by),  -- two people (OD-29)
  CHECK ((status IN ('prepared', 'cancelled')) OR approved_by IS NOT NULL)
);
CREATE TABLE mdm.load_run_request (
  load_run_id       uuid NOT NULL REFERENCES mdm.load_run,
  seq               int NOT NULL,
  step              text NOT NULL,
  change_request_id uuid NOT NULL UNIQUE REFERENCES mdm.change_request,
  PRIMARY KEY (load_run_id, seq)
);

-- Guard: the lifecycle, a human ADMIN approver who did not prepare the run, and a frozen manifest.
CREATE FUNCTION mdm.trg_load_run_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = mdm, public AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'prepared' OR NEW.approved_by IS NOT NULL THEN
      RAISE EXCEPTION 'A load run starts prepared and unapproved' USING ERRCODE = 'N2814', HINT = 'load.status_transition';
    END IF;
    IF NOT mdm.holds_role(NEW.prepared_by, 'ADMIN', mdm.business_today()) THEN
      RAISE EXCEPTION 'Only an ADMIN can prepare a load' USING ERRCODE = 'N1035', HINT = 'load.not_admin';
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.load_run_id, NEW.kind, NEW.target_version_name, NEW.manifest_sha256, NEW.plan, NEW.prepared_by, NEW.prepared_at)
     IS DISTINCT FROM (OLD.load_run_id, OLD.kind, OLD.target_version_name, OLD.manifest_sha256, OLD.plan, OLD.prepared_by,
                       OLD.prepared_at) THEN
    RAISE EXCEPTION 'A prepared load run cannot change; prepare a new one' USING ERRCODE = 'N2814', HINT = 'load.frozen';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'prepared' AND NEW.status IN ('approved', 'cancelled'))
    OR (OLD.status = 'approved' AND NEW.status IN ('applying', 'cancelled'))
    OR (OLD.status = 'applying' AND NEW.status IN ('applied', 'failed'))) THEN
    RAISE EXCEPTION 'A load run cannot go from % to %', OLD.status, NEW.status USING ERRCODE = 'N2814', HINT = 'load.status_transition';
  END IF;
  IF NEW.approved_by IS DISTINCT FROM OLD.approved_by THEN
    IF OLD.approved_by IS NOT NULL OR NEW.status <> 'approved' THEN
      RAISE EXCEPTION 'A load run is approved once' USING ERRCODE = 'N2814', HINT = 'load.status_transition';
    END IF;
    IF NOT mdm.holds_role(NEW.approved_by, 'ADMIN', mdm.business_today())
       OR (SELECT kind FROM mdm.app_user WHERE user_id = NEW.approved_by) <> 'human' THEN
      RAISE EXCEPTION 'A load run is approved by a person who is an ADMIN' USING ERRCODE = 'N1035', HINT = 'load.not_admin';
    END IF;
    IF NEW.approved_by = NEW.prepared_by THEN
      RAISE EXCEPTION 'The ADMIN who prepared a load cannot approve it' USING ERRCODE = 'N1001', HINT = 'maker_checker.self_decision';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER load_run_guard BEFORE INSERT OR UPDATE ON mdm.load_run FOR EACH ROW EXECUTE FUNCTION mdm.trg_load_run_guard();
CREATE TRIGGER load_run_audit AFTER INSERT OR UPDATE OR DELETE ON mdm.load_run FOR EACH ROW EXECUTE FUNCTION mdm.trg_audit_row();
CREATE TRIGGER load_run_request_audit AFTER INSERT ON mdm.load_run_request FOR EACH ROW EXECUTE FUNCTION mdm.trg_audit_row();
GRANT INSERT, UPDATE (status, approved_by, approved_at, finished_at, report, error) ON mdm.load_run TO nexus_api;
GRANT INSERT ON mdm.load_run_request TO nexus_api;

-- -----------------------------------------------------------------------------
-- How the data set's core rules map onto the database guards (ADR-046 D5, LLD §17.5): such a rule names a guard
-- that already exists, so the load relabels the guard instead of adding a second copy of the rule. Fixed and reviewed.
-- -----------------------------------------------------------------------------
CREATE TABLE mdm.load_rule_guard_map (
  external_code text PRIMARY KEY,
  guard_rule    text NOT NULL REFERENCES mdm.validation_rule (rule_code)
);
INSERT INTO mdm.load_rule_guard_map VALUES
  ('VR02', 'NEXUS.NODE_NAME_UNIQUE'), ('VR05', 'NEXUS.PARENT_MISSING'), ('VR06', 'NEXUS.PARENT_IS_LEAF'),
  ('VR07', 'NEXUS.HIERARCHY_CYCLE'), ('VR08', 'NEXUS.PROPERTY_LIST_VALUE');

-- -----------------------------------------------------------------------------
-- add_node may create an inactive node (the data set's status column): payload "active", default true. V1's handler
-- otherwise unchanged; CREATE OR REPLACE keeps its owner and grants.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mdm.apply_add_node(p_item mdm.change_item)
RETURNS int LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE v_rows int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM mdm.node WHERE node_id = p_item.node_id)
     OR EXISTS (SELECT 1 FROM mdm.node_attr WHERE node_id = p_item.node_id) THEN
    RAISE EXCEPTION 'Item %: node % must be a new identity without attributes', p_item.seq, p_item.node_id
      USING ERRCODE = 'N2105', HINT = 'apply.item_invalid';
  END IF;
  v_rows := mdm.apply_fact('node_attr', NULL, jsonb_build_object('node_id', p_item.node_id),
              jsonb_build_object('node_name', p_item.payload ->> 'name',
                                 'display_name', p_item.payload ->> 'displayName',
                                 'description', p_item.payload ->> 'description',
                                 'is_active', coalesce((p_item.payload ->> 'active')::boolean, true),     -- V20
                                 'allows_children', NOT coalesce((p_item.payload ->> 'isLeaf')::boolean, false)),
              NULL, false);
  RETURN v_rows + mdm.apply_place(p_item, true, NULL);
END $$;

-- -----------------------------------------------------------------------------
-- provision_user (LLD §17.7): the one way, outside migrations, to create an app_user. ADMIN only; audited. A user
-- that already exists is left as it is (the load reuses it).
-- -----------------------------------------------------------------------------
CREATE TRIGGER app_user_audit AFTER INSERT OR UPDATE OR DELETE ON mdm.app_user FOR EACH ROW EXECUTE FUNCTION mdm.trg_audit_row();
CREATE FUNCTION mdm.provision_user(p_login text, p_display_name text, p_kind text, p_actor uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm, public AS $$
DECLARE v uuid;
BEGIN
  IF NOT mdm.holds_role(p_actor, 'ADMIN', mdm.business_today()) THEN
    RAISE EXCEPTION 'Only an ADMIN can add users' USING ERRCODE = 'N1035', HINT = 'load.not_admin';
  END IF;
  IF p_kind NOT IN ('human', 'service') OR coalesce(btrim(p_login), '') = '' OR coalesce(btrim(p_display_name), '') = '' THEN
    RAISE EXCEPTION 'A user needs a login, a display name and the kind human or service'
      USING ERRCODE = 'N2815', HINT = 'load.user_invalid';
  END IF;
  SELECT user_id INTO v FROM mdm.app_user WHERE login = p_login;
  IF v IS NULL THEN
    PERFORM set_config('mdm.actor_id', p_actor::text, true);
    INSERT INTO mdm.app_user (login, display_name, kind) VALUES (p_login, p_display_name, p_kind::mdm.requester_kind)
    RETURNING user_id INTO v;
  END IF;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION mdm.provision_user(text, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mdm.provision_user(text, text, text, uuid) TO nexus_api;

-- The run must be applying and the caller its approver: configuration is written only under an approved run.
CREATE FUNCTION mdm.load_require_applying(p_run uuid, p_actor uuid)
RETURNS void LANGUAGE plpgsql SET search_path = mdm, public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM mdm.load_run WHERE load_run_id = p_run AND status = 'applying' AND approved_by = p_actor) THEN
    RAISE EXCEPTION 'Load run % is not being applied by its approver', p_run USING ERRCODE = 'N2814', HINT = 'load.not_approved';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- load_apply_definitions: the configuration of an approved run (LLD §17.1, §17.4, §17.5, §17.7): categories, property
-- definitions (derived ones skipped, D6), list values copied per property (D3), ledgers, users, the guard labels of
-- mapped core rules, and the other rules (FEED skipped) with their expressions from the rule library p_library
-- ({code: sql}); a rule with no library entry is stored inactive with the never-matching expression. Runs as the
-- schema owner, guarded by the approved run; reads mdm_stage, writes configuration only (no facts).
-- -----------------------------------------------------------------------------
CREATE FUNCTION mdm.load_apply_definitions(p_run uuid, p_actor uuid, p_library jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm, mdm_stage, public AS $$
DECLARE
  v_counts jsonb := '{}';
  v_n      int;
  v_never  text := 'SELECT NULL::uuid AS node_id, NULL::uuid AS hierarchy_id, NULL::text AS message WHERE false';
  u        record;
BEGIN
  PERFORM mdm.load_require_applying(p_run, p_actor);
  PERFORM set_config('mdm.actor_id', p_actor::text, true);

  CREATE TEMP TABLE ld_ad ON COMMIT DROP AS
    SELECT s.* FROM mdm_stage.hx_attribute_definition s JOIN mdm_stage.intake_batch b USING (batch_id)
    WHERE b.load_id = p_run AND s.derivation IS NULL;
  CREATE TEMP TABLE ld_rl ON COMMIT DROP AS
    SELECT s.* FROM mdm_stage.hx_reference_list s JOIN mdm_stage.intake_batch b USING (batch_id) WHERE b.load_id = p_run;

  INSERT INTO mdm.property_category (category_code, name)
  SELECT DISTINCT category, category FROM ld_ad WHERE category IS NOT NULL ON CONFLICT (category_code) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT; v_counts := v_counts || jsonb_build_object('categories', v_n);

  INSERT INTO mdm.property_definition (property_code, label, category_code, data_type, scope, inheritance, default_value,
                                       max_length, is_required, description, node_filter)
  SELECT d.attribute_code, d.label, d.category, t.data_type::mdm.property_data_type, lower(d.scope)::mdm.property_scope,
         CASE WHEN upper(coalesce(d.inherited, 'N')) = 'Y' THEN 'inherit_from_ancestor' ELSE 'none' END::mdm.inheritance_mode,
         CASE WHEN d.default_value IS NULL THEN NULL
              WHEN t.data_type = 'boolean' THEN to_jsonb(upper(d.default_value) = 'Y')
              WHEN t.data_type IN ('integer', 'decimal') AND d.default_value ~ '^-?[0-9]+(\.[0-9]+)?$' THEN to_jsonb(d.default_value::numeric)
              ELSE to_jsonb(d.default_value) END,
         d.max_length::int, upper(coalesce(d.required, 'N')) = 'Y', d.description, lower(coalesce(d.node_filter, 'any'))
  FROM ld_ad d
  CROSS JOIN LATERAL (SELECT CASE WHEN lower(d.data_type) = 'boolean' THEN 'boolean'
                                  WHEN d.reference_list IS NOT NULL THEN 'list'
                                  ELSE lower(d.data_type) END AS data_type) t;
  GET DIAGNOSTICS v_n = ROW_COUNT; v_counts := v_counts || jsonb_build_object('properties', v_n);

  INSERT INTO mdm.property_list_value (property_id, list_value, label, sort_seq)
  SELECT pd.property_id, l.value, l.label, row_number() OVER (PARTITION BY pd.property_id ORDER BY l.line_no)
  FROM ld_ad d JOIN mdm.property_definition pd ON pd.property_code = d.attribute_code AND pd.data_type = 'list'
  JOIN ld_rl l ON l.list_code = d.reference_list;
  GET DIAGNOSTICS v_n = ROW_COUNT; v_counts := v_counts || jsonb_build_object('listValues', v_n);

  INSERT INTO mdm.ledger (ledger_id, ledger_name, currency_code, finance_country)
  SELECT s.ledger_id, s.ledger_name, s.currency, s.finance_country
  FROM mdm_stage.hx_ledger s JOIN mdm_stage.intake_batch b USING (batch_id) WHERE b.load_id = p_run;
  GET DIAGNOSTICS v_n = ROW_COUNT; v_counts := v_counts || jsonb_build_object('ledgers', v_n);

  v_n := 0;
  FOR u IN SELECT s.* FROM mdm_stage.hx_user s JOIN mdm_stage.intake_batch b USING (batch_id) WHERE b.load_id = p_run
           AND NOT EXISTS (SELECT 1 FROM mdm.app_user a WHERE a.login = s.user_id) LOOP
    PERFORM mdm.provision_user(u.user_id, u.display_name,
              CASE WHEN upper(u.role) = 'CONSUMER' OR u.user_id LIKE 'svc\_%' THEN 'service' ELSE 'human' END, p_actor);
    v_n := v_n + 1;
  END LOOP;
  v_counts := v_counts || jsonb_build_object('users', v_n);

  -- core rules: relabel the guard they name
  UPDATE mdm.validation_rule vr SET external_code = r.rule_code, rule_name = r.rule_name, description = coalesce(r.description, vr.description)
  FROM mdm_stage.hx_validation_rule r JOIN mdm_stage.intake_batch b USING (batch_id)
  JOIN mdm.load_rule_guard_map m ON m.external_code = r.rule_code
  WHERE b.load_id = p_run AND vr.rule_code = m.guard_rule;
  GET DIAGNOSTICS v_n = ROW_COUNT; v_counts := v_counts || jsonb_build_object('guardsLabelled', v_n);

  -- other rules: the library's expression, or stored inactive
  INSERT INTO mdm.validation_rule (rule_code, rule_name, description, level, severity, engine, expression, mode,
                                   external_code, is_active)
  SELECT r.rule_code, r.rule_name, coalesce(r.description, r.rule_name, r.rule_code), lower(r.level)::mdm.validation_level,
         lower(r.severity)::mdm.validation_severity, 'sql', coalesce(p_library ->> r.rule_code, v_never),
         lower(coalesce(r.mode, 'both')), r.rule_code, p_library ? r.rule_code
  FROM mdm_stage.hx_validation_rule r JOIN mdm_stage.intake_batch b USING (batch_id)
  WHERE b.load_id = p_run AND upper(r.level) <> 'FEED'
    AND NOT EXISTS (SELECT 1 FROM mdm.load_rule_guard_map m WHERE m.external_code = r.rule_code);
  GET DIAGNOSTICS v_n = ROW_COUNT; v_counts := v_counts || jsonb_build_object('rules', v_n);
  RETURN v_counts;
END $$;

-- After the hierarchies exist: the hierarchies each property applies to (D2) and the hierarchy of each rule.
CREATE FUNCTION mdm.load_apply_scopes(p_run uuid, p_actor uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm, mdm_stage, public AS $$
DECLARE v_props int; v_rules int;
BEGIN
  PERFORM mdm.load_require_applying(p_run, p_actor);
  PERFORM set_config('mdm.actor_id', p_actor::text, true);
  INSERT INTO mdm.property_hierarchy (property_id, hierarchy_id)
  SELECT DISTINCT pd.property_id, h.hierarchy_id
  FROM mdm_stage.hx_attribute_definition d JOIN mdm_stage.intake_batch b USING (batch_id)
  CROSS JOIN LATERAL unnest(string_to_array(d.hierarchies, ';')) x(code)
  JOIN mdm.property_definition pd ON pd.property_code = d.attribute_code
  JOIN mdm.hierarchy h ON h.hierarchy_code = btrim(x.code)
  WHERE b.load_id = p_run AND d.derivation IS NULL
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_props = ROW_COUNT;
  UPDATE mdm.validation_rule vr SET hierarchy_id = h.hierarchy_id
  FROM mdm_stage.hx_validation_rule r JOIN mdm_stage.intake_batch b USING (batch_id), mdm.hierarchy h
  WHERE b.load_id = p_run AND vr.rule_code = r.rule_code AND vr.enforcement = 'rule'
    AND upper(coalesce(r.applies_to, 'ALL')) <> 'ALL' AND h.hierarchy_code = r.applies_to;
  GET DIAGNOSTICS v_rules = ROW_COUNT;
  RETURN jsonb_build_object('propertyHierarchies', v_props, 'ruleScopes', v_rules);
END $$;

REVOKE EXECUTE ON FUNCTION mdm.load_apply_definitions(uuid, uuid, jsonb), mdm.load_apply_scopes(uuid, uuid),
                           mdm.load_require_applying(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mdm.load_apply_definitions(uuid, uuid, jsonb), mdm.load_apply_scopes(uuid, uuid) TO nexus_api;

-- -----------------------------------------------------------------------------
-- profile_against_nexus: what a staged load would collide with in Nexus (run after mdm_stage.profile). Codes that
-- exist are errors, except users (reused) and groups with the same role (kept; their missing scopes and members are
-- added). A core rule that names no guard is an error. Owned by the loader, like profile.
-- -----------------------------------------------------------------------------
CREATE FUNCTION mdm_stage.profile_against_nexus(p_load uuid)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm_stage, mdm, public AS $$
DECLARE v_errors int;
BEGIN
  DELETE FROM mdm_stage.profile_finding WHERE load_id = p_load AND kind IN ('exists', 'kept', 'core_rule');
  INSERT INTO mdm_stage.profile_finding (load_id, file_name, line_no, severity, kind, detail)
  SELECT p_load, x.file_name, x.line_no, x.severity, x.kind, x.detail FROM (
    SELECT 'hierarchies.csv' AS file_name, s.line_no, 'error' AS severity, 'exists' AS kind,
           format('hierarchy %s already exists in Nexus', s.hierarchy_code) AS detail
    FROM mdm_stage.hx_hierarchy s JOIN mdm_stage.intake_batch b USING (batch_id)
    WHERE b.load_id = p_load AND EXISTS (SELECT 1 FROM mdm.hierarchy h WHERE h.hierarchy_code = s.hierarchy_code)
    UNION ALL
    SELECT 'nodes.csv', s.line_no, 'error', 'exists', format('node %s already exists in Nexus', s.node_code)
    FROM mdm_stage.hx_node s JOIN mdm_stage.intake_batch b USING (batch_id)
    WHERE b.load_id = p_load AND EXISTS (SELECT 1 FROM mdm.node_attr a WHERE a.node_name = s.node_code AND upper_inf(a.recorded_period))
    UNION ALL
    SELECT 'attribute_definitions.csv', s.line_no, 'error', 'exists', format('attribute %s already exists in Nexus', s.attribute_code)
    FROM mdm_stage.hx_attribute_definition s JOIN mdm_stage.intake_batch b USING (batch_id)
    WHERE b.load_id = p_load AND s.derivation IS NULL
      AND EXISTS (SELECT 1 FROM mdm.property_definition p WHERE p.property_code = s.attribute_code)
    UNION ALL
    SELECT 'ledgers.csv', s.line_no, 'error', 'exists', format('ledger %s already exists in Nexus', s.ledger_id)
    FROM mdm_stage.hx_ledger s JOIN mdm_stage.intake_batch b USING (batch_id)
    WHERE b.load_id = p_load AND EXISTS (SELECT 1 FROM mdm.ledger l WHERE l.ledger_id = s.ledger_id)
    UNION ALL
    SELECT 'validation_rules.csv', s.line_no, 'error', 'exists', format('rule %s already exists in Nexus', s.rule_code)
    FROM mdm_stage.hx_validation_rule s JOIN mdm_stage.intake_batch b USING (batch_id)
    WHERE b.load_id = p_load AND upper(s.level) <> 'FEED'
      AND NOT EXISTS (SELECT 1 FROM mdm.load_rule_guard_map m WHERE m.external_code = s.rule_code)
      AND EXISTS (SELECT 1 FROM mdm.validation_rule v WHERE v.rule_code = s.rule_code OR v.external_code = s.rule_code)
    UNION ALL
    SELECT 'validation_rules.csv', s.line_no, 'error', 'core_rule',
           format('%s is a core rule but names no database guard Nexus knows', s.rule_code)
    FROM mdm_stage.hx_validation_rule s JOIN mdm_stage.intake_batch b USING (batch_id)
    WHERE b.load_id = p_load AND upper(coalesce(s.core_path, 'N')) = 'Y'
      AND NOT EXISTS (SELECT 1 FROM mdm.load_rule_guard_map m WHERE m.external_code = s.rule_code)
    UNION ALL
    SELECT 'validation_rules.csv', s.line_no, 'info', 'kept', format('%s is the database guard %s: its labels are taken from the file', s.rule_code, m.guard_rule)
    FROM mdm_stage.hx_validation_rule s JOIN mdm_stage.intake_batch b USING (batch_id)
    JOIN mdm.load_rule_guard_map m ON m.external_code = s.rule_code WHERE b.load_id = p_load
    UNION ALL
    SELECT 'versions.csv', s.line_no, 'error', 'exists', format('version %s already exists in Nexus', s.version_name)
    FROM mdm_stage.hx_version s JOIN mdm_stage.intake_batch b USING (batch_id)
    WHERE b.load_id = p_load AND EXISTS (SELECT 1 FROM mdm.version v WHERE v.version_name = s.version_name)
    UNION ALL
    SELECT 'groups.csv', s.line_no, 'error', 'exists', format('group %s already exists in Nexus with the role %s', s.group_code, g.role_code)
    FROM mdm_stage.hx_group s JOIN mdm_stage.intake_batch b USING (batch_id)
    JOIN mdm.user_group g ON g.group_code = s.group_code WHERE b.load_id = p_load AND g.role_code IS DISTINCT FROM upper(s.role)
    UNION ALL
    SELECT 'groups.csv', s.line_no, 'info', 'kept', format('group %s already exists: it is kept and its missing scopes and members are added', s.group_code)
    FROM mdm_stage.hx_group s JOIN mdm_stage.intake_batch b USING (batch_id)
    JOIN mdm.user_group g ON g.group_code = s.group_code WHERE b.load_id = p_load AND g.role_code = upper(s.role)
    UNION ALL
    SELECT 'users.csv', s.line_no, 'info', 'kept', format('user %s already exists: it is kept', s.user_id)
    FROM mdm_stage.hx_user s JOIN mdm_stage.intake_batch b USING (batch_id)
    WHERE b.load_id = p_load AND EXISTS (SELECT 1 FROM mdm.app_user a WHERE a.login = s.user_id)
  ) x;
  SELECT count(*) INTO v_errors FROM mdm_stage.profile_finding WHERE load_id = p_load AND severity = 'error';
  RETURN v_errors;
END $$;
ALTER FUNCTION mdm_stage.profile_against_nexus(uuid) OWNER TO nexus_loader;
REVOKE EXECUTE ON FUNCTION mdm_stage.profile_against_nexus(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mdm_stage.profile_against_nexus(uuid) TO nexus_api;
GRANT SELECT ON mdm.load_rule_guard_map, mdm.load_run, mdm.load_run_request TO nexus_loader;
