-- VR09 ValidOrgOCIsLvl2: level 2 holds OCs (OC + 3 numbers), and OC codes only appear there ({{hierarchy}} only)
WITH RECURSIVE h AS (SELECT hierarchy_id, top_node_id FROM mdm.hierarchy WHERE hierarchy_code = {{hierarchy}}),
t(node_id, lvl) AS (
  SELECT top_node_id, 1 FROM h
  UNION ALL
  SELECT r.child_node_id, t.lvl + 1 FROM t
  JOIN mdm.hierarchy_relationship r ON r.parent_node_id = t.node_id AND r.hierarchy_id = (SELECT hierarchy_id FROM h)
   AND r.is_primary AND r.valid_period @> $1 AND upper_inf(r.recorded_period)
  WHERE t.lvl < 50
)
SELECT t.node_id, (SELECT hierarchy_id FROM h), CASE WHEN t.lvl = 2 THEN format('Level-2 node %s must be an OC: OC followed by 3 numbers', a.node_name) ELSE format('%s is an OC code but sits at level %s', a.node_name, t.lvl) END
FROM t JOIN mdm.node_attr a ON a.node_id = t.node_id AND a.valid_period @> $1 AND upper_inf(a.recorded_period)
WHERE t.lvl = 2 AND a.node_name !~ '^OC[0-9]{3}$' OR t.lvl <> 2 AND a.node_name ~ '^OC[0-9]{3}$'
