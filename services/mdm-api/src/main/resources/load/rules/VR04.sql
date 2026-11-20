-- VR04 ValidOrganizationNodeCharacterLimit: leaf codes are exactly 5 characters; limb codes at most 5
SELECT a.node_id, NULL::uuid,
       CASE WHEN a.allows_children THEN format('Limb code %s is longer than 5 characters', a.node_name)
            ELSE format('Leaf code %s must be exactly 5 characters', a.node_name) END
FROM mdm.node_attr a
WHERE a.valid_period @> $1 AND upper_inf(a.recorded_period)
  AND ((a.allows_children AND length(a.node_name) > 5) OR (NOT a.allows_children AND length(a.node_name) <> 5))
