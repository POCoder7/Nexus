-- =============================================================================
-- V19 — Staging and profiling for the hackathon CSV data set (ADR-046; Phase 4 LLD §17.1, §17.8.2; increment H-5).
-- The 12 files are staged as text, row by row with their line numbers, then profiled. Nothing here touches governed
-- data: H-6 turns a clean staged load into change requests. mdm_stage is written only by the loader role
-- (CLAUDE.md rule 3); the API reaches it through the two functions below, which nexus_loader owns.
-- =============================================================================
SET search_path = mdm_stage, mdm, public;

-- -----------------------------------------------------------------------------
-- The loader role (ADR-026). A group role like the others in V7: logins are created per environment.
-- It reads mdm (to resolve codes) and writes mdm_stage only.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nexus_loader') THEN
    CREATE ROLE nexus_loader NOLOGIN;
  END IF;
END $$;
GRANT USAGE ON SCHEMA mdm, mdm_stage TO nexus_loader;
GRANT SELECT ON ALL TABLES IN SCHEMA mdm TO nexus_loader;
ALTER DEFAULT PRIVILEGES IN SCHEMA mdm GRANT SELECT ON TABLES TO nexus_loader;
GRANT USAGE ON SCHEMA mdm_stage TO nexus_api;               -- the API reads what was staged and the findings

-- -----------------------------------------------------------------------------
-- The fixed file formats (the hackathon team's; ADR-046), as data: file name, staging table and columns in order.
-- A file must match its header exactly (case and surrounding spaces aside).
-- -----------------------------------------------------------------------------
CREATE TABLE mdm_stage.hx_file (
  file_name   text PRIMARY KEY,
  stage_table text NOT NULL UNIQUE,
  columns     text[] NOT NULL,
  required    boolean NOT NULL,
  load_order  int NOT NULL
);
INSERT INTO mdm_stage.hx_file VALUES
  ('roles.csv',                 'hx_role',                 '{role,permissions}', false, 1),
  ('ledgers.csv',               'hx_ledger',               '{ledger_id,ledger_name,currency,finance_country}', false, 2),
  ('reference_lists.csv',       'hx_reference_list',       '{list_code,value,label}', false, 3),
  ('attribute_definitions.csv', 'hx_attribute_definition', '{attribute_code,label,category,data_type,scope,hierarchies,node_filter,required,reference_list,inherited,default_value,derivation,max_length,description}', false, 4),
  ('validation_rules.csv',      'hx_validation_rule',      '{rule_code,rule_name,description,level,mode,severity,applies_to,core_path}', false, 5),
  ('versions.csv',              'hx_version',              '{version_code,version_name,status,description}', false, 6),
  ('hierarchies.csv',           'hx_hierarchy',            '{hierarchy_code,hierarchy_name,top_node_code,description}', true, 7),
  ('nodes.csv',                 'hx_node',                 '{node_code,node_name,description,node_type,status}', true, 8),
  ('relationships.csv',         'hx_relationship',         '{hierarchy_code,parent_code,child_code,sort_order}', true, 9),
  ('attribute_values.csv',      'hx_attribute_value',      '{node_code,hierarchy_code,attribute_code,value}', false, 10),
  ('groups.csv',                'hx_group',                '{group_code,role,hierarchies}', false, 11),
  ('users.csv',                 'hx_user',                 '{user_id,display_name,role,groups,notes}', false, 12);

-- One row per staged file of a load. load_id groups the files of one load (the load run of H-6).
CREATE TABLE mdm_stage.intake_batch (
  batch_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  load_id     uuid NOT NULL,
  file_name   text NOT NULL REFERENCES mdm_stage.hx_file,
  file_sha256 char(64) NOT NULL,
  row_count   int NOT NULL,
  loaded_at   timestamptz NOT NULL DEFAULT now(),
  loaded_by   uuid NOT NULL REFERENCES mdm.app_user,
  UNIQUE (load_id, file_name)
);

-- The staged rows: every column text as read (trimmed; blank = NULL), with the file's line number (the header is 1).
DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT * FROM mdm_stage.hx_file LOOP
    EXECUTE format('CREATE TABLE mdm_stage.%I (batch_id uuid NOT NULL REFERENCES mdm_stage.intake_batch ON DELETE CASCADE, '
                   'line_no int NOT NULL, %s, PRIMARY KEY (batch_id, line_no))',
                   f.stage_table, (SELECT string_agg(format('%I text', c), ', ') FROM unnest(f.columns) c));
  END LOOP;
END $$;

-- What profiling found. severity error blocks preparing the load (H-6); warning and info are shown.
CREATE TABLE mdm_stage.profile_finding (
  finding_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  load_id    uuid NOT NULL,
  file_name  text,
  line_no    int,
  severity   text NOT NULL CHECK (severity IN ('error', 'warning', 'info')),
  kind       text NOT NULL,
  detail     text NOT NULL
);
CREATE INDEX ON mdm_stage.profile_finding (load_id, severity);

GRANT SELECT ON ALL TABLES IN SCHEMA mdm_stage TO nexus_api, nexus_loader;
GRANT INSERT, DELETE ON ALL TABLES IN SCHEMA mdm_stage TO nexus_loader;

-- -----------------------------------------------------------------------------
-- stage_file: stages one file of a load (replacing an earlier copy of the same file in that load). p_rows is a JSON
-- array of rows, each an array of text fields, without the header. A wrong header, or an unknown file name, refuses the
-- file; a row with the wrong number of fields is not staged and is recorded as an error finding.
-- -----------------------------------------------------------------------------
CREATE FUNCTION mdm_stage.stage_file(p_load uuid, p_file text, p_sha256 text, p_actor uuid, p_header text[], p_rows jsonb)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm_stage, mdm, public AS $$
DECLARE
  f       mdm_stage.hx_file%ROWTYPE;
  v_batch uuid;
  v_rows  int;
BEGIN
  SELECT * INTO f FROM mdm_stage.hx_file WHERE file_name = lower(btrim(p_file));
  IF NOT FOUND THEN
    RAISE EXCEPTION 'File % is not part of the data set (expected one of %)', p_file,
      (SELECT string_agg(file_name, ', ' ORDER BY load_order) FROM mdm_stage.hx_file)
      USING ERRCODE = 'N2812', HINT = 'load.unknown_file';
  END IF;
  IF (SELECT array_agg(lower(btrim(h)) ORDER BY o) FROM unnest(p_header) WITH ORDINALITY AS x(h, o)) IS DISTINCT FROM f.columns THEN
    RAISE EXCEPTION 'File % has the header %, expected %', f.file_name, array_to_string(p_header, ','),
      array_to_string(f.columns, ',') USING ERRCODE = 'N2813', HINT = 'load.header_mismatch';
  END IF;
  IF jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'Rows must be a JSON array of arrays' USING ERRCODE = 'N2813', HINT = 'load.header_mismatch';
  END IF;

  DELETE FROM mdm_stage.intake_batch WHERE load_id = p_load AND file_name = f.file_name;   -- rows go with it (cascade)
  DELETE FROM mdm_stage.profile_finding WHERE load_id = p_load AND file_name = f.file_name AND kind = 'row_width';
  INSERT INTO mdm_stage.intake_batch (load_id, file_name, file_sha256, row_count, loaded_by)
  VALUES (p_load, f.file_name, p_sha256, jsonb_array_length(p_rows), p_actor) RETURNING batch_id INTO v_batch;

  INSERT INTO mdm_stage.profile_finding (load_id, file_name, line_no, severity, kind, detail)
  SELECT p_load, f.file_name, (o.n + 1)::int, 'error', 'row_width',
         format('The row has %s fields; the header has %s', jsonb_array_length(o.r), cardinality(f.columns))
  FROM jsonb_array_elements(p_rows) WITH ORDINALITY AS o(r, n)
  WHERE jsonb_typeof(o.r) <> 'array' OR jsonb_array_length(o.r) <> cardinality(f.columns);

  EXECUTE format('INSERT INTO mdm_stage.%I (batch_id, line_no, %s) '
                 'SELECT $1, (o.n + 1)::int, %s FROM jsonb_array_elements($2) WITH ORDINALITY AS o(r, n) '
                 'WHERE jsonb_typeof(o.r) = ''array'' AND jsonb_array_length(o.r) = %s',
                 f.stage_table,
                 (SELECT string_agg(format('%I', c), ', ' ORDER BY i) FROM unnest(f.columns) WITH ORDINALITY AS x(c, i)),
                 (SELECT string_agg(format('nullif(btrim(o.r ->> %s), %L)', i - 1, ''), ', ' ORDER BY i)
                  FROM unnest(f.columns) WITH ORDINALITY AS x(c, i)),
                 cardinality(f.columns))
    USING v_batch, p_rows;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END $$;

-- -----------------------------------------------------------------------------
-- profile: checks a staged load as a whole and records findings (replacing earlier ones, except row widths, which
-- stage_file records). Returns the number of errors; any error blocks preparing the load. Codes are compared as written
-- (they are business keys); enumerations ignore case. Deterministic SQL, no model (CLAUDE.md rule 4).
-- -----------------------------------------------------------------------------
CREATE FUNCTION mdm_stage.profile(p_load uuid)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = mdm_stage, mdm, public AS $$
DECLARE v_errors int;
BEGIN
  DELETE FROM mdm_stage.profile_finding WHERE load_id = p_load AND kind <> 'row_width';

  IF to_regclass('pg_temp.hx_f') IS NULL THEN
    CREATE TEMP TABLE hx_f (file_name text, line_no int, severity text, kind text, detail text) ON COMMIT DROP;
  ELSE
    TRUNCATE hx_f;
  END IF;

  -- the staged rows of this load, one temporary view per file (EXECUTE: a view definition takes no variables)
  EXECUTE (SELECT string_agg(format('CREATE TEMP VIEW %I AS SELECT s.* FROM mdm_stage.%I s JOIN mdm_stage.intake_batch b USING (batch_id) WHERE b.load_id = %L',
                                    v.alias, v.stage_table, p_load), '; ')
           FROM (VALUES ('hx_h', 'hx_hierarchy'), ('hx_n', 'hx_node'), ('hx_r', 'hx_relationship'),
                        ('hx_ad', 'hx_attribute_definition'), ('hx_av', 'hx_attribute_value'), ('hx_rl', 'hx_reference_list'),
                        ('hx_l', 'hx_ledger'), ('hx_vr', 'hx_validation_rule'), ('hx_v', 'hx_version'),
                        ('hx_u', 'hx_user'), ('hx_g', 'hx_group'), ('hx_ro', 'hx_role')) AS v(alias, stage_table));

  -- files: the three required ones must be there
  INSERT INTO hx_f SELECT f.file_name, NULL, 'error', 'missing_file', format('%s is required', f.file_name)
  FROM mdm_stage.hx_file f WHERE f.required
    AND NOT EXISTS (SELECT 1 FROM mdm_stage.intake_batch b WHERE b.load_id = p_load AND b.file_name = f.file_name);

  -- required fields
  INSERT INTO hx_f
  SELECT 'hierarchies.csv', line_no, 'error', 'required', 'hierarchy_code, hierarchy_name and top_node_code are required'
    FROM hx_h WHERE hierarchy_code IS NULL OR hierarchy_name IS NULL OR top_node_code IS NULL
  UNION ALL SELECT 'nodes.csv', line_no, 'error', 'required', 'node_code, node_type and status are required'
    FROM hx_n WHERE node_code IS NULL OR node_type IS NULL OR status IS NULL
  UNION ALL SELECT 'relationships.csv', line_no, 'error', 'required', 'hierarchy_code and child_code are required'
    FROM hx_r WHERE hierarchy_code IS NULL OR child_code IS NULL
  UNION ALL SELECT 'attribute_definitions.csv', line_no, 'error', 'required', 'attribute_code, label, data_type and scope are required'
    FROM hx_ad WHERE attribute_code IS NULL OR label IS NULL OR data_type IS NULL OR scope IS NULL
  UNION ALL SELECT 'attribute_values.csv', line_no, 'error', 'required', 'node_code and attribute_code are required'
    FROM hx_av WHERE node_code IS NULL OR attribute_code IS NULL
  UNION ALL SELECT 'reference_lists.csv', line_no, 'error', 'required', 'list_code and value are required'
    FROM hx_rl WHERE list_code IS NULL OR value IS NULL
  UNION ALL SELECT 'ledgers.csv', line_no, 'error', 'required', 'ledger_id, ledger_name, currency and finance_country are required'
    FROM hx_l WHERE ledger_id IS NULL OR ledger_name IS NULL OR currency IS NULL OR finance_country IS NULL
  UNION ALL SELECT 'validation_rules.csv', line_no, 'error', 'required', 'rule_code, level and severity are required'
    FROM hx_vr WHERE rule_code IS NULL OR level IS NULL OR severity IS NULL
  UNION ALL SELECT 'versions.csv', line_no, 'error', 'required', 'version_code, version_name and status are required'
    FROM hx_v WHERE version_code IS NULL OR version_name IS NULL OR status IS NULL
  UNION ALL SELECT 'users.csv', line_no, 'error', 'required', 'user_id, display_name and role are required'
    FROM hx_u WHERE user_id IS NULL OR display_name IS NULL OR role IS NULL
  UNION ALL SELECT 'groups.csv', line_no, 'error', 'required', 'group_code and role are required'
    FROM hx_g WHERE group_code IS NULL OR role IS NULL
  UNION ALL SELECT 'roles.csv', line_no, 'error', 'required', 'role is required' FROM hx_ro WHERE role IS NULL;

  -- duplicate keys (VR02 for nodes: a code is unique within the load)
  INSERT INTO hx_f
  SELECT file, line_no, 'error', 'duplicate', format('%s %s appears more than once', what, k) FROM (
    SELECT 'hierarchies.csv' AS file, line_no, 'hierarchy_code' AS what, hierarchy_code AS k, count(*) OVER (PARTITION BY hierarchy_code) AS c FROM hx_h WHERE hierarchy_code IS NOT NULL
    UNION ALL SELECT 'nodes.csv', line_no, 'node_code', node_code, count(*) OVER (PARTITION BY node_code) FROM hx_n WHERE node_code IS NOT NULL
    UNION ALL SELECT 'attribute_definitions.csv', line_no, 'attribute_code', attribute_code, count(*) OVER (PARTITION BY attribute_code) FROM hx_ad WHERE attribute_code IS NOT NULL
    UNION ALL SELECT 'reference_lists.csv', line_no, 'list value', list_code || '/' || value, count(*) OVER (PARTITION BY list_code, value) FROM hx_rl WHERE list_code IS NOT NULL AND value IS NOT NULL
    UNION ALL SELECT 'ledgers.csv', line_no, 'ledger_id', ledger_id, count(*) OVER (PARTITION BY ledger_id) FROM hx_l WHERE ledger_id IS NOT NULL
    UNION ALL SELECT 'validation_rules.csv', line_no, 'rule_code', rule_code, count(*) OVER (PARTITION BY rule_code) FROM hx_vr WHERE rule_code IS NOT NULL
    UNION ALL SELECT 'versions.csv', line_no, 'version_code', version_code, count(*) OVER (PARTITION BY version_code) FROM hx_v WHERE version_code IS NOT NULL
    UNION ALL SELECT 'users.csv', line_no, 'user_id', user_id, count(*) OVER (PARTITION BY user_id) FROM hx_u WHERE user_id IS NOT NULL
    UNION ALL SELECT 'groups.csv', line_no, 'group_code', group_code, count(*) OVER (PARTITION BY group_code) FROM hx_g WHERE group_code IS NOT NULL
    UNION ALL SELECT 'relationships.csv', line_no, 'placement', hierarchy_code || ': ' || coalesce(parent_code, '(top)') || ' > ' || child_code,
                     count(*) OVER (PARTITION BY hierarchy_code, parent_code, child_code) FROM hx_r WHERE child_code IS NOT NULL
    UNION ALL SELECT 'attribute_values.csv', line_no, 'value', node_code || '/' || coalesce(hierarchy_code, '(global)') || '/' || attribute_code,
                     count(*) OVER (PARTITION BY node_code, hierarchy_code, attribute_code) FROM hx_av WHERE node_code IS NOT NULL AND attribute_code IS NOT NULL
  ) d WHERE c > 1;

  -- enumerations
  INSERT INTO hx_f
  SELECT 'nodes.csv', line_no, 'error', 'value', format('node_type %s must be LEAF or LIMB', node_type) FROM hx_n WHERE upper(node_type) NOT IN ('LEAF', 'LIMB')
  UNION ALL SELECT 'nodes.csv', line_no, 'error', 'value', format('status %s must be active or inactive', status) FROM hx_n WHERE lower(status) NOT IN ('active', 'inactive')
  UNION ALL SELECT 'attribute_definitions.csv', line_no, 'error', 'value', format('data_type %s is not one Nexus stores', data_type)
    FROM hx_ad WHERE lower(data_type) NOT IN ('string', 'memo', 'integer', 'decimal', 'boolean', 'date', 'datetime', 'list')
  UNION ALL SELECT 'attribute_definitions.csv', line_no, 'error', 'value', format('scope %s must be GLOBAL or LOCAL', scope) FROM hx_ad WHERE upper(scope) NOT IN ('GLOBAL', 'LOCAL')
  UNION ALL SELECT 'attribute_definitions.csv', line_no, 'error', 'value', format('node_filter %s must be ANY, LEAF or LIMB', node_filter)
    FROM hx_ad WHERE node_filter IS NOT NULL AND upper(node_filter) NOT IN ('ANY', 'LEAF', 'LIMB')
  UNION ALL SELECT 'attribute_definitions.csv', line_no, 'error', 'value', 'required and inherited must be Y or N'
    FROM hx_ad WHERE upper(coalesce(required, 'N')) NOT IN ('Y', 'N') OR upper(coalesce(inherited, 'N')) NOT IN ('Y', 'N')
  UNION ALL SELECT 'attribute_definitions.csv', line_no, 'error', 'value', format('max_length %s must be a whole number', max_length)
    FROM hx_ad WHERE max_length IS NOT NULL AND max_length !~ '^[0-9]+$'
  UNION ALL SELECT 'validation_rules.csv', line_no, 'error', 'value', format('level %s must be NODE, HIERARCHY, VERSION or FEED', level)
    FROM hx_vr WHERE upper(level) NOT IN ('NODE', 'HIERARCHY', 'VERSION', 'FEED')
  UNION ALL SELECT 'validation_rules.csv', line_no, 'error', 'value', format('mode %s must be IMPORT, REAL_TIME or BOTH', mode)
    FROM hx_vr WHERE mode IS NOT NULL AND upper(mode) NOT IN ('IMPORT', 'REAL_TIME', 'BOTH')
  UNION ALL SELECT 'validation_rules.csv', line_no, 'error', 'value', format('severity %s must be ERROR, WARNING or INFO', severity)
    FROM hx_vr WHERE upper(severity) NOT IN ('ERROR', 'WARNING', 'INFO')
  UNION ALL SELECT 'validation_rules.csv', line_no, 'error', 'value', 'core_path must be Y or N' FROM hx_vr WHERE upper(coalesce(core_path, 'N')) NOT IN ('Y', 'N')
  UNION ALL SELECT 'versions.csv', line_no, 'error', 'value', format('status %s must be working, finalized or expired', status)
    FROM hx_v WHERE lower(status) NOT IN ('working', 'finalized', 'expired')
  UNION ALL SELECT 'ledgers.csv', line_no, 'error', 'value', format('currency %s must be three upper-case letters', currency) FROM hx_l WHERE currency !~ '^[A-Z]{3}$'
  UNION ALL SELECT 'ledgers.csv', line_no, 'error', 'value', format('ledger_id %s must be 1 to 20 characters without spaces', ledger_id) FROM hx_l WHERE ledger_id !~ '^\S{1,20}$'
  UNION ALL SELECT 'relationships.csv', line_no, 'error', 'value', format('sort_order %s must be a number', sort_order)
    FROM hx_r WHERE sort_order IS NOT NULL AND sort_order !~ '^-?[0-9]+(\.[0-9]+)?$'
  UNION ALL SELECT 'users.csv', line_no, 'error', 'value', format('role %s is not a Nexus role', role) FROM hx_u WHERE upper(role) NOT IN (SELECT role_code FROM mdm.role)
  UNION ALL SELECT 'groups.csv', line_no, 'error', 'value', format('role %s is not a Nexus role', role) FROM hx_g WHERE upper(role) NOT IN (SELECT role_code FROM mdm.role)
  UNION ALL SELECT 'roles.csv', line_no, 'error', 'value', format('role %s is not a Nexus role (VIEWER, EDITOR, APPROVER, ADMIN, CONSUMER)', role)
    FROM hx_ro WHERE upper(role) NOT IN (SELECT role_code FROM mdm.role);

  -- references between files
  INSERT INTO hx_f
  SELECT 'hierarchies.csv', h.line_no, 'error', 'reference', format('top node %s is not in nodes.csv', h.top_node_code)
    FROM hx_h h WHERE h.top_node_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM hx_n n WHERE n.node_code = h.top_node_code)
  UNION ALL SELECT 'relationships.csv', r.line_no, 'error', 'reference', format('hierarchy %s is not in hierarchies.csv', r.hierarchy_code)
    FROM hx_r r WHERE r.hierarchy_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM hx_h h WHERE h.hierarchy_code = r.hierarchy_code)
  UNION ALL SELECT 'relationships.csv', r.line_no, 'error', 'reference', format('node %s is not in nodes.csv', x.code)
    FROM hx_r r CROSS JOIN LATERAL (VALUES (r.parent_code), (r.child_code)) x(code)
    WHERE x.code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM hx_n n WHERE n.node_code = x.code)
  -- the top node: the row with no parent must be the hierarchy's top_node_code, and every hierarchy needs one
  UNION ALL SELECT 'relationships.csv', r.line_no, 'error', 'top_node', format('%s has no parent but the top node of %s is %s', r.child_code, r.hierarchy_code, h.top_node_code)
    FROM hx_r r JOIN hx_h h ON h.hierarchy_code = r.hierarchy_code WHERE r.parent_code IS NULL AND r.child_code IS DISTINCT FROM h.top_node_code
  UNION ALL SELECT 'relationships.csv', h.line_no, 'warning', 'top_node', format('%s has no row with a blank parent; its top node %s is used', h.hierarchy_code, h.top_node_code)
    FROM hx_h h WHERE NOT EXISTS (SELECT 1 FROM hx_r r WHERE r.hierarchy_code = h.hierarchy_code AND r.parent_code IS NULL)
  -- VR06 PARENT_IS_LIMB: a leaf cannot have children
  UNION ALL SELECT 'relationships.csv', r.line_no, 'error', 'parent_is_leaf', format('parent %s is a LEAF', r.parent_code)
    FROM hx_r r JOIN hx_n n ON n.node_code = r.parent_code WHERE upper(n.node_type) = 'LEAF'
  UNION ALL SELECT 'attribute_values.csv', v.line_no, 'error', 'reference', format('node %s is not in nodes.csv', v.node_code)
    FROM hx_av v WHERE v.node_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM hx_n n WHERE n.node_code = v.node_code)
  UNION ALL SELECT 'attribute_values.csv', v.line_no, 'error', 'reference', format('attribute %s is not in attribute_definitions.csv', v.attribute_code)
    FROM hx_av v WHERE v.attribute_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM hx_ad d WHERE d.attribute_code = v.attribute_code)
  UNION ALL SELECT 'attribute_values.csv', v.line_no, 'error', 'reference', format('hierarchy %s is not in hierarchies.csv', v.hierarchy_code)
    FROM hx_av v WHERE v.hierarchy_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM hx_h h WHERE h.hierarchy_code = v.hierarchy_code)
  UNION ALL SELECT 'attribute_definitions.csv', d.line_no, 'error', 'reference', format('reference list %s is not in reference_lists.csv', d.reference_list)
    FROM hx_ad d WHERE d.reference_list IS NOT NULL AND lower(d.data_type) <> 'boolean'
      AND NOT EXISTS (SELECT 1 FROM hx_rl l WHERE l.list_code = d.reference_list)
  UNION ALL SELECT 'attribute_definitions.csv', d.line_no, 'error', 'reference', format('hierarchy %s is not in hierarchies.csv', x.code)
    FROM hx_ad d CROSS JOIN LATERAL unnest(string_to_array(d.hierarchies, ';')) x(code)
    WHERE btrim(x.code) <> '' AND NOT EXISTS (SELECT 1 FROM hx_h h WHERE h.hierarchy_code = btrim(x.code))
  UNION ALL SELECT 'validation_rules.csv', r.line_no, 'error', 'reference', format('applies_to %s is ALL or a hierarchy in hierarchies.csv', r.applies_to)
    FROM hx_vr r WHERE r.applies_to IS NOT NULL AND upper(r.applies_to) <> 'ALL' AND NOT EXISTS (SELECT 1 FROM hx_h h WHERE h.hierarchy_code = r.applies_to)
  UNION ALL SELECT 'groups.csv', g.line_no, 'error', 'reference', format('hierarchy %s is not in hierarchies.csv', x.code)
    FROM hx_g g CROSS JOIN LATERAL unnest(string_to_array(g.hierarchies, ';')) x(code)
    WHERE btrim(x.code) <> '' AND NOT EXISTS (SELECT 1 FROM hx_h h WHERE h.hierarchy_code = btrim(x.code))
  UNION ALL SELECT 'users.csv', u.line_no, 'error', 'reference', format('group %s is not in groups.csv', x.code)
    FROM hx_u u CROSS JOIN LATERAL unnest(string_to_array(u.groups, ';')) x(code)
    WHERE btrim(x.code) NOT IN ('', 'ALL') AND NOT EXISTS (SELECT 1 FROM hx_g g WHERE g.group_code = btrim(x.code));

  -- attribute values against their definitions: scope, Y/N for booleans, list values
  INSERT INTO hx_f
  SELECT 'attribute_values.csv', v.line_no, 'error', 'scope', format('%s is GLOBAL: leave hierarchy_code blank', v.attribute_code)
    FROM hx_av v JOIN hx_ad d ON d.attribute_code = v.attribute_code WHERE upper(d.scope) = 'GLOBAL' AND v.hierarchy_code IS NOT NULL
  UNION ALL SELECT 'attribute_values.csv', v.line_no, 'error', 'scope', format('%s is LOCAL: hierarchy_code is required', v.attribute_code)
    FROM hx_av v JOIN hx_ad d ON d.attribute_code = v.attribute_code WHERE upper(d.scope) = 'LOCAL' AND v.hierarchy_code IS NULL
  UNION ALL SELECT 'attribute_values.csv', v.line_no, 'error', 'value', format('%s is BOOLEAN: the value must be Y or N', v.attribute_code)
    FROM hx_av v JOIN hx_ad d ON d.attribute_code = v.attribute_code WHERE lower(d.data_type) = 'boolean' AND upper(coalesce(v.value, '')) NOT IN ('Y', 'N', '')
  -- VR08 REFERENCE_VALUE
  UNION ALL SELECT 'attribute_values.csv', v.line_no, 'error', 'list_value', format('%s value %s is not in list %s', v.attribute_code, v.value, d.reference_list)
    FROM hx_av v JOIN hx_ad d ON d.attribute_code = v.attribute_code
    WHERE d.reference_list IS NOT NULL AND lower(d.data_type) <> 'boolean' AND v.value IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM hx_rl l WHERE l.list_code = d.reference_list AND l.value = v.value)
  UNION ALL SELECT 'attribute_values.csv', v.line_no, 'error', 'derived', format('%s is derived and cannot be stored', v.attribute_code)
    FROM hx_av v JOIN hx_ad d ON d.attribute_code = v.attribute_code WHERE d.derivation IS NOT NULL;

  -- notices: what the load will leave out (ADR-046 D3, D5, D6, D7), and data worth a look
  INSERT INTO hx_f
  SELECT 'attribute_definitions.csv', line_no, 'info', 'skipped', format('%s is derived: not loaded now (ADR-046 D6)', attribute_code)
    FROM hx_ad WHERE derivation IS NOT NULL
  UNION ALL SELECT 'validation_rules.csv', line_no, 'info', 'skipped', format('%s is a FEED rule: not loaded now (ADR-046 D5)', rule_code)
    FROM hx_vr WHERE upper(level) = 'FEED'
  UNION ALL SELECT 'versions.csv', NULL, 'warning', 'versions', 'More than one version is working; the load goes to the one you choose, or the latest working one'
    WHERE (SELECT count(*) FROM hx_v WHERE lower(status) = 'working') > 1
  UNION ALL SELECT 'ledgers.csv', l.line_no, 'warning', 'ledger_list', format('ledger %s is not a value of the LEDGER reference list', l.ledger_id)
    FROM hx_l l WHERE EXISTS (SELECT 1 FROM hx_rl WHERE list_code = 'LEDGER')
      AND NOT EXISTS (SELECT 1 FROM hx_rl r WHERE r.list_code = 'LEDGER' AND r.value = l.ledger_id)
  UNION ALL SELECT 'nodes.csv', n.line_no, 'warning', 'unplaced', format('node %s is not placed in any hierarchy', n.node_code)
    FROM hx_n n WHERE NOT EXISTS (SELECT 1 FROM hx_r r WHERE r.child_code = n.node_code)
      AND NOT EXISTS (SELECT 1 FROM hx_h h WHERE h.top_node_code = n.node_code);

  INSERT INTO mdm_stage.profile_finding (load_id, file_name, line_no, severity, kind, detail)
  SELECT p_load, file_name, line_no, severity, kind, detail FROM hx_f;

  DROP VIEW hx_h, hx_n, hx_r, hx_ad, hx_av, hx_rl, hx_l, hx_vr, hx_v, hx_u, hx_g, hx_ro;
  SELECT count(*) INTO v_errors FROM mdm_stage.profile_finding WHERE load_id = p_load AND severity = 'error';
  RETURN v_errors;
END $$;

-- Staging and profiling run with the loader's rights; the API calls them (LLD §17.8.2: no loader credential in the API).
ALTER FUNCTION mdm_stage.stage_file(uuid, text, text, uuid, text[], jsonb) OWNER TO nexus_loader;
ALTER FUNCTION mdm_stage.profile(uuid) OWNER TO nexus_loader;
REVOKE EXECUTE ON FUNCTION mdm_stage.stage_file(uuid, text, text, uuid, text[], jsonb), mdm_stage.profile(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mdm_stage.stage_file(uuid, text, text, uuid, text[], jsonb), mdm_stage.profile(uuid) TO nexus_api;
