-- pgTAP: least-privilege roles (ADR-014, ADR-019, D-04). Each block switches to a role with SET LOCAL ROLE and
-- proves what it may and may not do. 42501 = insufficient_privilege.
BEGIN;
SELECT plan(17);

SELECT has_role('nexus_api');
SELECT has_role('nexus_wf');
SELECT has_role('nexus_bridge');
SELECT has_role('nexus_apply');
SELECT has_role('nexus_decider');
SELECT has_role('nexus_readonly');

-- ---------------------------------------------------------------- fixtures (as the owner; synthetic)
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-0000000005a1', 'r_steward', 'Steward', 'human');
INSERT INTO mdm.version (version_id, version_name, business_as_of)
VALUES ('00000000-0000-0000-0000-0000000005b1', 'R_VERSION', current_date);
INSERT INTO mdm.node (node_id, node_kind) VALUES ('00000000-0000-0000-0000-0000000005c1', 'legal_entity');
INSERT INTO mdm.node_attr (node_id, node_name) VALUES ('00000000-0000-0000-0000-0000000005c1', 'R_NODE');
INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind)
VALUES ('00000000-0000-0000-0000-0000000005f1', '00000000-0000-0000-0000-0000000005b1', 'R request',
        '00000000-0000-0000-0000-0000000005a1', 'human');
INSERT INTO wf.workflow_model (model_id, model_code, label)
VALUES ('00000000-0000-0000-0000-000000000571', 'R_MODEL', 'Roles model');

-- ---------------------------------------------------------------- the application role
SET LOCAL ROLE nexus_api;

SELECT lives_ok(
  $$INSERT INTO mdm.change_request (version_id, title, requester_id, requester_kind)
    VALUES ('00000000-0000-0000-0000-0000000005b1', 'R draft by api', '00000000-0000-0000-0000-0000000005a1', 'human')$$,
  'nexus_api can create draft requests (triggers and audit run without extra rights)');

SELECT lives_ok(
  $$INSERT INTO mdm.change_item (change_request_id, seq, action, node_id)
    VALUES ('00000000-0000-0000-0000-0000000005f1', 1, 'update_node', '00000000-0000-0000-0000-0000000005c1')$$,
  'nexus_api can add items to a draft');

SELECT throws_ok(
  $$UPDATE mdm.change_request SET status = 'submitted' WHERE change_request_id = '00000000-0000-0000-0000-0000000005f1'$$,
  '42501', NULL, 'nexus_api cannot set a request''s status directly');

SELECT throws_ok(
  $$UPDATE mdm.change_request SET decision_basis = 'approved_policy' WHERE change_request_id = '00000000-0000-0000-0000-0000000005f1'$$,
  '42501', NULL, 'nexus_api cannot write decision columns (D-04)');

SELECT throws_ok(
  $$INSERT INTO mdm.node_attr (node_id, node_name) VALUES ('00000000-0000-0000-0000-0000000005c1', 'R_FORGED')$$,
  '42501', NULL, 'nexus_api cannot write facts');

SELECT throws_ok(
  $$UPDATE mdm.node_attr SET recorded_period = tstzrange(lower(recorded_period), now())
    WHERE node_id = '00000000-0000-0000-0000-0000000005c1'$$,
  '42501', NULL, 'nexus_api cannot close facts');

SELECT throws_ok(
  $$INSERT INTO mdm.audit_log (table_name, action) VALUES ('node_attr', 'INSERT')$$,
  '42501', NULL, 'nexus_api cannot write audit rows directly');

RESET ROLE;

-- ---------------------------------------------------------------- the workflow role
SET LOCAL ROLE nexus_wf;

SELECT throws_ok(
  $$UPDATE mdm.change_request SET status = 'in_review' WHERE change_request_id = '00000000-0000-0000-0000-0000000005f1'$$,
  '42501', NULL, 'nexus_wf cannot write mdm (layer rule)');

SELECT lives_ok(
  $$INSERT INTO wf.workflow_instance (instance_id, change_request_id, model_id, status, current_seq, submitted_by, submitted_at)
    VALUES ('00000000-0000-0000-0000-000000000581', '00000000-0000-0000-0000-0000000005f1',
            '00000000-0000-0000-0000-000000000571', 'in_flight', 1, '00000000-0000-0000-0000-0000000005a1', now())$$,
  'nexus_wf can start a workflow instance');

RESET ROLE;

SELECT is(
  (SELECT status::text FROM mdm.change_request WHERE change_request_id = '00000000-0000-0000-0000-0000000005f1'),
  'in_review', 'The bridge (nexus_bridge, security definer) moved the request to in_review on the workflow''s behalf');

-- ---------------------------------------------------------------- the read-only role
SET LOCAL ROLE nexus_readonly;

SELECT throws_ok(
  $$INSERT INTO mdm.change_request (version_id, title, requester_id, requester_kind)
    VALUES ('00000000-0000-0000-0000-0000000005b1', 'R by readonly', '00000000-0000-0000-0000-0000000005a1', 'human')$$,
  '42501', NULL, 'nexus_readonly cannot write');

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
