-- VR15 INACTIVATE_LIMB_WITH_ACTIVE_CHILDREN: an inactive limb has no active children (in any hierarchy)
SELECT p.node_id, r.hierarchy_id, format('Limb %s is inactive but its child %s is active', p.node_name, c.node_name)
FROM mdm.node_attr p
JOIN mdm.hierarchy_relationship r ON r.parent_node_id = p.node_id AND r.valid_period @> $1 AND upper_inf(r.recorded_period)
JOIN mdm.node_attr c ON c.node_id = r.child_node_id AND c.valid_period @> $1 AND upper_inf(c.recorded_period) AND c.is_active
WHERE p.valid_period @> $1 AND upper_inf(p.recorded_period) AND p.allows_children AND NOT p.is_active
