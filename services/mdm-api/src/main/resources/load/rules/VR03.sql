-- VR03 NAME_LENGTH: node_name must be at most 60 characters (the display name, or the code without one)
SELECT a.node_id, NULL::uuid, format('The node name has %s characters; at most 60 are allowed', length(coalesce(a.display_name, a.node_name)))
FROM mdm.node_attr a
WHERE a.valid_period @> $1 AND upper_inf(a.recorded_period) AND length(coalesce(a.display_name, a.node_name)) > 60
