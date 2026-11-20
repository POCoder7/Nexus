-- VR16 FINANCE_REQUIRED_ACTIVE_LEAF: an active leaf has GL_COMPANY, LEDGER_ID and ACCOUNTING_CURRENCY, where those
-- attributes apply (their hierarchies and node kind, ADR-046 D2)
SELECT a.node_id, NULL::uuid, format('Active leaf %s has no %s', a.node_name, pd.property_code)
FROM mdm.node_attr a
JOIN mdm.property_definition pd ON pd.property_code IN ('GL_COMPANY', 'LEDGER_ID', 'ACCOUNTING_CURRENCY')
WHERE a.valid_period @> $1 AND upper_inf(a.recorded_period) AND a.is_active AND NOT a.allows_children
  AND mdm.property_applies(pd.property_id, a.node_id, NULL, $1)
  AND NOT EXISTS (SELECT 1 FROM mdm.property_value v
                  WHERE v.node_id = a.node_id AND v.property_id = pd.property_id AND v.valid_period @> $1
                    AND upper_inf(v.recorded_period) AND jsonb_typeof(v.value) <> 'null')
