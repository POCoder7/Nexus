-- VR01 NAME_REQUIRED: node_name must not be blank (the code, and the display name where there is one)
SELECT a.node_id, NULL::uuid, 'The node name must not be blank'
FROM mdm.node_attr a
WHERE a.valid_period @> $1 AND upper_inf(a.recorded_period)
  AND (btrim(a.node_name) = '' OR btrim(coalesce(a.display_name, 'x')) = '')
