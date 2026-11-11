-- =============================================================================
-- AI-enabled MDM — 03: DRM EXPORT COMPATIBILITY, RECONCILIATION, MIGRATION STAGING
--
-- Goal: reproduce today's DRM export files byte-for-byte, so downstream
-- systems (EPM, ERP, data warehouse, regulatory) need no changes at cutover,
-- and so the parallel run can be reconciled automatically by file hash.
--
-- DRM concept                    -> New model
-- ------------------------------------------------------------------------------
-- Version                        -> version (business_as_of + recorded_as_of slice)
-- Hierarchy / Top node / Group   -> hierarchy (top_node_id, hierarchy_group)
-- Node (Core.Name, Description)  -> node + node_attr (bitemporal, renames tracked)
-- Leaf / limb                    -> node_attr.allows_children; is_leaf derived per hierarchy
-- Inactive node                  -> node_attr.is_active
-- Parent-child relationship      -> hierarchy_relationship (sort_order, is_primary)
-- Shared node                    -> hierarchy_relationship.is_primary = false
-- Global / local property        -> property_definition.scope
-- Inherited property / override  -> property_definition.inheritance + property_value_asof()
-- Derived property (formula)     -> property_definition.derivation_expr (+ drm_formula_orig)
-- Property category / list       -> property_category / property_list_value
-- Validation                     -> validation_rule (+ drm_validation_orig)
-- Query (node filter)            -> export_profile.node_filter (declarative JSON)
-- Export (hierarchy, generation) -> export_profile + export_profile_column
-- DRG request / workflow         -> change_request + change_item (maker-checker)
-- Transaction log                -> audit_log
-- =============================================================================
SET search_path = mdm, public;

CREATE TYPE drm_export_type AS ENUM (
  'hierarchy',        -- one row per node: parent/child plus properties      (implemented below)
  'generation',       -- one row per node: ancestors spread across columns    (implemented below)
  'compare', 'difference', 'transaction_log', 'version'   -- implement in the export service
);

-- -----------------------------------------------------------------------------
-- Export profiles  (one row per DRM export definition)
-- -----------------------------------------------------------------------------
CREATE TABLE export_profile (
  export_profile_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_code             text NOT NULL UNIQUE,
  profile_name             text NOT NULL,
  drm_export_name          text,                  -- original DRM export, for traceability
  export_type              drm_export_type NOT NULL,
  hierarchy_id             uuid NOT NULL REFERENCES hierarchy,
  top_node_override        uuid REFERENCES node,  -- export a sub-tree
  include_top_node         boolean NOT NULL DEFAULT true,
  leaf_only                boolean NOT NULL DEFAULT false,
  include_shared_nodes     boolean NOT NULL DEFAULT true,
  include_inactive         boolean NOT NULL DEFAULT false,
  max_level                int CHECK (max_level > 0),
  -- AND-ed conditions, e.g. [{"property":"Custom.Reportable","op":"=","value":true}]
  -- ops: =, <>, in, not_in, is_null, not_null
  node_filter              jsonb NOT NULL DEFAULT '[]',
  -- file format: match the current DRM output exactly
  delimiter                text NOT NULL DEFAULT ',',
  quote_char               text DEFAULT '"',
  quote_mode               text NOT NULL DEFAULT 'minimal' CHECK (quote_mode IN ('minimal', 'all', 'none')),
  include_header           boolean NOT NULL DEFAULT true,
  line_ending              text NOT NULL DEFAULT E'\n',
  trailing_line_ending     boolean NOT NULL DEFAULT true,
  encoding                 text NOT NULL DEFAULT 'UTF8',
  true_token               text NOT NULL DEFAULT 'True',
  false_token              text NOT NULL DEFAULT 'False',
  null_token               text NOT NULL DEFAULT '',
  multi_value_separator    text NOT NULL DEFAULT ';',
  generation_header_prefix text NOT NULL DEFAULT 'Gen',
  generation_pad_mode      text NOT NULL DEFAULT 'blank' CHECK (generation_pad_mode IN ('blank', 'repeat_last')),
  output_file_pattern      text,                  -- e.g. 'LE_Hierarchy_{version}_{yyyymmdd}.csv'
  target_system            text,                  -- downstream consumer, for the cutover plan
  owner_team               text,
  is_active                boolean NOT NULL DEFAULT true
);

CREATE TABLE export_profile_column (
  export_profile_id uuid NOT NULL REFERENCES export_profile ON DELETE CASCADE,
  seq               int  NOT NULL,
  header_label      text NOT NULL,
  column_source     text NOT NULL CHECK (column_source IN (
                      'node_name', 'description', 'parent_name', 'level', 'is_leaf',
                      'sort_order', 'hierarchy_code', 'static', 'property', 'parent_property')),
  property_id       uuid REFERENCES property_definition,
  static_value      text,
  format_mask       text,                         -- to_char mask for dates and numbers
  PRIMARY KEY (export_profile_id, seq),
  CHECK (column_source NOT IN ('property', 'parent_property') OR property_id IS NOT NULL),
  CHECK (column_source <> 'static' OR static_value IS NOT NULL)
);

-- -----------------------------------------------------------------------------
-- Tree walk as of a version slice (shared nodes expand their sub-trees, as in DRM)
-- -----------------------------------------------------------------------------
CREATE FUNCTION hierarchy_tree(
  p_hierarchy_id   uuid,
  p_as_of          date,
  p_recorded_as_of timestamptz DEFAULT now(),
  p_top_node_id    uuid        DEFAULT NULL
)
RETURNS TABLE (node_id uuid, parent_node_id uuid, level int, sort_order numeric, is_primary boolean,
               is_leaf boolean, path uuid[], name_path text[], sort_path numeric[])
LANGUAGE sql STABLE SET search_path = mdm, public AS $$
WITH RECURSIVE
rel AS (
  SELECT r.parent_node_id, r.child_node_id, r.sort_order, r.is_primary
  FROM hierarchy_relationship r
  WHERE r.hierarchy_id = p_hierarchy_id
    AND r.valid_period    @> p_as_of
    AND r.recorded_period @> p_recorded_as_of
),
nm AS (
  SELECT a.node_id, a.node_name
  FROM node_attr a
  WHERE a.valid_period @> p_as_of AND a.recorded_period @> p_recorded_as_of
),
top AS (
  SELECT coalesce(p_top_node_id, h.top_node_id) AS node_id
  FROM hierarchy h WHERE h.hierarchy_id = p_hierarchy_id
),
t AS (
  SELECT top.node_id, NULL::uuid AS parent_node_id, 1 AS level, 0::numeric AS sort_order,
         true AS is_primary, ARRAY[top.node_id] AS path,
         ARRAY[nm.node_name] AS name_path, ARRAY[0::numeric] AS sort_path
  FROM top LEFT JOIN nm ON nm.node_id = top.node_id
  UNION ALL
  SELECT rel.child_node_id, rel.parent_node_id, t.level + 1, rel.sort_order, rel.is_primary,
         t.path || rel.child_node_id, t.name_path || nm.node_name, t.sort_path || rel.sort_order
  FROM t
  JOIN rel ON rel.parent_node_id = t.node_id
  LEFT JOIN nm ON nm.node_id = rel.child_node_id
  WHERE NOT rel.child_node_id = ANY (t.path)
)
SELECT t.node_id, t.parent_node_id, t.level, t.sort_order, t.is_primary,
       NOT EXISTS (SELECT 1 FROM rel r2 WHERE r2.parent_node_id = t.node_id),
       t.path, t.name_path, t.sort_path
FROM t
$$;

-- -----------------------------------------------------------------------------
-- Property resolution: stored value -> inherited from primary ancestors -> default.
-- Derived properties are evaluated here only for the 'sql' engine; CEL and
-- Python derivations run in the rules service.
-- -----------------------------------------------------------------------------
CREATE FUNCTION property_value_asof(
  p_node_id        uuid,
  p_property_id    uuid,
  p_hierarchy_id   uuid,
  p_as_of          date,
  p_recorded_as_of timestamptz DEFAULT now()
)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = mdm, public AS $$
DECLARE
  d     property_definition%ROWTYPE;
  v_h   uuid;
  v_val jsonb;
BEGIN
  SELECT * INTO d FROM property_definition WHERE property_id = p_property_id;

  IF d.origin = 'derived' THEN
    IF d.derivation_engine = 'sql' THEN
      -- Admin-authored expression; parameters: $1 node, $2 hierarchy, $3 as_of, $4 recorded_as_of
      EXECUTE format('SELECT (%s)::jsonb', d.derivation_expr)
        INTO v_val USING p_node_id, p_hierarchy_id, p_as_of, p_recorded_as_of;
      RETURN v_val;
    END IF;
    RETURN NULL;
  END IF;

  v_h := CASE WHEN d.scope = 'local' THEN p_hierarchy_id END;

  SELECT pv.value INTO v_val
  FROM property_value pv
  WHERE pv.node_id = p_node_id AND pv.property_id = p_property_id
    AND pv.hierarchy_id IS NOT DISTINCT FROM v_h
    AND pv.valid_period @> p_as_of AND pv.recorded_period @> p_recorded_as_of;
  IF FOUND THEN
    RETURN v_val;                                   -- includes explicit JSON null overrides
  END IF;

  IF d.inheritance = 'inherit_from_ancestor' AND p_hierarchy_id IS NOT NULL THEN
    WITH RECURSIVE anc(node_id, dist) AS (
      SELECT r.parent_node_id, 1
      FROM hierarchy_relationship r
      WHERE r.hierarchy_id = p_hierarchy_id AND r.child_node_id = p_node_id AND r.is_primary
        AND r.valid_period @> p_as_of AND r.recorded_period @> p_recorded_as_of
      UNION ALL
      SELECT r.parent_node_id, anc.dist + 1
      FROM anc
      JOIN hierarchy_relationship r
        ON r.child_node_id = anc.node_id AND r.hierarchy_id = p_hierarchy_id AND r.is_primary
       AND r.valid_period @> p_as_of AND r.recorded_period @> p_recorded_as_of
      WHERE anc.dist < 100
    )
    SELECT pv.value INTO v_val
    FROM anc
    JOIN property_value pv
      ON pv.node_id = anc.node_id AND pv.property_id = p_property_id
     AND pv.hierarchy_id IS NOT DISTINCT FROM v_h
     AND pv.valid_period @> p_as_of AND pv.recorded_period @> p_recorded_as_of
    ORDER BY anc.dist
    LIMIT 1;
    IF FOUND THEN
      RETURN v_val;
    END IF;
  END IF;

  RETURN d.default_value;
END $$;

-- -----------------------------------------------------------------------------
-- Formatting helpers
-- -----------------------------------------------------------------------------
CREATE FUNCTION csv_field(p_text text, p_delim text, p_quote text, p_mode text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
SELECT CASE
  WHEN p_text IS NULL THEN ''
  WHEN p_mode = 'none' OR coalesce(p_quote, '') = '' THEN p_text
  WHEN p_mode = 'all'
    OR strpos(p_text, p_delim) > 0
    OR strpos(p_text, p_quote) > 0
    OR p_text ~ '[\r\n]'
    THEN p_quote || replace(p_text, p_quote, p_quote || p_quote) || p_quote
  ELSE p_text
END
$$;

CREATE FUNCTION format_cell(p_value jsonb, p_type property_data_type, p_mask text,
                            p_true text, p_false text, p_null text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = mdm, public AS $$
SELECT CASE
  WHEN p_value IS NULL OR jsonb_typeof(p_value) = 'null' THEN p_null
  WHEN p_type = 'boolean' THEN CASE WHEN (p_value::text)::boolean THEN p_true ELSE p_false END
  WHEN p_type = 'date' AND p_mask IS NOT NULL THEN to_char((p_value #>> '{}')::date, p_mask)
  WHEN p_type = 'datetime' AND p_mask IS NOT NULL THEN to_char((p_value #>> '{}')::timestamptz, p_mask)
  WHEN p_type IN ('integer', 'decimal') AND p_mask IS NOT NULL
    THEN trim(to_char((p_value #>> '{}')::numeric, p_mask))
  ELSE p_value #>> '{}'
END
$$;

CREATE FUNCTION node_passes_filter(p_node_id uuid, p_hierarchy_id uuid, p_filter jsonb,
                                   p_as_of date, p_recorded_as_of timestamptz)
RETURNS boolean LANGUAGE plpgsql STABLE SET search_path = mdm, public AS $$
DECLARE
  c   jsonb;
  pid uuid;
  v   jsonb;
  ok  boolean;
BEGIN
  FOR c IN SELECT * FROM jsonb_array_elements(coalesce(p_filter, '[]'::jsonb)) LOOP
    IF c->>'op' NOT IN ('=', '<>', 'in', 'not_in', 'is_null', 'not_null') THEN
      RAISE EXCEPTION 'Unsupported filter op %', c->>'op';
    END IF;
    SELECT property_id INTO pid FROM property_definition WHERE property_code = c->>'property';
    IF pid IS NULL THEN
      RAISE EXCEPTION 'Unknown property in filter: %', c->>'property';
    END IF;
    v := property_value_asof(p_node_id, pid, p_hierarchy_id, p_as_of, p_recorded_as_of);
    IF v = 'null'::jsonb THEN v := NULL; END IF;
    ok := CASE c->>'op'
            WHEN '='        THEN v = c->'value'
            WHEN '<>'       THEN v IS DISTINCT FROM c->'value'
            WHEN 'in'       THEN v IS NOT NULL AND (c->'value') @> jsonb_build_array(v)
            WHEN 'not_in'   THEN v IS NULL OR NOT ((c->'value') @> jsonb_build_array(v))
            WHEN 'is_null'  THEN v IS NULL
            WHEN 'not_null' THEN v IS NOT NULL
          END;
    IF NOT coalesce(ok, false) THEN
      RETURN false;
    END IF;
  END LOOP;
  RETURN true;
END $$;

CREATE FUNCTION export_column_value(
  c export_profile_column, p export_profile,
  p_node_id uuid, p_parent_id uuid, p_level int, p_is_leaf boolean, p_sort numeric,
  p_hierarchy_id uuid, p_hierarchy_code text, p_as_of date, p_recorded_as_of timestamptz
)
RETURNS text LANGUAGE plpgsql STABLE SET search_path = mdm, public AS $$
DECLARE
  d      property_definition%ROWTYPE;
  v      jsonb;
  target uuid;
BEGIN
  CASE c.column_source
    WHEN 'node_name'      THEN RETURN (node_attr_asof(p_node_id, p_as_of, p_recorded_as_of)).node_name;
    WHEN 'description'    THEN RETURN coalesce((node_attr_asof(p_node_id, p_as_of, p_recorded_as_of)).description, p.null_token);
    WHEN 'parent_name'    THEN RETURN CASE WHEN p_parent_id IS NULL THEN p.null_token
                                           ELSE (node_attr_asof(p_parent_id, p_as_of, p_recorded_as_of)).node_name END;
    WHEN 'level'          THEN RETURN p_level::text;
    WHEN 'is_leaf'        THEN RETURN CASE WHEN p_is_leaf THEN p.true_token ELSE p.false_token END;
    WHEN 'sort_order'     THEN RETURN p_sort::text;
    WHEN 'hierarchy_code' THEN RETURN p_hierarchy_code;
    WHEN 'static'         THEN RETURN c.static_value;
    WHEN 'property', 'parent_property' THEN
      target := CASE WHEN c.column_source = 'property' THEN p_node_id ELSE p_parent_id END;
      IF target IS NULL THEN
        RETURN p.null_token;
      END IF;
      SELECT * INTO d FROM property_definition WHERE property_id = c.property_id;
      v := property_value_asof(target, c.property_id, p_hierarchy_id, p_as_of, p_recorded_as_of);
      -- node references are exported by name, as DRM does
      IF d.data_type = 'node_ref' AND jsonb_typeof(v) = 'string' THEN
        RETURN (node_attr_asof((v #>> '{}')::uuid, p_as_of, p_recorded_as_of)).node_name;
      END IF;
      IF d.data_type = 'multi_node_ref' AND jsonb_typeof(v) = 'array' THEN
        RETURN (SELECT string_agg((node_attr_asof(x::uuid, p_as_of, p_recorded_as_of)).node_name,
                                  p.multi_value_separator ORDER BY ord)
                FROM jsonb_array_elements_text(v) WITH ORDINALITY AS t(x, ord));
      END IF;
      RETURN format_cell(v, d.data_type, c.format_mask, p.true_token, p.false_token, p.null_token);
    ELSE
      RAISE EXCEPTION 'Unsupported column_source %', c.column_source;
  END CASE;
END $$;

-- -----------------------------------------------------------------------------
-- Export generator: hierarchy and generation exports, as file lines
-- Usage: SELECT line FROM mdm.export_drm('LE_CONSOL_HIER', 'FY26_Oct') ORDER BY line_no;
-- -----------------------------------------------------------------------------
CREATE FUNCTION export_drm(p_profile_code text, p_version_name text)
RETURNS TABLE (line_no bigint, line text)
LANGUAGE plpgsql STABLE SET search_path = mdm, public AS $$
DECLARE
  p        export_profile%ROWTYPE;
  v        version%ROWTYPE;
  h        hierarchy%ROWTYPE;
  c        export_profile_column%ROWTYPE;
  n        record;
  s_asof   date;
  s_rec    timestamptz;
  offs     int;
  gen_cols int := 0;
  np       text[];
  np_len   int;
  cells    text[];
  i        bigint := 0;
BEGIN
  SELECT * INTO p FROM export_profile WHERE profile_code = p_profile_code AND is_active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown or inactive export profile %', p_profile_code;
  END IF;
  IF p.export_type NOT IN ('hierarchy', 'generation') THEN
    RAISE EXCEPTION 'Export type % is produced by the export service, not SQL', p.export_type;
  END IF;

  SELECT * INTO v FROM version WHERE version_name = p_version_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown version %', p_version_name;
  END IF;
  s_asof := v.business_as_of;
  s_rec  := coalesce(v.recorded_as_of, now());
  SELECT * INTO h FROM hierarchy WHERE hierarchy_id = p.hierarchy_id;
  offs := CASE WHEN p.include_top_node THEN 0 ELSE 1 END;

  IF p.export_type = 'generation' THEN
    SELECT coalesce(p.max_level, max(t.level)) - offs INTO gen_cols
    FROM hierarchy_tree(h.hierarchy_id, s_asof, s_rec, p.top_node_override) t;
  END IF;

  -- header row
  IF p.include_header THEN
    cells := ARRAY[]::text[];
    FOR g IN 1..gen_cols LOOP
      cells := cells || csv_field(p.generation_header_prefix || g, p.delimiter, p.quote_char, p.quote_mode);
    END LOOP;
    FOR c IN SELECT * FROM export_profile_column WHERE export_profile_id = p.export_profile_id ORDER BY seq LOOP
      cells := cells || csv_field(c.header_label, p.delimiter, p.quote_char, p.quote_mode);
    END LOOP;
    i := i + 1; line_no := i; line := array_to_string(cells, p.delimiter);
    RETURN NEXT;
  END IF;

  -- data rows, in hierarchy sort order
  FOR n IN
    SELECT t.*
    FROM hierarchy_tree(h.hierarchy_id, s_asof, s_rec, p.top_node_override) t
    WHERE (p.include_top_node OR t.level > 1)
      AND (NOT p.leaf_only OR t.is_leaf)
      AND (p.include_shared_nodes OR t.is_primary)
      AND (p.max_level IS NULL OR t.level <= p.max_level)
      AND (p.include_inactive OR coalesce((node_attr_asof(t.node_id, s_asof, s_rec)).is_active, false))
      AND node_passes_filter(t.node_id, h.hierarchy_id, p.node_filter, s_asof, s_rec)
    ORDER BY t.sort_path, t.name_path
  LOOP
    cells := ARRAY[]::text[];

    IF p.export_type = 'generation' THEN
      np     := n.name_path[1 + offs : array_length(n.name_path, 1)];
      np_len := coalesce(array_length(np, 1), 0);
      FOR g IN 1..gen_cols LOOP
        cells := cells || csv_field(
          CASE WHEN g <= np_len THEN np[g]
               WHEN p.generation_pad_mode = 'repeat_last' AND np_len > 0 THEN np[np_len]
               ELSE '' END,
          p.delimiter, p.quote_char, p.quote_mode);
      END LOOP;
    END IF;

    FOR c IN SELECT * FROM export_profile_column WHERE export_profile_id = p.export_profile_id ORDER BY seq LOOP
      cells := cells || csv_field(
        export_column_value(c, p, n.node_id, n.parent_node_id, n.level, n.is_leaf, n.sort_order,
                            h.hierarchy_id, h.hierarchy_code, s_asof, s_rec),
        p.delimiter, p.quote_char, p.quote_mode);
    END LOOP;

    i := i + 1; line_no := i; line := array_to_string(cells, p.delimiter);
    RETURN NEXT;
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- Export runs and DRM parallel-run reconciliation
-- -----------------------------------------------------------------------------
CREATE TABLE export_run (
  export_run_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  export_profile_id uuid NOT NULL REFERENCES export_profile,
  version_id        uuid NOT NULL REFERENCES version,
  generated_at      timestamptz NOT NULL DEFAULT now(),
  row_count         bigint NOT NULL,
  file_sha256       char(64) NOT NULL,
  storage_uri       text,                       -- written by the export service
  triggered_by      uuid REFERENCES app_user
);

CREATE FUNCTION run_export(p_profile_code text, p_version_name text, p_triggered_by uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE
  p       export_profile%ROWTYPE;
  content text;
  cnt     bigint;
  run_id  uuid;
BEGIN
  SELECT * INTO p FROM export_profile WHERE profile_code = p_profile_code;
  SELECT string_agg(e.line, p.line_ending ORDER BY e.line_no), count(*)
    INTO content, cnt
  FROM export_drm(p_profile_code, p_version_name) e;

  content := coalesce(content, '')
          || CASE WHEN p.trailing_line_ending AND cnt > 0 THEN p.line_ending ELSE '' END;

  INSERT INTO export_run (export_profile_id, version_id, row_count, file_sha256, triggered_by)
  SELECT p.export_profile_id, v.version_id, cnt,
         encode(digest(convert_to(content, p.encoding), 'sha256'), 'hex'), p_triggered_by
  FROM version v WHERE v.version_name = p_version_name
  RETURNING export_run_id INTO run_id;

  RETURN run_id;
END $$;

CREATE TABLE drm_reconciliation (
  recon_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  export_run_id   uuid NOT NULL REFERENCES export_run,
  mdm_sha256      char(64) NOT NULL,
  drm_file_uri    text NOT NULL,
  drm_sha256      char(64) NOT NULL,
  drm_row_count   bigint,
  is_exact_match  boolean GENERATED ALWAYS AS (mdm_sha256 = drm_sha256) STORED,
  diff_summary    jsonb,                        -- row-level diff from the reconciliation service
  status          text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'explained', 'fixed', 'accepted')),
  reviewed_by     uuid REFERENCES app_user,
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Migration staging: raw DRM extracts land here before AI-assisted mapping
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS mdm_stage;

CREATE TABLE mdm_stage.drm_property_definition (
  property_name text PRIMARY KEY, label text, data_type text, scope text,
  origin text, inherits boolean, derived_formula text, category text, list_values text[], raw jsonb
);
CREATE TABLE mdm_stage.drm_node (
  version_name text NOT NULL, node_name text NOT NULL, description text,
  is_leaf boolean, is_inactive boolean, raw jsonb,
  PRIMARY KEY (version_name, node_name)
);
CREATE TABLE mdm_stage.drm_relationship (
  version_name text NOT NULL, hierarchy_name text NOT NULL,
  parent_name text, child_name text NOT NULL, sort_order numeric, is_shared boolean
);
CREATE TABLE mdm_stage.drm_property_value (
  version_name text NOT NULL, hierarchy_name text,   -- NULL for global properties
  node_name text NOT NULL, property_name text NOT NULL, value text
);
CREATE TABLE mdm_stage.drm_validation (
  validation_name text PRIMARY KEY, level text, formula text, message text, raw jsonb
);
CREATE TABLE mdm_stage.drm_export_definition (
  export_name text PRIMARY KEY, export_type text, hierarchy_name text,
  settings jsonb, columns jsonb, target_system text
);

-- How each DRM property maps across (filled during the AI-assisted inventory step).
CREATE TABLE mdm.drm_property_map (
  drm_property_name text PRIMARY KEY,
  property_id       uuid REFERENCES mdm.property_definition,
  value_transform   text,                  -- e.g. 'Y/N -> boolean'
  status            text NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed', 'confirmed', 'retired')),
  proposed_by       text,                  -- 'ai_inventory' or a steward login
  notes             text
);
