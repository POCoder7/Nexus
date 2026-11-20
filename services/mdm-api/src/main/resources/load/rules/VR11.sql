-- VR11 ValidOrgBUIsLvl4: limbs at level 4 are BUs (3 upper-case letters) ({{hierarchy}} only)
WITH RECURSIVE h AS (SELECT hierarchy_id, top_node_id FROM mdm.hierarchy WHERE hierarchy_code = {{hierarchy}}),
t(node_id, lvl) AS (
  SELECT top_node_id, 1 FROM h
  UNION ALL
  SELECT r.child_node_id, t.lvl + 1 FROM t
  JOIN mdm.hierarchy_relationship r ON r.parent_node_id = t.node_id AND r.hierarchy_id = (SELECT hierarchy_id FROM h)
   AND r.is_primary AND r.valid_period @> $1 AND upper_inf(r.recorded_period)
  WHERE t.lvl < 50
)
SELECT t.node_id, (SELECT hierarchy_id FROM h), format('Level-4 limb %s must be a BU: exactly 3 upper-case letters', a.node_name)
FROM t JOIN mdm.node_attr a ON a.node_id = t.node_id AND a.valid_period @> $1 AND upper_inf(a.recorded_period)
WHERE t.lvl = 4 AND a.allows_children AND a.node_name !~ '^[A-Z]{3}$'
