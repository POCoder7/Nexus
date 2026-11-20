-- =============================================================================
-- V21 — Required properties only where the property applies (ADR-046 D2; owner, 2026-11-20).
-- wf.missing_required_properties (V4; GOV-03 infrastructure) asked for every required property of a stage's task on
-- every node of the request. A property limited to some hierarchies or to leaves (or to nodes with children) cannot be
-- stored anywhere else (guard N2025, mdm.property_applies), so asking for it there made a request impossible to
-- complete. It is now asked for only where it applies:
--   * a node the request adds is judged by its add_node item (isLeaf; the item's hierarchy), because it does not
--     exist in mdm until the request is applied;
--   * any other node by mdm.property_applies at the request's effective date (D-11), the same rule as the guard.
-- Everything else is unchanged: a required property that applies is still asked for. Replaced, not edited (V4 is
-- applied in the kept demo database).
-- =============================================================================

CREATE OR REPLACE FUNCTION wf.missing_required_properties(p_instance_stage_id uuid)
RETURNS TABLE (node_id uuid, property_code text)
LANGUAGE sql STABLE SET search_path = wf, mdm, public AS $$
SELECT DISTINCT ci.node_id, pd.property_code
FROM wf.instance_stage ist
JOIN wf.workflow_stage ws  ON ws.stage_id = ist.stage_id
JOIN wf.task_property tp   ON tp.task_id = ws.task_id AND tp.is_required
JOIN mdm.property_definition pd ON pd.property_id = tp.property_id
JOIN wf.instance_item ii   ON ii.instance_id = ist.instance_id
JOIN mdm.change_item ci    ON ci.change_item_id = ii.change_item_id AND ci.node_id IS NOT NULL
JOIN mdm.change_request cr ON cr.change_request_id = ci.change_request_id
-- the request adds this node: its add_node item says what kind of node it will be (apply_add_node: isLeaf, default false)
LEFT JOIN LATERAL (
  SELECT coalesce((a.payload ->> 'isLeaf')::boolean, false) AS is_leaf, a.hierarchy_id
  FROM mdm.change_item a
  WHERE a.change_request_id = ci.change_request_id AND a.node_id = ci.node_id AND a.action = 'add_node'
  ORDER BY a.seq LIMIT 1) added ON true
WHERE ist.instance_stage_id = p_instance_stage_id
  AND CASE WHEN added.is_leaf IS NOT NULL THEN
             (pd.node_filter = 'any' OR pd.node_filter = CASE WHEN added.is_leaf THEN 'leaf' ELSE 'limb' END)
             AND (NOT EXISTS (SELECT 1 FROM mdm.property_hierarchy ph WHERE ph.property_id = pd.property_id)
                  OR EXISTS (SELECT 1 FROM mdm.property_hierarchy ph
                             WHERE ph.property_id = pd.property_id AND ph.hierarchy_id = added.hierarchy_id))
           ELSE mdm.property_applies(pd.property_id, ci.node_id, ci.hierarchy_id, cr.effective_from)
      END
  AND NOT EXISTS (                 -- not supplied in the request...
        SELECT 1 FROM mdm.change_item c2
        WHERE c2.change_request_id = ci.change_request_id AND c2.node_id = ci.node_id
          AND c2.property_id = tp.property_id AND c2.action = 'set_property'
          AND jsonb_typeof(c2.payload->'value') IS DISTINCT FROM 'null')
  AND coalesce(jsonb_typeof(       -- ...and not already stored on the request's effective date (D-11)
        mdm.property_value_asof(ci.node_id, tp.property_id, ci.hierarchy_id, cr.effective_from, now())), 'null') = 'null'
$$;
COMMENT ON FUNCTION wf.missing_required_properties(uuid) IS
  'Required properties of the stage''s task that a node of the request lacks, counting only properties that apply to the node (its hierarchies and leaf/limb kind; a node the request adds by its add_node item). V21.';
