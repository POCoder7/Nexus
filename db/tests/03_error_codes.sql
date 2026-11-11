-- pgTAP: guards raise stable SQLSTATE codes (ADR-020, registry in docs/design/CONSISTENCY_REVIEW.md §3).
-- Messages are asserted elsewhere (01, 02); this file asserts the machine-readable codes only.
BEGIN;
SELECT plan(10);

-- ---------------------------------------------------------------- fixtures (synthetic)
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-0000000003a1', 'e_maker',   'Maker',    'human'),
  ('00000000-0000-0000-0000-0000000003a2', 'e_checker', 'Checker',  'human'),
  ('00000000-0000-0000-0000-0000000003a3', 'e_ai',      'AI agent', 'ai_agent');

INSERT INTO mdm.version (version_id, version_name, business_as_of)
VALUES ('00000000-0000-0000-0000-0000000003b1', 'E_VERSION', current_date);

INSERT INTO mdm.node (node_id, node_kind) VALUES
  ('00000000-0000-0000-0000-0000000003c1', 'structural'),
  ('00000000-0000-0000-0000-0000000003c2', 'legal_entity'),
  ('00000000-0000-0000-0000-0000000003c3', 'legal_entity');
INSERT INTO mdm.node_attr (node_id, node_name) VALUES
  ('00000000-0000-0000-0000-0000000003c1', 'E_TOP'),
  ('00000000-0000-0000-0000-0000000003c2', 'E_B'),
  ('00000000-0000-0000-0000-0000000003c3', 'E_C');
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id)
VALUES ('00000000-0000-0000-0000-0000000003d1', 'E_H1', 'Error-code hierarchy', '00000000-0000-0000-0000-0000000003c1');
INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id) VALUES
  ('00000000-0000-0000-0000-0000000003d1', '00000000-0000-0000-0000-0000000003c1', '00000000-0000-0000-0000-0000000003c2'),
  ('00000000-0000-0000-0000-0000000003d1', '00000000-0000-0000-0000-0000000003c2', '00000000-0000-0000-0000-0000000003c3');

INSERT INTO mdm.property_definition (property_id, property_code, label, data_type, scope)
VALUES ('00000000-0000-0000-0000-0000000003e1', 'E.Int', 'Error-code integer', 'integer', 'global');

INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, risk_tier)
VALUES ('00000000-0000-0000-0000-0000000003f1', '00000000-0000-0000-0000-0000000003b1', 'E request',
        '00000000-0000-0000-0000-0000000003a1', 'human', 'medium');

-- ---------------------------------------------------------------- N1 controls
SELECT throws_ok(
  $$UPDATE mdm.change_request SET status = 'approved', decided_by = '00000000-0000-0000-0000-0000000003a1'
    WHERE change_request_id = '00000000-0000-0000-0000-0000000003f1'$$,
  'N1001', NULL, 'Self-approval raises N1001');

SELECT throws_ok(
  $$UPDATE mdm.change_request SET status = 'approved', decided_by = '00000000-0000-0000-0000-0000000003a3'
    WHERE change_request_id = '00000000-0000-0000-0000-0000000003f1'$$,
  'N1002', NULL, 'A non-human decider raises N1002');

-- ---------------------------------------------------------------- N2 integrity
SELECT throws_ok(
  $$INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id)
    VALUES ('00000000-0000-0000-0000-0000000003d1', '00000000-0000-0000-0000-0000000003c3', '00000000-0000-0000-0000-0000000003c2')$$,
  'N2001', NULL, 'A cycle raises N2001');

SELECT throws_ok(
  $$INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id)
    VALUES ('00000000-0000-0000-0000-0000000003d1', '00000000-0000-0000-0000-0000000003c2', '00000000-0000-0000-0000-0000000003c1')$$,
  'N2002', NULL, 'Parenting the top node raises N2002');

SELECT throws_ok(
  $$INSERT INTO mdm.hierarchy_relationship (hierarchy_id, parent_node_id, child_node_id, is_primary)
    VALUES ('00000000-0000-0000-0000-0000000003d1', '00000000-0000-0000-0000-0000000003c1', '00000000-0000-0000-0000-0000000003c3', false)$$,
  'N2003', NULL, 'A shared node in a hierarchy without shared nodes raises N2003');

SELECT throws_ok(
  $$UPDATE mdm.node_attr SET node_name = 'E_RENAMED' WHERE node_id = '00000000-0000-0000-0000-0000000003c2'$$,
  'N2010', NULL, 'Editing a fact in place raises N2010');

SELECT throws_ok(
  $$UPDATE mdm.audit_log SET table_name = 'tampered'$$,
  'N2011', NULL, 'Changing an append-only table raises N2011');

SELECT throws_ok(
  $$INSERT INTO mdm.property_value (node_id, property_id, hierarchy_id, value)
    VALUES ('00000000-0000-0000-0000-0000000003c2', '00000000-0000-0000-0000-0000000003e1',
            '00000000-0000-0000-0000-0000000003d1', '5')$$,
  'N2020', NULL, 'A hierarchy on a global property raises N2020');

SELECT throws_ok(
  $$INSERT INTO mdm.property_value (node_id, property_id, value)
    VALUES ('00000000-0000-0000-0000-0000000003c2', '00000000-0000-0000-0000-0000000003e1', '"abc"')$$,
  'N2022', NULL, 'A wrong value type raises N2022');

-- ---------------------------------------------------------------- workflow layer (V4/V6 guards)
INSERT INTO wf.workflow_model (model_id, model_code, label)
VALUES ('00000000-0000-0000-0000-000000000371', 'E_MODEL', 'Error-code model');
INSERT INTO wf.workflow_instance (instance_id, change_request_id, model_id, status, current_seq, submitted_by, submitted_at)
VALUES ('00000000-0000-0000-0000-000000000381', '00000000-0000-0000-0000-0000000003f1',
        '00000000-0000-0000-0000-000000000371', 'in_flight', 1, '00000000-0000-0000-0000-0000000003a1', now());

SELECT throws_ok(
  $$INSERT INTO wf.instance_action (instance_id, actor_id, actor_kind, action)
    VALUES ('00000000-0000-0000-0000-000000000381', '00000000-0000-0000-0000-0000000003a3', 'human', 'comment')$$,
  'N1017', NULL, 'A false actor kind in request history raises N1017');

SELECT * FROM finish();
ROLLBACK;
