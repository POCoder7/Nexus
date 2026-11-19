-- =============================================================================
-- V13 — Queries, derived properties and compares (Phase 5 LLD §17; ADR-038; ADR-041 for the build order).
--
-- 5-9 (foundations): set-based property resolution for queries, compares and the formula resolver, and the settings
-- for the §17.15 limits. Later increments add saved queries (5-13a), formula history and the formula apply handler
-- (5-10, 5-11) and compare runs (5-12) to this file.
-- Nothing here references wf (CLAUDE.md rule 3).
-- =============================================================================

SET search_path = mdm, public;

-- -----------------------------------------------------------------------------
-- Settings (Phase 5 LLD §17.15). Performance targets are not settings: they are checked by the performance tests.
-- -----------------------------------------------------------------------------
INSERT INTO mdm.system_setting VALUES
  ('cel_max_expr_chars', '4000', 'Longest CEL formula accepted (Phase 5 LLD §17.3.2)'),
  ('cel_max_iterations', '1000', 'Most comprehension iterations a CEL formula may run (Phase 5 LLD §17.3.2)'),
  ('query_scan_max', '50000', 'Candidates a query examines per page before it returns a partial page to continue (§17.5.2)'),
  ('query_max_conditions', '50', 'Most conditions in one query or export filter (N2807, §17.5.1)'),
  ('query_max_columns', '50', 'Most result columns in one query (N2807, §17.5.1)'),
  ('saved_query_max_per_user', '200', 'Most saved queries one person may own (§17.5.3)'),
  ('compare_parallelism', '2', 'Compare runs at a time per API instance (§17.4.3)'),
  ('compare_timeout_min', '15', 'A compare run that takes longer fails (N2808, §17.4.3)'),
  ('compare_result_ttl_h', '24', 'Hours a compare run''s rows are kept (§17.4.3)');

-- -----------------------------------------------------------------------------
-- resolve_properties_batch (§17.10): the resolved properties of many nodes in one statement, with the same rows, values
-- and provenance as node_properties_resolved (V3) gives node by node. A pgTAP test compares the two row for row.
--   * stored: one join of property_value to the nodes at the slice;
--   * inherited: one recursive walk up the primary placements, keeping the nearest ancestor's value; the walk stops
--     at the same bound as node_properties_resolved (100), so the two cannot differ on deep trees;
--   * then defaults, and sql-derived values per node as today (derived properties are few);
--   * CEL-derived properties come back with value NULL and provenance 'derived', for the Java resolver to fill (5-10).
-- p_rec NULL means as recorded now; p_properties NULL means every property.
-- -----------------------------------------------------------------------------
CREATE FUNCTION mdm.resolve_properties_batch(p_nodes uuid[], p_hierarchy uuid, p_as_of date, p_rec timestamptz,
                                             p_properties uuid[] DEFAULT NULL)
RETURNS TABLE (node_id uuid, property_id uuid, value jsonb, provenance text, source_node_id uuid,
               source_property_value_id uuid)
LANGUAGE sql STABLE SET search_path = mdm, public AS $$
WITH RECURSIVE
slice AS (SELECT coalesce(p_rec, now()) AS rec),
nodes AS (SELECT DISTINCT n AS node_id FROM unnest(p_nodes) AS n),
defs AS (
  SELECT d.*, CASE WHEN d.scope = 'local' THEN p_hierarchy END AS value_hierarchy
  FROM mdm.property_definition d
  WHERE (d.scope = 'global' OR p_hierarchy IS NOT NULL)
    AND (p_properties IS NULL OR d.property_id = ANY (p_properties))
),
anc(node_id, ancestor_id, dist) AS (
  SELECT n.node_id, r.parent_node_id, 1
  FROM nodes n
  JOIN mdm.hierarchy_relationship r ON r.child_node_id = n.node_id
  CROSS JOIN slice s
  WHERE p_hierarchy IS NOT NULL AND r.hierarchy_id = p_hierarchy AND r.is_primary
    AND r.valid_period @> p_as_of AND r.recorded_period @> s.rec
  UNION ALL
  SELECT a.node_id, r.parent_node_id, a.dist + 1
  FROM anc a
  JOIN mdm.hierarchy_relationship r ON r.child_node_id = a.ancestor_id
  CROSS JOIN slice s
  WHERE r.hierarchy_id = p_hierarchy AND r.is_primary
    AND r.valid_period @> p_as_of AND r.recorded_period @> s.rec
    AND a.dist < 100                                     -- same bound as node_properties_resolved (D-09)
),
stored AS (
  SELECT pv.node_id, pv.property_id, pv.value, pv.property_value_id
  FROM mdm.property_value pv
  JOIN nodes n ON n.node_id = pv.node_id
  JOIN defs d ON d.property_id = pv.property_id
  CROSS JOIN slice s
  WHERE pv.hierarchy_id IS NOT DISTINCT FROM d.value_hierarchy
    AND pv.valid_period @> p_as_of AND pv.recorded_period @> s.rec
),
inherited AS (
  SELECT DISTINCT ON (a.node_id, pv.property_id) a.node_id, pv.property_id, pv.value, a.ancestor_id AS source_node_id,
         pv.property_value_id
  FROM anc a
  JOIN mdm.property_value pv ON pv.node_id = a.ancestor_id
  JOIN defs d ON d.property_id = pv.property_id AND d.inheritance = 'inherit_from_ancestor'
  CROSS JOIN slice s
  WHERE pv.hierarchy_id IS NOT DISTINCT FROM d.value_hierarchy
    AND pv.valid_period @> p_as_of AND pv.recorded_period @> s.rec
  ORDER BY a.node_id, pv.property_id, a.dist
)
SELECT n.node_id, d.property_id,
       CASE WHEN d.origin = 'derived' THEN
              CASE WHEN d.derivation_engine = 'sql'
                   THEN mdm.property_value_asof(n.node_id, d.property_id, p_hierarchy, p_as_of, (SELECT rec FROM slice)) END
            WHEN s.property_id IS NOT NULL THEN s.value
            WHEN i.property_id IS NOT NULL THEN i.value
            ELSE d.default_value END,
       CASE WHEN d.origin = 'derived'        THEN 'derived'
            WHEN s.property_id IS NOT NULL   THEN 'stored'
            WHEN i.property_id IS NOT NULL   THEN 'inherited'
            WHEN d.default_value IS NOT NULL THEN 'default'
            ELSE 'none' END,
       CASE WHEN d.origin <> 'derived' AND s.property_id IS NULL THEN i.source_node_id END,
       CASE WHEN d.origin = 'derived' THEN NULL ELSE coalesce(s.property_value_id, i.property_value_id) END
FROM nodes n
CROSS JOIN defs d
LEFT JOIN stored s    ON s.node_id = n.node_id AND s.property_id = d.property_id
LEFT JOIN inherited i ON i.node_id = n.node_id AND i.property_id = d.property_id
$$;

-- -----------------------------------------------------------------------------
-- 5-13a: saved queries (QRY-01, §17.5.3). A person's own object, not governed master data, so it changes without a
-- change request; every change is audited. Results always use the runner's own read scope, so sharing a query never
-- shares data.
-- -----------------------------------------------------------------------------
CREATE TABLE mdm.saved_query (
  saved_query_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id       uuid NOT NULL REFERENCES mdm.app_user,
  name           text NOT NULL CHECK (length(trim(name)) > 0),
  description    text,
  hierarchy_id   uuid REFERENCES mdm.hierarchy,                    -- from the definition; NULL = chosen when run
  definition     jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
  visibility     text NOT NULL DEFAULT 'private' CHECK (visibility IN ('private', 'shared')),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  row_version    int NOT NULL DEFAULT 1,                           -- ETag (ADR-015)
  UNIQUE (owner_id, name)
);
CREATE INDEX ON mdm.saved_query (visibility, hierarchy_id);

-- ETag and timestamp move with every update; the owner and the creation time never change.
CREATE FUNCTION mdm.trg_saved_query_update() RETURNS trigger
LANGUAGE plpgsql SET search_path = mdm, public AS $$
BEGIN
  IF (NEW.saved_query_id, NEW.owner_id, NEW.created_at) IS DISTINCT FROM (OLD.saved_query_id, OLD.owner_id, OLD.created_at) THEN
    RAISE EXCEPTION 'The owner of a saved query never changes' USING ERRCODE = 'N2807', HINT = 'query.owner_fixed';
  END IF;
  NEW.row_version := OLD.row_version + 1;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
CREATE TRIGGER saved_query_update BEFORE UPDATE ON mdm.saved_query FOR EACH ROW EXECUTE FUNCTION mdm.trg_saved_query_update();
CREATE TRIGGER saved_query_audit AFTER INSERT OR UPDATE OR DELETE ON mdm.saved_query
  FOR EACH ROW EXECUTE FUNCTION mdm.trg_audit_row();

GRANT INSERT, UPDATE (name, description, hierarchy_id, definition, visibility), DELETE ON mdm.saved_query TO nexus_api;

-- =============================================================================
-- 5-12 Compares (QRY-02) and baselines (VER-04): Phase 5 LLD §17.4; built before 5-10 and 5-11 by ADR-044.
-- A compare is a run whose rows are stored and paged (a 500 000-node compare cannot be recomputed per page). Runs are
-- derived and rebuildable, like the sandbox overlay: not governed data, not audited, deleted when they expire.
-- =============================================================================
CREATE TABLE mdm.compare_run (
  compare_run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  requested_by   uuid NOT NULL REFERENCES mdm.app_user,
  definition     jsonb NOT NULL,      -- both sides resolved to (hierarchy, asOf, recordedAsOf), kinds, options
  slice_key      text NOT NULL,       -- md5 of the resolved definition: equal keys compare the same slices the same way
  is_frozen      boolean NOT NULL,    -- both sides have a recorded time in the past, so the answer never changes
  status         text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'done', 'failed')),
  counts         jsonb,
  error          text,
  started_at     timestamptz NOT NULL DEFAULT now(),
  finished_at    timestamptz,
  expires_at     timestamptz NOT NULL
);
CREATE INDEX compare_run_reuse ON mdm.compare_run (slice_key) WHERE status = 'done' AND is_frozen;
CREATE INDEX compare_run_expiry ON mdm.compare_run (expires_at);

CREATE TABLE mdm.compare_row (
  compare_run_id uuid NOT NULL REFERENCES mdm.compare_run ON DELETE CASCADE,
  seq            bigint NOT NULL,
  kind           text NOT NULL CHECK (kind IN ('structure', 'property', 'rename')),
  node_id        uuid NOT NULL,
  node_name      text NOT NULL,
  detail         jsonb NOT NULL,
  PRIMARY KEY (compare_run_id, seq)
);
CREATE INDEX compare_row_page ON mdm.compare_row (compare_run_id, kind, node_name, node_id, seq);

-- One side of a compare: every placement in the hierarchy at the slice (or below a sub-tree root, through primary and
-- shared placements, bounded by max_hierarchy_depth), plus the top (or the root) with no parent, each with the node's
-- name, description and active flag at the slice.
CREATE FUNCTION mdm.compare_side(p_hierarchy uuid, p_on date, p_rec timestamptz, p_root uuid)
RETURNS TABLE (node_id uuid, parent_node_id uuid, is_primary boolean, sort_order numeric, node_name text,
               description text, is_active boolean)
LANGUAGE sql STABLE SET search_path = mdm, public AS $$
WITH RECURSIVE
edges AS (
  SELECT r.parent_node_id, r.child_node_id, r.is_primary, r.sort_order
  FROM mdm.hierarchy_relationship r
  WHERE r.hierarchy_id = p_hierarchy AND r.valid_period @> p_on AND r.recorded_period @> p_rec
),
top AS (SELECT coalesce(p_root, h.top_node_id) AS node_id FROM mdm.hierarchy h WHERE h.hierarchy_id = p_hierarchy),
sub(node_id, depth) AS (
  SELECT t.node_id, 0 FROM top t WHERE p_root IS NOT NULL
  UNION
  SELECT e.child_node_id, s.depth + 1 FROM edges e JOIN sub s ON e.parent_node_id = s.node_id
  WHERE s.depth < (SELECT coalesce(max(setting_value::int), 50) FROM mdm.system_setting WHERE setting_key = 'max_hierarchy_depth')
),
placements AS (
  SELECT t.node_id, NULL::uuid AS parent_node_id, true AS is_primary, NULL::numeric AS sort_order FROM top t
  UNION ALL
  SELECT e.child_node_id, e.parent_node_id, e.is_primary, e.sort_order FROM edges e
  WHERE p_root IS NULL OR e.parent_node_id IN (SELECT s.node_id FROM sub s)
)
SELECT p.node_id, p.parent_node_id, p.is_primary, p.sort_order, coalesce(a.node_name, p.node_id::text), a.description,
       coalesce(a.is_active, true)
FROM placements p
LEFT JOIN mdm.node_attr a ON a.node_id = p.node_id AND a.valid_period @> p_on AND a.recorded_period @> p_rec
$$;

-- Fills a run (§17.4.2), set-based, in the caller's transaction, and marks it done with counts. The definition holds
-- left and right {hierarchyId, asOf, recordedAsOf}, kinds, propertyIds (null = every property), subtreeRootId,
-- includeInactive and includeOrder. Nodes are matched by node_id, so a rename is reported as a rename.
CREATE FUNCTION mdm.compare_fill(p_run uuid)
RETURNS jsonb LANGUAGE plpgsql SET search_path = mdm, public AS $$
DECLARE
  d        jsonb;
  lh uuid; rh uuid; la date; ra date; lr timestamptz; rr timestamptz;
  v_root   uuid;
  v_inact  boolean;
  v_order  boolean;
  v_kinds  text[];
  v_props  uuid[];
  v_seq    bigint := 0;
  v_n      bigint;
  v_counts jsonb := '{}';
BEGIN
  SELECT definition INTO d FROM mdm.compare_run WHERE compare_run_id = p_run AND status = 'running' FOR UPDATE;
  IF d IS NULL THEN
    RAISE EXCEPTION 'Compare run % is not running', p_run USING ERRCODE = 'N2808', HINT = 'compare.not_running';
  END IF;
  lh := (d #>> '{left,hierarchyId}')::uuid;  la := (d #>> '{left,asOf}')::date;  lr := (d #>> '{left,recordedAsOf}')::timestamptz;
  rh := (d #>> '{right,hierarchyId}')::uuid; ra := (d #>> '{right,asOf}')::date; rr := (d #>> '{right,recordedAsOf}')::timestamptz;
  v_root  := (d ->> 'subtreeRootId')::uuid;
  v_inact := coalesce((d ->> 'includeInactive')::boolean, false);
  v_order := coalesce((d ->> 'includeOrder')::boolean, false);
  v_kinds := ARRAY(SELECT jsonb_array_elements_text(d -> 'kinds'));
  v_props := CASE WHEN jsonb_typeof(d -> 'propertyIds') = 'array'
                  THEN ARRAY(SELECT jsonb_array_elements_text(d -> 'propertyIds'))::uuid[] END;

  IF 'structure' = ANY (v_kinds) THEN
    INSERT INTO mdm.compare_row (compare_run_id, seq, kind, node_id, node_name, detail)
    SELECT p_run, v_seq + row_number() OVER (ORDER BY x.node_name, x.node_id, x.change), 'structure', x.node_id, x.node_name, x.detail
    FROM (
      WITH l AS (SELECT * FROM mdm.compare_side(lh, la, lr, v_root) s WHERE v_inact OR s.is_active),
           r AS (SELECT * FROM mdm.compare_side(rh, ra, rr, v_root) s WHERE v_inact OR s.is_active),
           names AS (SELECT DISTINCT ON (n.node_id) n.node_id, n.node_name FROM (SELECT * FROM r UNION ALL SELECT * FROM l) n),
           lp AS (SELECT * FROM l WHERE l.is_primary), rp AS (SELECT * FROM r WHERE r.is_primary)
      SELECT coalesce(rp.node_id, lp.node_id) AS node_id, coalesce(rp.node_name, lp.node_name) AS node_name,
             CASE WHEN lp.node_id IS NULL THEN 'added' WHEN rp.node_id IS NULL THEN 'removed'
                  WHEN lp.parent_node_id IS DISTINCT FROM rp.parent_node_id THEN 'moved' ELSE 'reordered' END AS change,
             jsonb_strip_nulls(jsonb_build_object(
               'change', CASE WHEN lp.node_id IS NULL THEN 'added' WHEN rp.node_id IS NULL THEN 'removed'
                              WHEN lp.parent_node_id IS DISTINCT FROM rp.parent_node_id THEN 'moved' ELSE 'reordered' END,
               'leftParentId', lp.parent_node_id, 'rightParentId', rp.parent_node_id,
               'leftParentName', (SELECT n.node_name FROM names n WHERE n.node_id = lp.parent_node_id),
               'rightParentName', (SELECT n.node_name FROM names n WHERE n.node_id = rp.parent_node_id),
               'leftSortOrder', lp.sort_order, 'rightSortOrder', rp.sort_order)) AS detail
      FROM lp FULL JOIN rp ON lp.node_id = rp.node_id
      WHERE lp.node_id IS NULL OR rp.node_id IS NULL OR lp.parent_node_id IS DISTINCT FROM rp.parent_node_id
         OR (v_order AND lp.sort_order IS DISTINCT FROM rp.sort_order)
      UNION ALL
      -- shared (non-primary) placements, compared as sets of (parent, child)
      SELECT coalesce(rs.node_id, ls.node_id), coalesce(rs.node_name, ls.node_name),
             CASE WHEN ls.node_id IS NULL THEN 'shared_added' ELSE 'shared_removed' END,
             jsonb_strip_nulls(jsonb_build_object(
               'change', CASE WHEN ls.node_id IS NULL THEN 'shared_added' ELSE 'shared_removed' END,
               'leftParentId', ls.parent_node_id, 'rightParentId', rs.parent_node_id,
               'leftParentName', (SELECT n.node_name FROM names n WHERE n.node_id = ls.parent_node_id),
               'rightParentName', (SELECT n.node_name FROM names n WHERE n.node_id = rs.parent_node_id)))
      FROM (SELECT * FROM l WHERE NOT l.is_primary) ls
      FULL JOIN (SELECT * FROM r WHERE NOT r.is_primary) rs ON ls.node_id = rs.node_id AND ls.parent_node_id = rs.parent_node_id
      WHERE ls.node_id IS NULL OR rs.node_id IS NULL
    ) x;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_seq := v_seq + v_n;
    v_counts := v_counts || jsonb_build_object('structure', v_n);
  END IF;

  IF 'rename' = ANY (v_kinds) THEN
    INSERT INTO mdm.compare_row (compare_run_id, seq, kind, node_id, node_name, detail)
    SELECT p_run, v_seq + row_number() OVER (ORDER BY r.node_name, r.node_id), 'rename', r.node_id, r.node_name,
           jsonb_build_object('leftName', l.node_name, 'rightName', r.node_name,
                              'leftDescription', l.description, 'rightDescription', r.description)
    FROM (SELECT DISTINCT ON (s.node_id) * FROM mdm.compare_side(lh, la, lr, v_root) s WHERE v_inact OR s.is_active) l
    JOIN (SELECT DISTINCT ON (s.node_id) * FROM mdm.compare_side(rh, ra, rr, v_root) s WHERE v_inact OR s.is_active) r
      ON r.node_id = l.node_id
    WHERE (l.node_name, l.description) IS DISTINCT FROM (r.node_name, r.description);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_seq := v_seq + v_n;
    v_counts := v_counts || jsonb_build_object('rename', v_n);
  END IF;

  IF 'property' = ANY (v_kinds) THEN
    -- resolved values (stored, inherited, default) of the nodes on both sides, each side in its own hierarchy and slice
    INSERT INTO mdm.compare_row (compare_run_id, seq, kind, node_id, node_name, detail)
    SELECT p_run, v_seq + row_number() OVER (ORDER BY x.node_name, x.node_id, x.property_code), 'property', x.node_id,
           x.node_name, x.detail
    FROM (
      WITH both_sides AS (
        SELECT r.node_id, r.node_name
        FROM (SELECT DISTINCT ON (s.node_id) * FROM mdm.compare_side(rh, ra, rr, v_root) s WHERE v_inact OR s.is_active) r
        JOIN (SELECT DISTINCT ON (s.node_id) * FROM mdm.compare_side(lh, la, lr, v_root) s WHERE v_inact OR s.is_active) l
          ON l.node_id = r.node_id
      ),
      lv AS (SELECT * FROM mdm.resolve_properties_batch(ARRAY(SELECT node_id FROM both_sides), lh, la, lr, v_props)),
      rv AS (SELECT * FROM mdm.resolve_properties_batch(ARRAY(SELECT node_id FROM both_sides), rh, ra, rr, v_props))
      SELECT b.node_id, b.node_name, pd.property_code,
             jsonb_build_object('propertyId', pd.property_id, 'propertyCode', pd.property_code, 'propertyLabel', pd.label,
                                'category', pd.category_code, 'leftValue', lv.value, 'rightValue', rv.value,
                                'leftProvenance', lv.provenance, 'rightProvenance', rv.provenance) AS detail
      FROM lv FULL JOIN rv ON rv.node_id = lv.node_id AND rv.property_id = lv.property_id
      JOIN both_sides b ON b.node_id = coalesce(rv.node_id, lv.node_id)
      JOIN mdm.property_definition pd ON pd.property_id = coalesce(rv.property_id, lv.property_id)
      WHERE lv.value IS DISTINCT FROM rv.value
    ) x;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_seq := v_seq + v_n;
    v_counts := v_counts || jsonb_build_object('property', v_n);
  END IF;

  UPDATE mdm.compare_run SET status = 'done', counts = v_counts, finished_at = now() WHERE compare_run_id = p_run;
  RETURN v_counts;
END $$;

-- Runs are written by the API (it starts, fills and expires them); compare_fill runs with the caller's rights and reads
-- only what every role can read.
GRANT INSERT, UPDATE (status, counts, error, finished_at), DELETE ON mdm.compare_run TO nexus_api;
GRANT INSERT, DELETE ON mdm.compare_row TO nexus_api;
