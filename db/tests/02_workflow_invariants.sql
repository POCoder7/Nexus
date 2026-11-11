-- pgTAP: workflow layer and commit-policy invariants (V4–V6).
BEGIN;
SELECT plan(17);

-- ---------------------------------------------------------------- fixtures
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-0000000001a1', 'w_maker',   'Maker',    'human'),
  ('00000000-0000-0000-0000-0000000001a2', 'w_checker', 'Checker',  'human'),
  ('00000000-0000-0000-0000-0000000001a3', 'w_ai',      'AI agent', 'ai_agent'),
  ('00000000-0000-0000-0000-0000000001a4', 'w_system',  'System',   'system_feed');

INSERT INTO mdm.version (version_id, version_name, business_as_of)
VALUES ('00000000-0000-0000-0000-0000000001b1', 'W_VERSION', current_date);

INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, risk_tier)
VALUES ('00000000-0000-0000-0000-0000000001f1', '00000000-0000-0000-0000-0000000001b1', 'W request',
        '00000000-0000-0000-0000-0000000001a1', 'human', 'low');

INSERT INTO wf.workflow_model (model_id, model_code, label)
VALUES ('00000000-0000-0000-0000-0000000001c1', 'W_MODEL', 'Test model');

INSERT INTO wf.workflow_instance (instance_id, change_request_id, model_id, status, current_seq, submitted_by, submitted_at)
VALUES ('00000000-0000-0000-0000-0000000001d1', '00000000-0000-0000-0000-0000000001f1',
        '00000000-0000-0000-0000-0000000001c1', 'in_flight', 1, '00000000-0000-0000-0000-0000000001a1', now());

INSERT INTO wf.user_group (group_id, group_code, name)
VALUES ('00000000-0000-0000-0000-0000000001e1', 'W_OWNERS', 'Test owners');

INSERT INTO wf.user_group_member (group_id, user_id)
SELECT group_id, '00000000-0000-0000-0000-0000000001a2' FROM wf.user_group WHERE group_code = 'POLICY_APPROVERS';

-- ---------------------------------------------------------------- history guard
SELECT throws_like(
  $$INSERT INTO wf.instance_action (instance_id, actor_id, actor_kind, action, ai_model, ai_confidence)
    VALUES ('00000000-0000-0000-0000-0000000001d1', '00000000-0000-0000-0000-0000000001a3', 'ai_agent', 'approve', 'test-model', 0.99)$$,
  '%can only be performed by a human%', 'AI agents cannot approve');

SELECT throws_like(
  $$INSERT INTO wf.instance_action (instance_id, actor_id, actor_kind, action)
    VALUES ('00000000-0000-0000-0000-0000000001d1', '00000000-0000-0000-0000-0000000001a3', 'human', 'comment')$$,
  '%does not match%', 'Actor kind must match the user record');

SELECT throws_like(
  $$INSERT INTO wf.instance_action (instance_id, actor_id, actor_kind, action)
    VALUES ('00000000-0000-0000-0000-0000000001d1', '00000000-0000-0000-0000-0000000001a3', 'ai_agent', 'comment')$$,
  '%ai_model%', 'AI actions must record model and confidence');

SELECT lives_ok(
  $$INSERT INTO wf.instance_action (instance_id, actor_id, actor_kind, action, ai_model, ai_confidence)
    VALUES ('00000000-0000-0000-0000-0000000001d1', '00000000-0000-0000-0000-0000000001a3', 'ai_agent', 'ai_suggestion', 'test-model', 0.8)$$,
  'AI suggestions are recorded');

SELECT throws_like(
  $$INSERT INTO wf.instance_action (instance_id, actor_id, actor_kind, action, payload)
    VALUES ('00000000-0000-0000-0000-0000000001d1', '00000000-0000-0000-0000-0000000001a4', 'system_feed', 'commit', '{}')$$,
  '%approved commit policy%', 'The system cannot commit without a policy evaluation');

SELECT throws_like(
  $$UPDATE wf.instance_action SET comment = 'tampered'$$,
  '%append-only%', 'Request history is append-only');

-- ---------------------------------------------------------------- commit policies
SELECT throws_ok(
  $$INSERT INTO wf.commit_policy (policy_code, description, rationale, allowed_actions, owner_group_id, proposed_by)
    VALUES ('W_BAD', 'd', 'r', '{move_node}', '00000000-0000-0000-0000-0000000001e1', '00000000-0000-0000-0000-0000000001a1')$$,
  '23514', NULL, 'Hard limits: moves can never be auto-committed');

SELECT lives_ok(
  $$INSERT INTO wf.commit_policy (policy_id, policy_code, description, rationale, allowed_actions, owner_group_id, proposed_by)
    VALUES ('00000000-0000-0000-0000-000000000199', 'W_POLICY', 'Routine adds', 'Low risk',
            '{add_node,insert_node,set_property}', '00000000-0000-0000-0000-0000000001e1', '00000000-0000-0000-0000-0000000001a1')$$,
  'A draft policy can be created');

SELECT lives_ok(
  $$INSERT INTO wf.policy_scope (policy_id, model_code) VALUES ('00000000-0000-0000-0000-000000000199', 'W_MODEL')$$,
  'A draft policy can be scoped to a model');

SELECT lives_ok(
  $$SELECT wf.submit_commit_policy('00000000-0000-0000-0000-000000000199', '00000000-0000-0000-0000-0000000001a1')$$,
  'The proposer can submit it for approval');

SELECT throws_like(
  $$SELECT wf.approve_commit_policy('00000000-0000-0000-0000-000000000199', '00000000-0000-0000-0000-0000000001a1', 'self')$$,
  '%Maker-checker%', 'The proposer cannot approve their own policy');

SELECT throws_like(
  $$SELECT wf.approve_commit_policy('00000000-0000-0000-0000-000000000199', '00000000-0000-0000-0000-0000000001a3', 'ai')$$,
  '%approved by a human%', 'AI agents cannot approve policies');

SELECT lives_ok(
  $$SELECT wf.approve_commit_policy('00000000-0000-0000-0000-000000000199', '00000000-0000-0000-0000-0000000001a2', 'ok')$$,
  'An approver in POLICY_APPROVERS can approve');

SELECT throws_like(
  $$UPDATE wf.commit_policy SET max_items_per_request = 5 WHERE policy_id = '00000000-0000-0000-0000-000000000199'$$,
  '%immutable%', 'Approved policies are immutable');

SELECT lives_ok(
  $$SELECT wf.engage_kill_switch('W_POLICY', '00000000-0000-0000-0000-0000000001a2', 'test')$$,
  'An approver can engage the kill switch');

SELECT throws_like(
  $$UPDATE wf.commit_policy SET kill_switch = false WHERE policy_id = '00000000-0000-0000-0000-000000000199'$$,
  '%kill switch%', 'The kill switch is one-way');

SELECT ok(
  (SELECT 'kill switch engaged' = ANY (failed_checks)
   FROM wf.evaluate_commit_policy('00000000-0000-0000-0000-0000000001d1', now())),
  'A kill-switched policy makes requests ineligible');

SELECT * FROM finish();
ROLLBACK;
