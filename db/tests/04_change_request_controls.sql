-- pgTAP: change-request controls added in Phase 1 (ADR-021): truthful requester kind, guarded status transitions,
-- content frozen after draft, items editable only in drafts, item audit, row version, origin, hard limits.
BEGIN;
SELECT plan(19);

-- ---------------------------------------------------------------- fixtures (synthetic)
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-0000000004a1', 'c_steward',  'Steward',  'human'),
  ('00000000-0000-0000-0000-0000000004a2', 'c_approver', 'Approver', 'human'),
  ('00000000-0000-0000-0000-0000000004a3', 'c_ai',       'AI agent', 'ai_agent');
INSERT INTO mdm.version (version_id, version_name, business_as_of)
VALUES ('00000000-0000-0000-0000-0000000004b1', 'C_VERSION', current_date);
INSERT INTO mdm.node (node_id, node_kind) VALUES ('00000000-0000-0000-0000-0000000004c1', 'legal_entity');

INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, risk_tier, effective_from) VALUES
  ('00000000-0000-0000-0000-0000000004f1', '00000000-0000-0000-0000-0000000004b1', 'C draft',     '00000000-0000-0000-0000-0000000004a1', 'human', 'medium', current_date),
  ('00000000-0000-0000-0000-0000000004f2', '00000000-0000-0000-0000-0000000004b1', 'C submitted', '00000000-0000-0000-0000-0000000004a1', 'human', 'medium', current_date);
UPDATE mdm.change_request SET status = 'submitted', submitted_at = now()
WHERE change_request_id = '00000000-0000-0000-0000-0000000004f2';

INSERT INTO wf.user_group (group_id, group_code, name)
VALUES ('00000000-0000-0000-0000-0000000004e1', 'C_OWNERS', 'Test owners');

-- ---------------------------------------------------------------- requester kind (D-05)
SELECT throws_ok(
  $$INSERT INTO mdm.change_request (version_id, title, requester_id, requester_kind, effective_from)
    VALUES ('00000000-0000-0000-0000-0000000004b1', 'C lie', '00000000-0000-0000-0000-0000000004a3', 'human', current_date)$$,
  'N1005', NULL, 'An AI agent cannot file a request labelled as human');

SELECT lives_ok(
  $$INSERT INTO mdm.change_request (version_id, title, requester_id, requester_kind, ai_model, ai_confidence, rationale, effective_from)
    VALUES ('00000000-0000-0000-0000-0000000004b1', 'C truthful AI', '00000000-0000-0000-0000-0000000004a3', 'ai_agent',
            'test-model', 0.9, 'synthetic rationale', current_date)$$,
  'An AI request labelled as AI is accepted');

-- ---------------------------------------------------------------- status transitions (D-07)
SELECT throws_ok(
  $$UPDATE mdm.change_request SET status = 'applied' WHERE change_request_id = '00000000-0000-0000-0000-0000000004f1'$$,
  'N2101', NULL, 'draft -> applied is not a valid transition');

SELECT throws_ok(
  $$UPDATE mdm.change_request SET status = 'draft' WHERE change_request_id = '00000000-0000-0000-0000-0000000004f2'$$,
  'N2101', NULL, 'submitted -> draft is not a valid transition');

SELECT lives_ok(
  $$UPDATE mdm.change_request SET status = 'approved', decided_by = '00000000-0000-0000-0000-0000000004a2',
           decided_at = now(), decision_basis = 'human_review'
    WHERE change_request_id = '00000000-0000-0000-0000-0000000004f2'$$,
  'submitted -> approved by another human is allowed');

SELECT lives_ok(
  $$UPDATE mdm.change_request SET status = 'applied', applied_at = now()
    WHERE change_request_id = '00000000-0000-0000-0000-0000000004f2'$$,
  'approved -> applied is allowed');

SELECT throws_ok(
  $$UPDATE mdm.change_request SET status = 'draft' WHERE change_request_id = '00000000-0000-0000-0000-0000000004f2'$$,
  'N2101', NULL, 'applied -> draft is not a valid transition');

-- ---------------------------------------------------------------- frozen content after draft (D-07)
SELECT throws_ok(
  $$UPDATE mdm.change_request SET title = 'C changed after submit' WHERE change_request_id = '00000000-0000-0000-0000-0000000004f2'$$,
  'N2102', NULL, 'A submitted or later request''s content cannot change');

SELECT lives_ok(
  $$UPDATE mdm.change_request SET title = 'C draft renamed' WHERE change_request_id = '00000000-0000-0000-0000-0000000004f1'$$,
  'A draft''s content can change');

SELECT is(
  (SELECT row_version FROM mdm.change_request WHERE change_request_id = '00000000-0000-0000-0000-0000000004f1'),
  2, 'Each update of a request increments row_version');

-- ---------------------------------------------------------------- items only in drafts (D-07)
SELECT lives_ok(
  $$INSERT INTO mdm.change_item (change_request_id, seq, action, node_id)
    VALUES ('00000000-0000-0000-0000-0000000004f1', 1, 'update_node', '00000000-0000-0000-0000-0000000004c1')$$,
  'Items can be added to a draft');

SELECT is(
  (SELECT row_version FROM mdm.change_request WHERE change_request_id = '00000000-0000-0000-0000-0000000004f1'),
  3, 'Adding an item increments the request''s row_version');

SELECT throws_ok(
  $$INSERT INTO mdm.change_item (change_request_id, seq, action, node_id)
    VALUES ('00000000-0000-0000-0000-0000000004f2', 1, 'update_node', '00000000-0000-0000-0000-0000000004c1')$$,
  'N2102', NULL, 'Items cannot be added once the request has left draft');

SELECT ok(
  EXISTS (SELECT 1 FROM mdm.audit_log WHERE table_name = 'change_item' AND action = 'INSERT'),
  'Item changes are written to the audit log');

SELECT throws_ok(
  $$DELETE FROM mdm.change_request WHERE change_request_id = '00000000-0000-0000-0000-0000000004f2'$$,
  'N2102', NULL, 'A request that has left draft cannot be deleted (its items would go with it)');

-- ---------------------------------------------------------------- origin (CR-04)
SELECT throws_ok(
  $$INSERT INTO mdm.change_request (version_id, title, requester_id, requester_kind, effective_from, origin)
    VALUES ('00000000-0000-0000-0000-0000000004b1', 'C bad origin', '00000000-0000-0000-0000-0000000004a1', 'human', current_date, 'email')$$,
  '23514', NULL, 'Origin must be one of user, sandbox, load, ai');

-- ---------------------------------------------------------------- new hard limits (D-36, ADR-026)
SELECT throws_ok(
  $$INSERT INTO wf.commit_policy (policy_code, description, rationale, allowed_actions, owner_group_id, proposed_by)
    VALUES ('C_DEL', 'd', 'r', '{delete_node}', '00000000-0000-0000-0000-0000000004e1', '00000000-0000-0000-0000-0000000004a1')$$,
  '23514', NULL, 'Deletes can never be auto-committed');

SELECT throws_ok(
  $$INSERT INTO wf.commit_policy (policy_code, description, rationale, allowed_actions, owner_group_id, proposed_by)
    VALUES ('C_HIER', 'd', 'r', '{add_hierarchy}', '00000000-0000-0000-0000-0000000004e1', '00000000-0000-0000-0000-0000000004a1')$$,
  '23514', NULL, 'Creating hierarchies can never be auto-committed');

SELECT throws_ok(
  $$INSERT INTO wf.commit_policy (policy_code, description, rationale, allowed_actions, owner_group_id, proposed_by)
    VALUES ('C_REN', 'd', 'r', '{update_node}', '00000000-0000-0000-0000-0000000004e1', '00000000-0000-0000-0000-0000000004a1')$$,
  '23514', NULL, 'Renames can never be auto-committed');

SELECT * FROM finish();
ROLLBACK;
