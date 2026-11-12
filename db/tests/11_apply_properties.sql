-- pgTAP: apply handlers for set_property and clear_property, and the item limit by origin (Phase 1 LLD §7.1–§7.2,
-- increment 1-8c, CR-04). Synthetic data only.
BEGIN;
SELECT plan(18);

-- Fixture ------------------------------------------------------------------------------------------------------
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-000000000ba1', 'k_steward',  'Steward',  'human'),
  ('00000000-0000-0000-0000-000000000ba2', 'k_approver', 'Approver', 'human');
INSERT INTO mdm.version (version_id, version_name, business_as_of)
VALUES ('00000000-0000-0000-0000-000000000bb1', 'K_VERSION', current_date);
INSERT INTO mdm.node (node_id, node_kind) VALUES
  ('00000000-0000-0000-0000-000000000b01', 'structural'),    -- T  top of K_H1
  ('00000000-0000-0000-0000-000000000b02', 'structural'),    -- A  under T
  ('00000000-0000-0000-0000-000000000b03', 'legal_entity'),  -- X  under A; also under T2 in K_H2
  ('00000000-0000-0000-0000-000000000b04', 'structural');    -- T2 top of K_H2
INSERT INTO mdm.node_attr (node_id, node_name, allows_children, valid_period) VALUES
  ('00000000-0000-0000-0000-000000000b01', 'K top', true, daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-000000000b02', 'K A', true, daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-000000000b03', 'K X', false, daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-000000000b04', 'K top 2', true, daterange('2020-01-01', NULL));
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id) VALUES
  ('00000000-0000-0000-0000-000000000bc1', 'K_H1', 'K one', '00000000-0000-0000-0000-000000000b01'),
  ('00000000-0000-0000-0000-000000000bc2', 'K_H2', 'K two', '00000000-0000-0000-0000-000000000b04');
INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, valid_period) VALUES
  ('00000000-0000-0000-0000-000000000bc1', '00000000-0000-0000-0000-000000000b01', '00000000-0000-0000-0000-000000000b02', daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-000000000bc1', '00000000-0000-0000-0000-000000000b02', '00000000-0000-0000-0000-000000000b03', daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-000000000bc2', '00000000-0000-0000-0000-000000000b04', '00000000-0000-0000-0000-000000000b03', daterange('2020-01-01', NULL));
INSERT INTO mdm.property_definition (property_id, property_code, label, data_type, scope, inheritance, origin, derivation_engine, derivation_expr) VALUES
  ('00000000-0000-0000-0000-000000000bd1', 'K.Ccy', 'Currency', 'string', 'global', 'inherit_from_ancestor', 'stored', NULL, NULL),
  ('00000000-0000-0000-0000-000000000bd2', 'K.Loc', 'Local code', 'string', 'local', 'none', 'stored', NULL, NULL),
  ('00000000-0000-0000-0000-000000000bd3', 'K.Der', 'Derived', 'string', 'global', 'none', 'derived', 'sql', '''"derived"''');
INSERT INTO mdm.property_value (node_id, property_id, value, valid_period) VALUES
  ('00000000-0000-0000-0000-000000000b01', '00000000-0000-0000-0000-000000000bd1', '"EUR"', daterange('2020-01-01', NULL));

-- Helpers (owner, setup only): approved requests effective 2030-01-01, applied through the API's privileges.
CREATE FUNCTION pg_temp.cr(p_id uuid, p_origin text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, effective_from, origin)
  VALUES (p_id, '00000000-0000-0000-0000-000000000bb1', 'K ' || p_id, '00000000-0000-0000-0000-000000000ba1', 'human', '2030-01-01', p_origin)
$$;
CREATE FUNCTION pg_temp.item(p_cr uuid, p_seq int, p_action text, p_h uuid, p_node uuid, p_prop uuid, p_payload jsonb)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, property_id, payload)
  VALUES (p_cr, p_seq, p_action::mdm.change_action, p_h, p_node, p_prop, p_payload)
$$;
CREATE FUNCTION pg_temp.apply(p_cr uuid) RETURNS int LANGUAGE plpgsql AS $$
DECLARE v int;
BEGIN
  UPDATE mdm.change_request SET status = 'submitted' WHERE change_request_id = p_cr;
  UPDATE mdm.change_request SET status = 'approved', decided_by = '00000000-0000-0000-0000-000000000ba2',
         decided_at = now(), decision_basis = 'human_review' WHERE change_request_id = p_cr;
  SET LOCAL ROLE nexus_api;
  v := mdm.apply_change_request(p_cr, '00000000-0000-0000-0000-000000000ba2');
  RESET ROLE;
  RETURN v;
END $$;
CREATE FUNCTION pg_temp.error(p_id uuid) RETURNS text LANGUAGE sql AS $$
  SELECT left(apply_error, 5) FROM mdm.change_request WHERE change_request_id = p_id AND status = 'apply_failed'
$$;
-- value/provenance of a property for a node in a hierarchy on a date
CREATE FUNCTION pg_temp.resolved(p_node uuid, p_h uuid, p_prop uuid, p_d date) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(r.value::text, '-') || '/' || r.provenance
  FROM mdm.node_properties_resolved(p_node, p_h, p_d, now()) r WHERE r.property_id = p_prop
$$;

-- set_property: global ---------------------------------------------------------------------------------------
SELECT pg_temp.cr('00000000-0000-0000-0000-000000000be1', 'user');
SELECT pg_temp.item('00000000-0000-0000-0000-000000000be1', 1, 'set_property', '00000000-0000-0000-0000-000000000bc1',
  '00000000-0000-0000-0000-000000000b03', '00000000-0000-0000-0000-000000000bd1',
  '{"value": "USD", "expected": {"present": false, "value": null}}');
SELECT is(pg_temp.apply('00000000-0000-0000-0000-000000000be1'), 1, 'Setting a value nobody stored writes one row');
SELECT is(pg_temp.resolved('00000000-0000-0000-0000-000000000b03', '00000000-0000-0000-0000-000000000bc1',
  '00000000-0000-0000-0000-000000000bd1', '2030-01-01'), '"USD"/stored', 'From D the node has its own value');
SELECT is(pg_temp.resolved('00000000-0000-0000-0000-000000000b03', '00000000-0000-0000-0000-000000000bc1',
  '00000000-0000-0000-0000-000000000bd1', '2029-12-31'), '"EUR"/inherited', 'Before D it still inherits');
SELECT is(pg_temp.resolved('00000000-0000-0000-0000-000000000b03', '00000000-0000-0000-0000-000000000bc2',
  '00000000-0000-0000-0000-000000000bd1', '2030-01-01'), '"USD"/stored', 'A global value is the same in every hierarchy');

-- set_property: local --------------------------------------------------------------------------------------------
SELECT pg_temp.cr('00000000-0000-0000-0000-000000000be2', 'user');
SELECT pg_temp.item('00000000-0000-0000-0000-000000000be2', 1, 'set_property', '00000000-0000-0000-0000-000000000bc1',
  '00000000-0000-0000-0000-000000000b03', '00000000-0000-0000-0000-000000000bd2', '{"value": "L1"}');
SELECT is(pg_temp.apply('00000000-0000-0000-0000-000000000be2'), 1, 'A local value is applied');
SELECT is(pg_temp.resolved('00000000-0000-0000-0000-000000000b03', '00000000-0000-0000-0000-000000000bc1',
  '00000000-0000-0000-0000-000000000bd2', '2030-01-01'), '"L1"/stored', 'The local value shows in its hierarchy');
SELECT is(pg_temp.resolved('00000000-0000-0000-0000-000000000b03', '00000000-0000-0000-0000-000000000bc2',
  '00000000-0000-0000-0000-000000000bd2', '2030-01-01'), '-/none', '… and not in another hierarchy');

-- stale base, then clear_property --------------------------------------------------------------------------------
SELECT pg_temp.cr('00000000-0000-0000-0000-000000000be3', 'user');
SELECT pg_temp.item('00000000-0000-0000-0000-000000000be3', 1, 'set_property', '00000000-0000-0000-0000-000000000bc1',
  '00000000-0000-0000-0000-000000000b03', '00000000-0000-0000-0000-000000000bd1',
  '{"value": "JPY", "expected": {"present": false, "value": null}}');
SELECT is(pg_temp.apply('00000000-0000-0000-0000-000000000be3') || '/' || pg_temp.error('00000000-0000-0000-0000-000000000be3'),
  '-1/N3001', 'A set drafted when no value was stored does not overwrite a value stored since');

SELECT pg_temp.cr('00000000-0000-0000-0000-000000000be4', 'user');
SELECT pg_temp.item('00000000-0000-0000-0000-000000000be4', 1, 'clear_property', '00000000-0000-0000-0000-000000000bc1',
  '00000000-0000-0000-0000-000000000b03', '00000000-0000-0000-0000-000000000bd1',
  '{"expected": {"present": true, "value": "USD"}}');
SELECT is(pg_temp.apply('00000000-0000-0000-0000-000000000be4'), 1, 'Clearing closes the stored row');
SELECT is((SELECT r.value::text || '/' || r.provenance || '/' || r.source_node_id
           FROM mdm.node_properties_resolved('00000000-0000-0000-0000-000000000b03', '00000000-0000-0000-0000-000000000bc1',
                                             '2030-01-01', now()) r
           WHERE r.property_id = '00000000-0000-0000-0000-000000000bd1'),
  '"EUR"/inherited/00000000-0000-0000-0000-000000000b01', 'After clearing, the value is inherited again, from its source');

SELECT pg_temp.cr('00000000-0000-0000-0000-000000000be5', 'user');
SELECT pg_temp.item('00000000-0000-0000-0000-000000000be5', 1, 'clear_property', '00000000-0000-0000-0000-000000000bc1',
  '00000000-0000-0000-0000-000000000b03', '00000000-0000-0000-0000-000000000bd1', '{}');
SELECT is(pg_temp.apply('00000000-0000-0000-0000-000000000be5'), 0, 'Clearing a value that is not stored changes nothing');

-- explicit blank and a bounded value -----------------------------------------------------------------------------
SELECT pg_temp.cr('00000000-0000-0000-0000-000000000be6', 'user');
SELECT pg_temp.item('00000000-0000-0000-0000-000000000be6', 1, 'set_property', '00000000-0000-0000-0000-000000000bc1',
  '00000000-0000-0000-0000-000000000b02', '00000000-0000-0000-0000-000000000bd1', '{"value": null}');
SELECT pg_temp.item('00000000-0000-0000-0000-000000000be6', 2, 'set_property', '00000000-0000-0000-0000-000000000bc1',
  '00000000-0000-0000-0000-000000000b01', '00000000-0000-0000-0000-000000000bd1', '{"value": "GBP", "validTo": "2030-06-01"}');
SELECT is(pg_temp.apply('00000000-0000-0000-0000-000000000be6'), 5, 'Blank on A (1 row) and bounded GBP on T (4 rows)');
SELECT is((SELECT value FROM mdm.property_value WHERE node_id = '00000000-0000-0000-0000-000000000b02'
           AND upper_inf(recorded_period)), 'null'::jsonb, 'An explicit blank is stored as JSON null, not SQL NULL');
SELECT is(pg_temp.resolved('00000000-0000-0000-0000-000000000b03', '00000000-0000-0000-0000-000000000bc1',
  '00000000-0000-0000-0000-000000000bd1', '2030-01-01'), 'null/inherited', 'The blank on A blocks inheritance from T');
SELECT is(pg_temp.resolved('00000000-0000-0000-0000-000000000b01', '00000000-0000-0000-0000-000000000bc1',
  '00000000-0000-0000-0000-000000000bd1', '2030-03-01') || ' ' ||
          pg_temp.resolved('00000000-0000-0000-0000-000000000b01', '00000000-0000-0000-0000-000000000bc1',
  '00000000-0000-0000-0000-000000000bd1', '2030-06-01'), '"GBP"/stored "EUR"/stored', 'A bounded value holds only until validTo');

-- rules enforced by the property guard ----------------------------------------------------------------------------
SELECT pg_temp.cr('00000000-0000-0000-0000-000000000be7', 'user');
SELECT pg_temp.item('00000000-0000-0000-0000-000000000be7', 1, 'set_property', NULL,
  '00000000-0000-0000-0000-000000000b03', '00000000-0000-0000-0000-000000000bd2', '{"value": "no hierarchy"}');
SELECT pg_temp.cr('00000000-0000-0000-0000-000000000be8', 'user');
SELECT pg_temp.item('00000000-0000-0000-0000-000000000be8', 1, 'set_property', '00000000-0000-0000-0000-000000000bc1',
  '00000000-0000-0000-0000-000000000b03', '00000000-0000-0000-0000-000000000bd3', '{"value": "x"}');
SELECT is(ARRAY[pg_temp.apply('00000000-0000-0000-0000-000000000be7') || '/' || pg_temp.error('00000000-0000-0000-0000-000000000be7'),
                pg_temp.apply('00000000-0000-0000-0000-000000000be8') || '/' || pg_temp.error('00000000-0000-0000-0000-000000000be8')],
  ARRAY['-1/N2020', '-1/N2021'], 'A local value needs a hierarchy (N2020); a derived property cannot be stored (N2021)');

-- item limit by origin (CR-04) -----------------------------------------------------------------------------------
UPDATE mdm.system_setting SET setting_value = '1' WHERE setting_key = 'max_items_per_change_request';
SELECT pg_temp.cr('00000000-0000-0000-0000-000000000be9', 'user');
SELECT pg_temp.cr('00000000-0000-0000-0000-000000000bea', 'sandbox');
SELECT pg_temp.item(c::uuid, s, 'set_property', '00000000-0000-0000-0000-000000000bc1', '00000000-0000-0000-0000-000000000b03',
  '00000000-0000-0000-0000-000000000bd2', jsonb_build_object('value', 'v' || s))
FROM (VALUES ('00000000-0000-0000-0000-000000000be9'), ('00000000-0000-0000-0000-000000000bea')) AS r(c), generate_series(1, 2) AS s;
SELECT is(pg_temp.apply('00000000-0000-0000-0000-000000000be9') || '/' || pg_temp.error('00000000-0000-0000-0000-000000000be9'),
  '-1/N2103', 'A user request over the item limit is refused');
SELECT ok(pg_temp.apply('00000000-0000-0000-0000-000000000bea') > 0, 'A sandbox request has its own, larger limit');

SELECT * FROM finish();
ROLLBACK;
