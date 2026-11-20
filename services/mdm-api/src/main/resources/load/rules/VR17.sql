-- VR17 LEDGER_CURRENCY_MATCH: ACCOUNTING_CURRENCY equals the currency of the node's ledger (mdm.ledger)
SELECT ccy.node_id, NULL::uuid,
       format('Accounting currency %s differs from ledger %s''s currency %s', ccy.value #>> '{}', led.value #>> '{}', l.currency_code)
FROM mdm.property_value ccy
JOIN mdm.property_definition pc ON pc.property_id = ccy.property_id AND pc.property_code = 'ACCOUNTING_CURRENCY'
JOIN mdm.property_value led ON led.node_id = ccy.node_id AND led.valid_period @> $1 AND upper_inf(led.recorded_period)
JOIN mdm.property_definition pl ON pl.property_id = led.property_id AND pl.property_code = 'LEDGER_ID'
JOIN mdm.ledger l ON l.ledger_id = led.value #>> '{}'
WHERE ccy.valid_period @> $1 AND upper_inf(ccy.recorded_period) AND l.currency_code <> ccy.value #>> '{}'
