-- pgTAP: Phase 2 test-design cases not covered elsewhere (LLD §13): an active model cannot be edited (GOV-01 control),
-- a decision on a stage that has not started is refused with its reason (GOV-02), and shadow evaluations feed the
-- shadow summary (GOV-12). Synthetic data only.
BEGIN;
SELECT plan(6);

INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-000000002001', 'x_steward',  'Steward',  'human'),
  ('00000000-0000-0000-0000-000000002002', 'x_approver', 'Approver', 'human'),
  ('00000000-0000-0000-0000-000000002003', 'x_system',   'System',   'system_feed'),
  ('00000000-0000-0000-0000-000000002004', 'x_policy',   'Policy approver', 'human');
INSERT INTO mdm.version (version_id, version_name, business_as_of) VALUES ('00000000-0000-0000-0000-000000002011', 'X_V', current_date);
INSERT INTO mdm.node (node_id, node_kind) VALUES ('00000000-0000-0000-0000-000000002021', 'legal_entity');
INSERT INTO mdm.property_definition (property_id, property_code, label, data_type, scope)
VALUES ('00000000-0000-0000-0000-000000002031', 'X.Note', 'Note', 'string', 'global');
INSERT INTO wf.user_group (group_id, group_code, name) VALUES
  ('00000000-0000-0000-0000-000000002041', 'X_APPROVERS', 'Approvers'), ('00000000-0000-0000-0000-000000002042', 'X_OWNERS', 'Owners');
INSERT INTO wf.user_group_member (group_id, user_id) VALUES ('00000000-0000-0000-0000-000000002041', '00000000-0000-0000-0000-000000002002');
INSERT INTO wf.user_group_member (group_id, user_id)
SELECT group_id, '00000000-0000-0000-0000-000000002004' FROM wf.user_group WHERE group_code = 'POLICY_APPROVERS';
INSERT INTO wf.workflow_task (task_id, task_code, label, allowed_actions) VALUES ('00000000-0000-0000-0000-000000002051', 'X_TASK', 'Task', '{set_property}');
INSERT INTO wf.workflow_model (model_id, model_code, label) VALUES ('00000000-0000-0000-0000-000000002061', 'X_MODEL', 'Model');
INSERT INTO wf.workflow_stage (stage_id, model_id, seq, stage_type, label, task_id) VALUES
  ('00000000-0000-0000-0000-000000002071', '00000000-0000-0000-0000-000000002061', 1, 'submit',  'Submit', NULL),
  ('00000000-0000-0000-0000-000000002072', '00000000-0000-0000-0000-000000002061', 2, 'approve', 'Review', '00000000-0000-0000-0000-000000002051'),
  ('00000000-0000-0000-0000-000000002073', '00000000-0000-0000-0000-000000002061', 3, 'commit',  'Commit', NULL);
INSERT INTO wf.submit_task VALUES ('00000000-0000-0000-0000-000000002061', '00000000-0000-0000-0000-000000002051');
INSERT INTO wf.stage_group (stage_id, group_id) VALUES
  ('00000000-0000-0000-0000-000000002072', '00000000-0000-0000-0000-000000002041'),
  ('00000000-0000-0000-0000-000000002073', '00000000-0000-0000-0000-000000002041');
UPDATE wf.workflow_model SET status = 'active', activated_by = '00000000-0000-0000-0000-000000002004'
WHERE model_id = '00000000-0000-0000-0000-000000002061';

-- GOV-01 control: an active model is frozen ------------------------------------------------------------------------
SELECT throws_ok($$UPDATE wf.workflow_stage SET label = 'Changed' WHERE stage_id = '00000000-0000-0000-0000-000000002072'$$,
  'N2205', NULL, 'A stage of an active model cannot be edited (a new version is needed)');
SELECT throws_ok($$UPDATE wf.workflow_model SET label = 'Changed' WHERE model_id = '00000000-0000-0000-0000-000000002061'$$,
  'N2205', NULL, 'An active model cannot be edited');

-- GOV-02: a stage that has not started cannot be decided, and the reason says so -----------------------------------
INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind, risk_tier)
VALUES ('00000000-0000-0000-0000-000000002081', '00000000-0000-0000-0000-000000002011', 'X request', '00000000-0000-0000-0000-000000002001', 'human', 'low');
INSERT INTO mdm.change_item (change_request_id, seq, action, node_id, property_id, payload)
VALUES ('00000000-0000-0000-0000-000000002081', 1, 'set_property', '00000000-0000-0000-0000-000000002021', '00000000-0000-0000-0000-000000002031', '{"value": "x"}');
CREATE TEMP TABLE x (k text PRIMARY KEY, id uuid);
INSERT INTO x SELECT 'i', wf.start_instance('00000000-0000-0000-0000-000000002081', 'X_MODEL', '00000000-0000-0000-0000-000000002001');
INSERT INTO x SELECT 'review', instance_stage_id FROM wf.instance_stage WHERE instance_id = (SELECT id FROM x WHERE k = 'i') AND seq = 2;
GRANT SELECT ON x TO nexus_api;
SET LOCAL ROLE nexus_api;
SELECT throws_ok($$SELECT wf.record_stage_decision((SELECT id FROM x WHERE k = 'review'), '00000000-0000-0000-0000-000000002002', 'approve', NULL)$$,
  'N1016', NULL, 'A stage that has not started cannot be decided');
SELECT is((SELECT code FROM wf.why_cannot_act((SELECT id FROM x WHERE k = 'review'), '00000000-0000-0000-0000-000000002002')),
  'wf.stage_not_open', '… and the explanation says the stage is not open');
RESET ROLE;

-- GOV-12: shadow evaluations feed the shadow summary ----------------------------------------------------------------
INSERT INTO wf.commit_policy (policy_id, policy_code, description, rationale, mode, allowed_actions, owner_group_id, proposed_by)
VALUES ('00000000-0000-0000-0000-000000002091', 'X_SHADOW', 'Notes', 'Test', 'shadow', '{set_property}',
        '00000000-0000-0000-0000-000000002042', '00000000-0000-0000-0000-000000002001');
INSERT INTO wf.policy_scope (policy_id, model_code) VALUES ('00000000-0000-0000-0000-000000002091', 'X_MODEL');
SELECT wf.submit_commit_policy('00000000-0000-0000-0000-000000002091', '00000000-0000-0000-0000-000000002001');
SELECT wf.approve_commit_policy('00000000-0000-0000-0000-000000002091', '00000000-0000-0000-0000-000000002004', 'shadow');
SELECT wf.apply_commit_policy((SELECT id FROM x WHERE k = 'i'), now(), '00000000-0000-0000-0000-000000002003');
SELECT is((SELECT policy_mode::text FROM wf.policy_evaluation WHERE instance_id = (SELECT id FROM x WHERE k = 'i')),
  'shadow', 'A shadow evaluation is recorded and commits nothing');
SELECT is((SELECT decided_requests || '/' || (would_auto_commit + (SELECT count(*) FROM wf.policy_evaluation pe
             WHERE pe.instance_id = (SELECT id FROM x WHERE k = 'i') AND pe.outcome = 'shadow_would_route'))
           FROM wf.v_shadow_summary WHERE policy_code = 'X_SHADOW'),
  '0/1', 'The shadow summary counts the evaluation; no human decision yet to compare with');

SELECT * FROM finish();
ROLLBACK;
