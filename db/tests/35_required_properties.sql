-- pgTAP: wf.missing_required_properties asks only for required properties that apply to the node (V21, ADR-046 D2):
-- the property's hierarchies and its leaf/limb filter; a node the request adds is judged by its add_node item.
-- Synthetic data only.
BEGIN;
SELECT plan(5);

-- H1: T ─ A (limb) ─ L (leaf)      H2: T2 (another hierarchy)
INSERT INTO mdm.node (node_id, node_kind)
SELECT ('00000000-0000-0000-0000-0000000035' || n)::uuid, 'structural' FROM unnest(ARRAY['01','02','03','04','05','06']) AS n;
--  01 T  02 A  03 L  04 T2  05 new limb  06 new leaf
INSERT INTO mdm.node_attr (node_id, node_name, allows_children, valid_period) VALUES
  ('00000000-0000-0000-0000-000000003501', 'RP top', true, daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-000000003502', 'RP limb', true, daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-000000003503', 'RP leaf', false, daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-000000003504', 'RP top two', true, daterange('2020-01-01', NULL));
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id) VALUES
  ('00000000-0000-0000-0000-000000003591', 'RP_H1', 'One', '00000000-0000-0000-0000-000000003501'),
  ('00000000-0000-0000-0000-000000003592', 'RP_H2', 'Two', '00000000-0000-0000-0000-000000003504');
INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, valid_period) VALUES
  ('00000000-0000-0000-0000-000000003591', '00000000-0000-0000-0000-000000003501', '00000000-0000-0000-0000-000000003502', daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-000000003591', '00000000-0000-0000-0000-000000003502', '00000000-0000-0000-0000-000000003503', daterange('2020-01-01', NULL));

-- Four required properties: for any node anywhere; leaves of H1; nodes with children in H1; any node of H2 only
INSERT INTO mdm.property_definition (property_id, property_code, label, data_type, scope, node_filter) VALUES
  ('00000000-0000-0000-0000-0000000035a1', 'RP_ANY',  'Any',  'string', 'global', 'any'),
  ('00000000-0000-0000-0000-0000000035a2', 'RP_LEAF', 'Leaf', 'string', 'global', 'leaf'),
  ('00000000-0000-0000-0000-0000000035a3', 'RP_LIMB', 'Limb', 'string', 'global', 'limb'),
  ('00000000-0000-0000-0000-0000000035a4', 'RP_TWO',  'Two',  'string', 'global', 'any');
INSERT INTO mdm.property_hierarchy (property_id, hierarchy_id) VALUES
  ('00000000-0000-0000-0000-0000000035a2', '00000000-0000-0000-0000-000000003591'),
  ('00000000-0000-0000-0000-0000000035a3', '00000000-0000-0000-0000-000000003591'),
  ('00000000-0000-0000-0000-0000000035a4', '00000000-0000-0000-0000-000000003592');

-- Model: Submit → Enrich (a task requiring all four) → Commit
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES ('00000000-0000-0000-0000-0000000035b1', 'rp_steward', 'Steward', 'human');
INSERT INTO mdm.version (version_id, version_name, business_as_of) VALUES ('00000000-0000-0000-0000-0000000035b2', 'RP_V', current_date);
INSERT INTO mdm.user_group (group_id, group_code, name) VALUES ('00000000-0000-0000-0000-0000000035b3', 'RP_G', 'Group');
INSERT INTO wf.workflow_task (task_id, task_code, label) VALUES ('00000000-0000-0000-0000-0000000035b4', 'RP_TASK', 'Enrich');
INSERT INTO wf.task_property (task_id, property_id, is_required)
SELECT '00000000-0000-0000-0000-0000000035b4', property_id, true FROM mdm.property_definition WHERE property_code LIKE 'RP\_%';
INSERT INTO wf.workflow_model (model_id, model_code, label) VALUES ('00000000-0000-0000-0000-0000000035b5', 'RP_MODEL', 'Model');
INSERT INTO wf.workflow_stage (stage_id, model_id, seq, stage_type, label, task_id) VALUES
  ('00000000-0000-0000-0000-0000000035c1', '00000000-0000-0000-0000-0000000035b5', 1, 'submit', 'Submit', NULL),
  ('00000000-0000-0000-0000-0000000035c2', '00000000-0000-0000-0000-0000000035b5', 2, 'approve', 'Enrich', '00000000-0000-0000-0000-0000000035b4'),
  ('00000000-0000-0000-0000-0000000035c3', '00000000-0000-0000-0000-0000000035b5', 3, 'commit', 'Commit', NULL);
INSERT INTO wf.submit_task VALUES ('00000000-0000-0000-0000-0000000035b5', '00000000-0000-0000-0000-0000000035b4');
INSERT INTO wf.stage_group (stage_id, group_id) VALUES
  ('00000000-0000-0000-0000-0000000035c2', '00000000-0000-0000-0000-0000000035b3'),
  ('00000000-0000-0000-0000-0000000035c3', '00000000-0000-0000-0000-0000000035b3');
UPDATE wf.workflow_model SET status = 'active', activated_by = '00000000-0000-0000-0000-0000000035b1'
WHERE model_id = '00000000-0000-0000-0000-0000000035b5';

-- One request per case, every item in H1; returns the missing properties at the Enrich stage as "node:code ..."
CREATE FUNCTION pg_temp.missing(p_title text, p_items jsonb) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v uuid; it jsonb; n int := 0; r text;
BEGIN
  INSERT INTO mdm.change_request (version_id, title, requester_id, requester_kind, effective_from)
  VALUES ('00000000-0000-0000-0000-0000000035b2', p_title, '00000000-0000-0000-0000-0000000035b1', 'human', current_date)
  RETURNING change_request_id INTO v;
  FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    n := n + 1;
    INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, target_parent_id, property_id, payload)
    VALUES (v, n, (it ->> 'a')::mdm.change_action, '00000000-0000-0000-0000-000000003591',
            ('00000000-0000-0000-0000-0000000035' || (it ->> 'n'))::uuid,
            CASE WHEN it ? 't' THEN ('00000000-0000-0000-0000-0000000035' || (it ->> 't'))::uuid END,
            (SELECT property_id FROM mdm.property_definition WHERE property_code = it ->> 'p'),
            coalesce(it -> 'payload', '{}'));
  END LOOP;
  PERFORM wf.start_instance(v, 'RP_MODEL', '00000000-0000-0000-0000-0000000035b1');
  SELECT string_agg(right(m.node_id::text, 2) || ':' || m.property_code, ' ' ORDER BY m.node_id, m.property_code) INTO r
  FROM wf.instance_stage ist JOIN wf.workflow_instance i ON i.instance_id = ist.instance_id
  CROSS JOIN LATERAL wf.missing_required_properties(ist.instance_stage_id) m
  WHERE i.change_request_id = v AND ist.stage_id = '00000000-0000-0000-0000-0000000035c2';
  RETURN r;
END $$;

SELECT is(pg_temp.missing('RP new limb', '[{"a":"add_node","n":"05","t":"02","payload":{"name":"RP new limb","isLeaf":false}}]'),
  '05:RP_ANY 05:RP_LIMB', 'A new node with children is not asked for a leaf-only property, nor for another hierarchy''s');
SELECT is(pg_temp.missing('RP new leaf', '[{"a":"add_node","n":"06","t":"02","payload":{"name":"RP new leaf","isLeaf":true}},'
                                         '{"a":"set_property","n":"06","p":"RP_LEAF","payload":{"value":"X1"}}]'),
  '06:RP_ANY', 'A new leaf is asked for the leaf property, which the request supplies; not for the limb one');
SELECT is(pg_temp.missing('RP no flag', '[{"a":"add_node","n":"05","t":"02","payload":{"name":"RP no flag"}}]'),
  '05:RP_ANY 05:RP_LIMB', 'A new node without isLeaf is judged as apply_add_node creates it: with children');
SELECT is(pg_temp.missing('RP leaf', '[{"a":"update_node","n":"03","payload":{"name":"RP leaf renamed"}}]'),
  '03:RP_ANY 03:RP_LEAF', 'An existing leaf is asked for the leaf property, by its stored kind');
SELECT is(pg_temp.missing('RP limb', '[{"a":"update_node","n":"02","payload":{"name":"RP limb renamed"}}]'),
  '02:RP_ANY 02:RP_LIMB', 'An existing node with children is asked for the limb property only');

SELECT * FROM finish();
ROLLBACK;
