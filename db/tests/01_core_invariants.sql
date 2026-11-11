-- pgTAP: core model invariants (V1). Each file runs in a transaction and rolls back.
BEGIN;
SELECT plan(18);

-- ---------------------------------------------------------------- fixtures
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 't_maker',   'Maker',    'human'),
  ('00000000-0000-0000-0000-0000000000a2', 't_checker', 'Checker',  'human'),
  ('00000000-0000-0000-0000-0000000000a3', 't_ai',      'AI agent', 'ai_agent'),
  ('00000000-0000-0000-0000-0000000000a4', 't_system',  'System',   'system_feed');

INSERT INTO mdm.version (version_id, version_name, business_as_of)
VALUES ('00000000-0000-0000-0000-0000000000b1', 'T_VERSION', current_date);

INSERT INTO mdm.node (node_id, node_kind) VALUES
  ('00000000-0000-0000-0000-0000000000c1', 'structural'),
  ('00000000-0000-0000-0000-0000000000c2', 'legal_entity'),
  ('00000000-0000-0000-0000-0000000000c3', 'legal_entity'),
  ('00000000-0000-0000-0000-0000000000c4', 'legal_entity');

INSERT INTO mdm.node_attr (node_id, node_name) VALUES
  ('00000000-0000-0000-0000-0000000000c1', 'T_TOP'),
  ('00000000-0000-0000-0000-0000000000c2', 'T_B'),
  ('00000000-0000-0000-0000-0000000000c3', 'T_C'),
  ('00000000-0000-0000-0000-0000000000c4', 'T_D');

INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id)
VALUES ('00000000-0000-0000-0000-0000000000d1', 'T_H1', 'Test hierarchy', '00000000-0000-0000-0000-0000000000c1');

-- TOP -> B -> C
INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, sort_order) VALUES
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c2', 1),
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000c3', 1);

-- ---------------------------------------------------------------- hierarchy integrity
SELECT throws_like(
  $$INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id)
    VALUES ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000c2')$$,
  '%Cycle detected%', 'A node cannot be placed under its own descendant');

SELECT throws_like(
  $$INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id)
    VALUES ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000c1')$$,
  '%top node%', 'The top node cannot be given a parent');

SELECT throws_like(
  $$INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, is_primary)
    VALUES ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c3', false)$$,
  '%does not allow shared nodes%', 'Shared nodes are rejected where the hierarchy disallows them');

SELECT lives_ok(
  $$INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, sort_order)
    VALUES ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000c4', 1)$$,
  'A valid child can be added');

SELECT is(
  (SELECT count(*) FROM mdm.hierarchy_tree('00000000-0000-0000-0000-0000000000d1', current_date)),
  4::bigint, 'hierarchy_tree returns every node');

SELECT is(
  (SELECT is_leaf FROM mdm.hierarchy_tree('00000000-0000-0000-0000-0000000000d1', current_date)
   WHERE node_id = '00000000-0000-0000-0000-0000000000c4'),
  true, 'hierarchy_tree marks leaves');

-- ---------------------------------------------------------------- bitemporal guard
SELECT throws_like(
  $$UPDATE mdm.node_attr SET node_name = 'RENAMED' WHERE node_id = '00000000-0000-0000-0000-0000000000c2'$$,
  '%bitemporal%', 'Facts cannot be edited in place');

SELECT throws_like(
  $$DELETE FROM mdm.node_attr WHERE node_id = '00000000-0000-0000-0000-0000000000c2'$$,
  '%bitemporal%', 'Facts cannot be deleted');

SELECT lives_ok(
  $$UPDATE mdm.node_attr SET recorded_period = tstzrange(lower(recorded_period), clock_timestamp())
    WHERE node_id = '00000000-0000-0000-0000-0000000000c4'$$,
  'Closing recorded_period (a correction) is allowed');

-- ---------------------------------------------------------------- property typing and scope
INSERT INTO mdm.property_definition (property_id, property_code, label, data_type, scope) VALUES
  ('00000000-0000-0000-0000-0000000000e1', 'T.Int',   'Test integer',     'integer', 'global'),
  ('00000000-0000-0000-0000-0000000000e2', 'T.Local', 'Test local string', 'string', 'local');

SELECT throws_like(
  $$INSERT INTO mdm.property_value (node_id, property_id, value)
    VALUES ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000e1', '"abc"')$$,
  '%expects an integer%', 'Typed properties reject the wrong type');

SELECT lives_ok(
  $$INSERT INTO mdm.property_value (node_id, property_id, value)
    VALUES ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000e1', '5')$$,
  'Typed properties accept the right type');

SELECT throws_like(
  $$INSERT INTO mdm.property_value (node_id, property_id, value)
    VALUES ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000e2', '"x"')$$,
  '%is local%', 'Local properties require a hierarchy');

-- ---------------------------------------------------------------- maker-checker
INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, risk_tier) VALUES
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000b1', 'T low',    '00000000-0000-0000-0000-0000000000a1', 'human', 'low'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000b1', 'T medium', '00000000-0000-0000-0000-0000000000a1', 'human', 'medium'),
  ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000b1', 'T human',  '00000000-0000-0000-0000-0000000000a1', 'human', 'medium');
-- Phase 1 (ADR-021): decisions are only valid on submitted requests, so the fixture submits them first.
-- Setup only; every assertion below is unchanged.
UPDATE mdm.change_request SET status = 'submitted', submitted_at = now()
WHERE change_request_id IN ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000f2',
                            '00000000-0000-0000-0000-0000000000f3');

SELECT throws_like(
  $$UPDATE mdm.change_request SET status = 'approved', decided_by = '00000000-0000-0000-0000-0000000000a1'
    WHERE change_request_id = '00000000-0000-0000-0000-0000000000f1'$$,
  '%Maker-checker%', 'Requesters cannot approve their own requests');

SELECT throws_like(
  $$UPDATE mdm.change_request SET status = 'approved', decided_by = '00000000-0000-0000-0000-0000000000a3'
    WHERE change_request_id = '00000000-0000-0000-0000-0000000000f1'$$,
  '%Only human reviewers%', 'AI agents cannot approve');

SELECT throws_like(
  $$UPDATE mdm.change_request SET status = 'approved', decided_by = '00000000-0000-0000-0000-0000000000a4',
           decision_basis = 'approved_policy', decision_policy_ref = gen_random_uuid()
    WHERE change_request_id = '00000000-0000-0000-0000-0000000000f2'$$,
  '%low-risk%', 'Policy-based approval is limited to low-risk requests');

SELECT lives_ok(
  $$UPDATE mdm.change_request SET status = 'approved', decided_by = '00000000-0000-0000-0000-0000000000a4',
           decision_basis = 'approved_policy', decision_policy_ref = gen_random_uuid()
    WHERE change_request_id = '00000000-0000-0000-0000-0000000000f1'$$,
  'Low-risk requests can be approved by the system under a policy');

SELECT lives_ok(
  $$UPDATE mdm.change_request SET status = 'approved', decided_by = '00000000-0000-0000-0000-0000000000a2',
           decision_basis = 'human_review'
    WHERE change_request_id = '00000000-0000-0000-0000-0000000000f3'$$,
  'A different human can approve');

-- ---------------------------------------------------------------- audit log
SELECT throws_like(
  $$UPDATE mdm.audit_log SET table_name = 'tampered'$$,
  '%append-only%', 'The audit log is append-only');

SELECT * FROM finish();
ROLLBACK;
