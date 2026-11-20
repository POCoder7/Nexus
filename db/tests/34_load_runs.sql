-- pgTAP: load runs (ADR-046; Phase 4 LLD §4.3, §17.8; increment H-6): who prepares and approves, the frozen manifest,
-- the lifecycle, configuration only under an approved run, provision_user, and inactive nodes from add_node.
BEGIN;
SELECT plan(13);

INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-000000003401', 'l_admin1', 'Admin one', 'human'),
  ('00000000-0000-0000-0000-000000003402', 'l_admin2', 'Admin two', 'human'),
  ('00000000-0000-0000-0000-000000003403', 'l_editor', 'Editor', 'human');
INSERT INTO mdm.user_role (user_id, role_code, hierarchy_id, granted_by, valid_period) VALUES
  ('00000000-0000-0000-0000-000000003401', 'ADMIN', NULL, '00000000-0000-0000-0000-000000003402', daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-000000003402', 'ADMIN', NULL, '00000000-0000-0000-0000-000000003401', daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-000000003403', 'EDITOR', NULL, '00000000-0000-0000-0000-000000003401', daterange('2020-01-01', NULL));

SET LOCAL ROLE nexus_api;
SELECT throws_ok($$INSERT INTO mdm.load_run (load_run_id, target_version_name, manifest_sha256, plan, prepared_by)
  VALUES ('00000000-0000-0000-0000-0000000034a1', 'V', repeat('a', 64), '{}', '00000000-0000-0000-0000-000000003403')$$,
  'N1035', NULL, 'Only an ADMIN prepares a load');
SELECT lives_ok($$INSERT INTO mdm.load_run (load_run_id, target_version_name, manifest_sha256, plan, prepared_by)
  VALUES ('00000000-0000-0000-0000-0000000034a1', 'V', repeat('a', 64), '{}', '00000000-0000-0000-0000-000000003401')$$,
  'An ADMIN prepares one');
SELECT throws_ok($$UPDATE mdm.load_run SET status = 'approved', approved_by = '00000000-0000-0000-0000-000000003401'
  WHERE load_run_id = '00000000-0000-0000-0000-0000000034a1'$$, 'N1001', NULL, 'The preparer cannot approve it (maker-checker)');
SELECT throws_ok($$UPDATE mdm.load_run SET status = 'approved', approved_by = '00000000-0000-0000-0000-000000003403'
  WHERE load_run_id = '00000000-0000-0000-0000-0000000034a1'$$, 'N1035', NULL, 'An approver must be an ADMIN');
SELECT throws_ok($$UPDATE mdm.load_run SET status = 'applying' WHERE load_run_id = '00000000-0000-0000-0000-0000000034a1'$$,
  'N2814', NULL, 'A load is not applied before it is approved');
SELECT throws_ok($$SELECT mdm.load_apply_scopes('00000000-0000-0000-0000-0000000034a1', '00000000-0000-0000-0000-000000003402')$$,
  'N2814', NULL, 'No configuration is written without an approved run being applied');
SELECT lives_ok($$UPDATE mdm.load_run SET status = 'approved', approved_by = '00000000-0000-0000-0000-000000003402', approved_at = now()
  WHERE load_run_id = '00000000-0000-0000-0000-0000000034a1'$$, 'A second ADMIN approves it');
RESET ROLE;
SELECT throws_ok($$UPDATE mdm.load_run SET manifest_sha256 = repeat('b', 64) WHERE load_run_id = '00000000-0000-0000-0000-0000000034a1'$$,
  'N2814', NULL, 'The approved manifest cannot change');
SET LOCAL ROLE nexus_api;
UPDATE mdm.load_run SET status = 'applying' WHERE load_run_id = '00000000-0000-0000-0000-0000000034a1';
SELECT throws_ok($$SELECT mdm.load_apply_scopes('00000000-0000-0000-0000-0000000034a1', '00000000-0000-0000-0000-000000003401')$$,
  'N2814', NULL, 'Only the approver applies it');
SELECT lives_ok($$SELECT mdm.load_apply_scopes('00000000-0000-0000-0000-0000000034a1', '00000000-0000-0000-0000-000000003402')$$,
  '… who can');

SELECT throws_ok($$SELECT mdm.provision_user('l_new', 'New user', 'human', '00000000-0000-0000-0000-000000003403')$$,
  'N1035', NULL, 'Only an ADMIN adds users');
SELECT mdm.provision_user('l_svc', 'Feed', 'service', '00000000-0000-0000-0000-000000003401');
SELECT is((SELECT kind::text FROM mdm.app_user WHERE login = 'l_svc'), 'service', 'An ADMIN adds a user of the given kind');
RESET ROLE;

-- add_node "active": false creates an inactive node
INSERT INTO mdm.version (version_id, version_name, business_as_of) VALUES ('00000000-0000-0000-0000-0000000034b1', 'L_V', current_date);
INSERT INTO mdm.node (node_id, node_kind) VALUES ('00000000-0000-0000-0000-0000000034c1', 'structural'), ('00000000-0000-0000-0000-0000000034c2', 'structural');
INSERT INTO mdm.node_attr (node_id, node_name, allows_children, valid_period)
VALUES ('00000000-0000-0000-0000-0000000034c1', 'LTOP', true, daterange('2020-01-01', NULL));
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id)
VALUES ('00000000-0000-0000-0000-0000000034d1', 'L_H', 'L', '00000000-0000-0000-0000-0000000034c1');
INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, effective_from)
VALUES ('00000000-0000-0000-0000-0000000034e1', '00000000-0000-0000-0000-0000000034b1', 'L inactive', '00000000-0000-0000-0000-000000003403', 'human', '2030-01-01');
INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, target_parent_id, payload)
VALUES ('00000000-0000-0000-0000-0000000034e1', 1, 'add_node', '00000000-0000-0000-0000-0000000034d1', '00000000-0000-0000-0000-0000000034c2',
        '00000000-0000-0000-0000-0000000034c1', '{"name": "30220", "isLeaf": true, "active": false}');
UPDATE mdm.change_request SET status = 'submitted' WHERE change_request_id = '00000000-0000-0000-0000-0000000034e1';
UPDATE mdm.change_request SET status = 'approved', decided_by = '00000000-0000-0000-0000-000000003401', decided_at = now(),
       decision_basis = 'human_review' WHERE change_request_id = '00000000-0000-0000-0000-0000000034e1';
SELECT mdm.apply_change_request('00000000-0000-0000-0000-0000000034e1', '00000000-0000-0000-0000-000000003401');
SELECT is((SELECT is_active FROM mdm.node_attr WHERE node_id = '00000000-0000-0000-0000-0000000034c2' AND upper_inf(recorded_period)),
  false, 'add_node with "active": false creates an inactive node');

SELECT * FROM finish();
ROLLBACK;
