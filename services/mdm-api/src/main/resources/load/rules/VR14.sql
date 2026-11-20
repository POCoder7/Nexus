-- VR14 ValidOrgLimbsNot5NumericCharacters: 5 digits are cost-center codes, so a limb may not have one
SELECT a.node_id, NULL::uuid, format('Limb code %s is 5 digits; that format is reserved for cost centers', a.node_name)
FROM mdm.node_attr a
WHERE a.valid_period @> $1 AND upper_inf(a.recorded_period) AND a.allows_children AND a.node_name ~ '^[0-9]{5}$'
