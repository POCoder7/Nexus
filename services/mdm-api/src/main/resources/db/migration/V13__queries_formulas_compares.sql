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
