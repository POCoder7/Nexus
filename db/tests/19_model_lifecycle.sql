-- pgTAP: model definitions, activation by a second administrator (GOV-01), and stage progression with
-- wf.advance_instance / wf.complete_stage (Phase 2 increment 2-7). Synthetic data only.
BEGIN;
SELECT plan(21);

INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-000000001901', 'l_admin1',    'Admin 1',   'human'),
  ('00000000-0000-0000-0000-000000001902', 'l_admin2',    'Admin 2',   'human'),
  ('00000000-0000-0000-0000-000000001903', 'l_steward',   'Steward',   'human'),
  ('00000000-0000-0000-0000-000000001904', 'l_approver',  'Approver',  'human'),
  ('00000000-0000-0000-0000-000000001905', 'l_committer', 'Committer', 'human'),
  ('00000000-0000-0000-0000-000000001906', 'l_system',    'System',    'system_feed'),
  ('00000000-0000-0000-0000-000000001907', 'l_granter',   'Granter',   'human');
INSERT INTO mdm.user_role (user_id, role_code, granted_by, valid_period)
SELECT u::uuid, 'WORKFLOW_ADMIN', '00000000-0000-0000-0000-000000001907', daterange(current_date - 1, NULL)
FROM unnest(ARRAY['00000000-0000-0000-0000-000000001901', '00000000-0000-0000-0000-000000001902']) u;
INSERT INTO wf.user_group (group_id, group_code, name) VALUES
  ('00000000-0000-0000-0000-000000001911', 'L_APPROVERS', 'Approvers'), ('00000000-0000-0000-0000-000000001912', 'L_COMMITTERS', 'Committers');
INSERT INTO wf.user_group_member (group_id, user_id) VALUES
  ('00000000-0000-0000-0000-000000001911', '00000000-0000-0000-0000-000000001904'),
  ('00000000-0000-0000-0000-000000001912', '00000000-0000-0000-0000-000000001905');
INSERT INTO mdm.property_definition (property_id, property_code, label, data_type, scope) VALUES
  ('00000000-0000-0000-0000-000000001921', 'L.Note', 'Note', 'string', 'global'), ('00000000-0000-0000-0000-000000001922', 'L.Flag', 'Flag', 'string', 'global');
INSERT INTO mdm.version (version_id, version_name, business_as_of) VALUES ('00000000-0000-0000-0000-000000001931', 'L_V', current_date);
INSERT INTO mdm.node (node_id, node_kind) VALUES ('00000000-0000-0000-0000-000000001941', 'legal_entity');

-- Definition: Submit → Approve → Approve if L.Flag = "yes" → Commit
CREATE TEMP TABLE d (k text PRIMARY KEY, v jsonb);
INSERT INTO d VALUES ('model', $j${
  "code": "L_MODEL", "label": "Add with approval", "requestDuration": "5 days",
  "tasks": [{"code": "L_SUBMIT", "label": "Submit", "allowedActions": ["set_property"],
             "properties": [{"code": "L.Note"}]},
            {"code": "L_APPROVE", "label": "Approve", "allowedActions": []}],
  "submitTasks": ["L_SUBMIT"],
  "stages": [{"seq": 1, "type": "submit", "label": "Submit"},
             {"seq": 2, "type": "approve", "label": "Review", "task": "L_APPROVE", "groups": ["L_APPROVERS"], "stageDuration": "2 days"},
             {"seq": 3, "type": "approve", "label": "Flagged", "task": "L_APPROVE", "groups": ["L_APPROVERS"],
              "condition": {"type": "property", "property": "L.Flag", "op": "=", "value": "yes"}},
             {"seq": 4, "type": "commit", "label": "Commit", "groups": ["L_COMMITTERS"]}]}$j$),
  ('no_commit', '{"code": "L_BROKEN", "label": "No commit", "submitTasks": ["L_SUBMIT"],
                  "stages": [{"seq": 1, "type": "submit", "label": "Submit"}]}'),
  ('bad_group', '{"code": "L_BAD", "label": "Bad", "stages": [{"seq": 1, "type": "submit", "label": "S"},
                  {"seq": 2, "type": "commit", "label": "C", "groups": ["NO_SUCH_GROUP"]}]}');
CREATE TEMP TABLE ids (k text PRIMARY KEY, id uuid);
GRANT SELECT ON d TO nexus_api; GRANT ALL ON ids TO nexus_api, nexus_wf;

-- Loading and activation ------------------------------------------------------------------------------------------
SET LOCAL ROLE nexus_api;
SELECT throws_ok($$SELECT wf.load_model((SELECT v FROM d WHERE k = 'model'), '00000000-0000-0000-0000-000000001903')$$,
  'N1026', NULL, 'Only a workflow administrator loads models');
INSERT INTO ids SELECT 'v1', wf.load_model((SELECT v FROM d WHERE k = 'model'), '00000000-0000-0000-0000-000000001901');
SELECT throws_ok($$SELECT wf.load_model((SELECT v FROM d WHERE k = 'bad_group'), '00000000-0000-0000-0000-000000001901')$$,
  'N2235', NULL, 'A definition naming an unknown group is refused');
INSERT INTO ids SELECT 'broken', wf.load_model((SELECT v FROM d WHERE k = 'no_commit'), '00000000-0000-0000-0000-000000001901');
RESET ROLE;
SELECT is((SELECT status || '/' || model_version || '/' || (SELECT count(*) FROM wf.workflow_stage s WHERE s.model_id = m.model_id)
           FROM wf.workflow_model m WHERE m.model_id = (SELECT id FROM ids WHERE k = 'v1')),
  'draft/1/4', 'A loaded definition is a draft version with its stages');

SET LOCAL ROLE nexus_api;
SELECT throws_ok($$SELECT wf.activate_model((SELECT id FROM ids WHERE k = 'v1'), '00000000-0000-0000-0000-000000001901')$$,
  'N1014', NULL, 'The administrator who loaded a model cannot activate it');
SELECT throws_ok($$SELECT wf.activate_model((SELECT id FROM ids WHERE k = 'v1'), '00000000-0000-0000-0000-000000001903')$$,
  'N1026', NULL, 'Only a workflow administrator activates models');
SELECT throws_ok($$SELECT wf.activate_model((SELECT id FROM ids WHERE k = 'broken'), '00000000-0000-0000-0000-000000001902')$$,
  'N2206', NULL, 'An invalid model (no commit stage) cannot be activated');
SELECT lives_ok($$SELECT wf.activate_model((SELECT id FROM ids WHERE k = 'v1'), '00000000-0000-0000-0000-000000001902')$$,
  'A second administrator activates it');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM wf.config_audit WHERE table_name = 'workflow_model'
           AND actor_id = '00000000-0000-0000-0000-000000001902' AND new_row ->> 'status' = 'active'),
  1, 'The activation is in the configuration audit with the activating administrator');

-- Progression -------------------------------------------------------------------------------------------------------
INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind)
VALUES ('00000000-0000-0000-0000-000000001951', '00000000-0000-0000-0000-000000001931', 'L request', '00000000-0000-0000-0000-000000001903', 'human');
INSERT INTO mdm.change_item (change_request_id, seq, action, node_id, property_id, payload)
VALUES ('00000000-0000-0000-0000-000000001951', 1, 'set_property', '00000000-0000-0000-0000-000000001941', '00000000-0000-0000-0000-000000001921', '{"value": "n"}');
INSERT INTO ids SELECT 'i', wf.start_instance('00000000-0000-0000-0000-000000001951', 'L_MODEL', '00000000-0000-0000-0000-000000001903');
CREATE FUNCTION pg_temp.stage(p_seq int) RETURNS uuid LANGUAGE sql AS $$
  SELECT instance_stage_id FROM wf.instance_stage WHERE instance_id = (SELECT id FROM ids WHERE k = 'i') AND seq = p_seq
$$;

SET LOCAL ROLE nexus_wf;
SELECT is((SELECT action || '/' || stage_type || '/' || (due_at IS NOT NULL) FROM wf.advance_instance((SELECT id FROM ids WHERE k = 'i'))),
  'activated/approve/true', 'Advancing after submit activates the first approval stage with its due date');
SELECT is((SELECT action FROM wf.advance_instance((SELECT id FROM ids WHERE k = 'i'))), 'wait', 'While a stage is open, advancing waits');
SELECT throws_ok($$SELECT wf.complete_stage(pg_temp.stage(2))$$, 'N2234', NULL, 'A stage cannot be completed before it is approved');
RESET ROLE;

SET LOCAL ROLE nexus_api;
SELECT wf.record_stage_decision(pg_temp.stage(2), '00000000-0000-0000-0000-000000001904', 'approve', NULL);
RESET ROLE;
SET LOCAL ROLE nexus_wf;
SELECT is(wf.complete_stage(pg_temp.stage(2)) || '/' || wf.complete_stage(pg_temp.stage(2)), 'completed/completed',
  'An approved stage is completed; completing it again is harmless');
SELECT is((SELECT action FROM wf.advance_instance((SELECT id FROM ids WHERE k = 'i'))), 'evaluate_policy',
  'The conditional stage is skipped and the policy is evaluated before Commit');
RESET ROLE;
SELECT is((SELECT status::text FROM wf.instance_stage WHERE instance_stage_id = pg_temp.stage(3)), 'skipped',
  'A stage whose condition does not match is skipped');
SELECT is(wf.apply_commit_policy((SELECT id FROM ids WHERE k = 'i'), now(), '00000000-0000-0000-0000-000000001906')::text,
  'routed_to_human', 'Without a covering policy the request goes to a human');
SET LOCAL ROLE nexus_wf;
SELECT is((SELECT action || '/' || stage_type FROM wf.advance_instance((SELECT id FROM ids WHERE k = 'i'))), 'activated/commit',
  'After the evaluation the Commit stage is activated');
RESET ROLE;
SET LOCAL ROLE nexus_api;
SELECT wf.record_stage_decision(pg_temp.stage(4), '00000000-0000-0000-0000-000000001905', 'approve', NULL);
RESET ROLE;
SET LOCAL ROLE nexus_wf;
SELECT is(wf.complete_stage(pg_temp.stage(4)) || '/' || (SELECT action FROM wf.advance_instance((SELECT id FROM ids WHERE k = 'i'))),
  'completed/none', 'When Commit is complete there is nothing left to advance (close follows)');
RESET ROLE;

-- Closing as committed (the worker's step): the commit action is recorded before the status changes, so the bridge
-- finds the committer and the maker-checker guard accepts the approval (2-10a regression)
SET LOCAL ROLE nexus_wf;
SELECT lives_ok($$SELECT wf.close_instance((SELECT id FROM ids WHERE k = 'i'), 'committed', '00000000-0000-0000-0000-000000001905')$$,
  'The committer''s close records the commit and closes the instance');
RESET ROLE;
SELECT is((SELECT status::text || '/' || decided_by || '/' || decision_basis FROM mdm.change_request
           WHERE change_request_id = '00000000-0000-0000-0000-000000001951'),
  'approved/00000000-0000-0000-0000-000000001905/human_review', 'The request is approved with the committer as decider');

-- A new version leaves requests in flight on theirs ------------------------------------------------------------------
SET LOCAL ROLE nexus_api;
INSERT INTO ids SELECT 'v2', wf.load_model((SELECT v FROM d WHERE k = 'model'), '00000000-0000-0000-0000-000000001902');
SELECT wf.activate_model((SELECT id FROM ids WHERE k = 'v2'), '00000000-0000-0000-0000-000000001901');
RESET ROLE;
SELECT is((SELECT string_agg(model_version || ':' || status, ',' ORDER BY model_version) FROM wf.workflow_model WHERE model_code = 'L_MODEL'),
  '1:retired,2:active', 'Activating version 2 retires version 1');
SELECT is((SELECT model_id FROM wf.workflow_instance WHERE instance_id = (SELECT id FROM ids WHERE k = 'i')),
  (SELECT id FROM ids WHERE k = 'v1'), 'The request in flight keeps the version it started on');

SELECT * FROM finish();
ROLLBACK;
