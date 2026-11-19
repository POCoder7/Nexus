-- pgTAP: the audit log's subject columns (AUD-01; Phase 5 LLD §18.2). trg_audit_row fills hierarchy, node and property
-- from the row itself, and the request from apply's setting or the row's own change_request_id. Synthetic data only.
BEGIN;
SELECT plan(9);

INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-0000000030a1', 'au_requester', 'Requester', 'human');
INSERT INTO mdm.node (node_id, node_kind) VALUES
  ('00000000-0000-0000-0000-0000000030c1', 'structural'), ('00000000-0000-0000-0000-0000000030c2', 'legal_entity');
INSERT INTO mdm.node_attr (node_id, node_name) VALUES
  ('00000000-0000-0000-0000-0000000030c1', 'AU top'), ('00000000-0000-0000-0000-0000000030c2', 'AU leaf');
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id)
VALUES ('00000000-0000-0000-0000-0000000030d1', 'AU_H', 'Audit hierarchy', '00000000-0000-0000-0000-0000000030c1');
INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id)
VALUES ('00000000-0000-0000-0000-0000000030d1', '00000000-0000-0000-0000-0000000030c1', '00000000-0000-0000-0000-0000000030c2');
INSERT INTO mdm.property_definition (property_id, property_code, label, data_type, scope)
VALUES ('00000000-0000-0000-0000-0000000030e1', 'AU.Note', 'Note', 'string', 'global');
INSERT INTO mdm.property_value (node_id, property_id, value)
VALUES ('00000000-0000-0000-0000-0000000030c2', '00000000-0000-0000-0000-0000000030e1', '"synthetic"');
INSERT INTO mdm.version (version_id, version_name, business_as_of)
VALUES ('00000000-0000-0000-0000-0000000030b1', 'AU_VERSION', current_date);
INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind)
VALUES ('00000000-0000-0000-0000-0000000030f1', '00000000-0000-0000-0000-0000000030b1', 'AU draft', '00000000-0000-0000-0000-0000000030a1', 'human');
INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, payload)
VALUES ('00000000-0000-0000-0000-0000000030f1', 1, 'update_node', '00000000-0000-0000-0000-0000000030d1',
        '00000000-0000-0000-0000-0000000030c2', '{"name": "AU renamed"}');

SELECT is((SELECT node_id FROM mdm.audit_log WHERE table_name = 'node_attr' AND new_row ->> 'node_name' = 'AU leaf'),
  '00000000-0000-0000-0000-0000000030c2'::uuid, 'A node''s attributes are filed under the node');
SELECT ok((SELECT hierarchy_id IS NULL FROM mdm.audit_log WHERE table_name = 'node_attr' AND new_row ->> 'node_name' = 'AU leaf'),
  '… with no hierarchy (a node''s name is the same in every hierarchy)');
SELECT results_eq(
  $$SELECT hierarchy_id, node_id FROM mdm.audit_log WHERE table_name = 'hierarchy_relationship'
    AND new_row ->> 'child_node_id' = '00000000-0000-0000-0000-0000000030c2'$$,
  $$VALUES ('00000000-0000-0000-0000-0000000030d1'::uuid, '00000000-0000-0000-0000-0000000030c2'::uuid)$$,
  'A placement is filed under its hierarchy and its child');
SELECT results_eq(
  $$SELECT node_id, property_id FROM mdm.audit_log WHERE table_name = 'property_value' AND new_row ->> 'value' = 'synthetic'$$,
  $$VALUES ('00000000-0000-0000-0000-0000000030c2'::uuid, '00000000-0000-0000-0000-0000000030e1'::uuid)$$,
  'A property value is filed under its node and property');
SELECT is((SELECT hierarchy_id FROM mdm.audit_log WHERE table_name = 'hierarchy' AND new_row ->> 'hierarchy_code' = 'AU_H'),
  '00000000-0000-0000-0000-0000000030d1'::uuid, 'A hierarchy is filed under itself');
SELECT is((SELECT change_request_id FROM mdm.audit_log WHERE table_name = 'change_request' AND action = 'INSERT' AND new_row ->> 'title' = 'AU draft'),
  '00000000-0000-0000-0000-0000000030f1'::uuid, 'A request written outside apply is filed under its own id');
SELECT results_eq(
  $$SELECT change_request_id, hierarchy_id, node_id FROM mdm.audit_log WHERE table_name = 'change_item'
    AND new_row ->> 'change_request_id' = '00000000-0000-0000-0000-0000000030f1'$$,
  $$VALUES ('00000000-0000-0000-0000-0000000030f1'::uuid, '00000000-0000-0000-0000-0000000030d1'::uuid,
            '00000000-0000-0000-0000-0000000030c2'::uuid)$$,
  'A draft item is filed under its request, hierarchy and node');
SELECT throws_ok($$UPDATE mdm.audit_log SET node_id = NULL WHERE table_name = 'node_attr'$$,
  'N2011', NULL, 'The subject columns are as append-only as the rest of the log');
SET LOCAL ROLE nexus_api;
SELECT throws_ok($$INSERT INTO mdm.audit_log (table_name, action, node_id) VALUES ('node_attr', 'INSERT', gen_random_uuid())$$,
  '42501', NULL, 'No application role writes the log itself');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
