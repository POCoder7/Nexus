-- pgTAP: workflow override (ADR-042 D4; Phase 5 LLD §19.5, increment 5-4c). An ADMIN decides an open stage in place of
-- its groups, with a reason; it passes over membership, claims and group order and nothing else. Synthetic data only.
BEGIN;
SELECT plan(17);

-- Fixture: Submit → Approve (SoD) → Approve (SoD) → Commit, one request touching hierarchy O_H1 ------------------
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-0000000029a1', 'o_requester', 'Requester (an ADMIN too)', 'human'),
  ('00000000-0000-0000-0000-0000000029a2', 'o_admin1',    'Admin one',               'human'),
  ('00000000-0000-0000-0000-0000000029a3', 'o_admin2',    'Admin two',               'human'),
  ('00000000-0000-0000-0000-0000000029a4', 'o_scoped',    'Admin of O_H2 only',      'human'),
  ('00000000-0000-0000-0000-0000000029a5', 'o_approver',  'Approver',                'human'),
  ('00000000-0000-0000-0000-0000000029a6', 'o_owner',     'Bootstrap',               'human'),
  ('00000000-0000-0000-0000-0000000029a7', 'o_ai',        'AI',                      'ai_agent');
INSERT INTO mdm.node (node_id, node_kind) VALUES
  ('00000000-0000-0000-0000-0000000029c1', 'structural'), ('00000000-0000-0000-0000-0000000029c2', 'structural');
INSERT INTO mdm.node_attr (node_id, node_name) VALUES
  ('00000000-0000-0000-0000-0000000029c1', 'O top'), ('00000000-0000-0000-0000-0000000029c2', 'O other top');
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id) VALUES
  ('00000000-0000-0000-0000-0000000029d1', 'O_H1', 'Override one', '00000000-0000-0000-0000-0000000029c1'),
  ('00000000-0000-0000-0000-0000000029d2', 'O_H2', 'Override two', '00000000-0000-0000-0000-0000000029c2');
INSERT INTO mdm.user_role (user_id, role_code, hierarchy_id, granted_by, valid_period) VALUES
  ('00000000-0000-0000-0000-0000000029a1', 'ADMIN', NULL, '00000000-0000-0000-0000-0000000029a6', daterange(current_date - 10, NULL)),
  ('00000000-0000-0000-0000-0000000029a2', 'ADMIN', NULL, '00000000-0000-0000-0000-0000000029a6', daterange(current_date - 10, NULL)),
  ('00000000-0000-0000-0000-0000000029a3', 'ADMIN', NULL, '00000000-0000-0000-0000-0000000029a6', daterange(current_date - 10, NULL)),
  ('00000000-0000-0000-0000-0000000029a4', 'ADMIN', '00000000-0000-0000-0000-0000000029d2', '00000000-0000-0000-0000-0000000029a6', daterange(current_date - 10, NULL)),
  ('00000000-0000-0000-0000-0000000029a5', 'APPROVER', NULL, '00000000-0000-0000-0000-0000000029a6', daterange(current_date - 10, NULL));
INSERT INTO mdm.version (version_id, version_name, business_as_of)
VALUES ('00000000-0000-0000-0000-0000000029b1', 'O_VERSION', current_date);
INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind)
VALUES ('00000000-0000-0000-0000-0000000029e1', '00000000-0000-0000-0000-0000000029b1', 'O one', '00000000-0000-0000-0000-0000000029a1', 'human');
INSERT INTO mdm.change_item (change_request_id, seq, action, hierarchy_id, node_id, payload)
VALUES ('00000000-0000-0000-0000-0000000029e1', 1, 'update_node', '00000000-0000-0000-0000-0000000029d1',
        '00000000-0000-0000-0000-0000000029c1', '{"name": "O renamed"}');
INSERT INTO mdm.user_group (group_id, group_code, name) VALUES
  ('00000000-0000-0000-0000-0000000029f1', 'O_APPROVERS', 'Approvers'), ('00000000-0000-0000-0000-0000000029f2', 'O_COMMITTERS', 'Committers');
INSERT INTO wf.workflow_task (task_id, task_code, label, allowed_actions)
VALUES ('00000000-0000-0000-0000-000000002901', 'O_TASK', 'Task', '{update_node}');
INSERT INTO wf.workflow_model (model_id, model_code, label) VALUES ('00000000-0000-0000-0000-000000002902', 'O_MODEL', 'Model');
INSERT INTO wf.workflow_stage (stage_id, model_id, seq, stage_type, label, task_id, separation_of_duties) VALUES
  ('00000000-0000-0000-0000-000000002911', '00000000-0000-0000-0000-000000002902', 1, 'submit',  'Submit',   NULL, false),
  ('00000000-0000-0000-0000-000000002912', '00000000-0000-0000-0000-000000002902', 2, 'approve', 'Review',   '00000000-0000-0000-0000-000000002901', true),
  ('00000000-0000-0000-0000-000000002913', '00000000-0000-0000-0000-000000002902', 3, 'approve', 'Sign-off', '00000000-0000-0000-0000-000000002901', true),
  ('00000000-0000-0000-0000-000000002914', '00000000-0000-0000-0000-000000002902', 4, 'commit',  'Commit',   NULL, false);
INSERT INTO wf.submit_task VALUES ('00000000-0000-0000-0000-000000002902', '00000000-0000-0000-0000-000000002901');
INSERT INTO wf.stage_group (stage_id, group_id) VALUES
  ('00000000-0000-0000-0000-000000002912', '00000000-0000-0000-0000-0000000029f1'),
  ('00000000-0000-0000-0000-000000002913', '00000000-0000-0000-0000-0000000029f1'),
  ('00000000-0000-0000-0000-000000002914', '00000000-0000-0000-0000-0000000029f2');
UPDATE wf.workflow_model SET status = 'active', activated_by = '00000000-0000-0000-0000-0000000029a6'
WHERE model_id = '00000000-0000-0000-0000-000000002902';

CREATE TEMP TABLE t (k text PRIMARY KEY, id uuid);
INSERT INTO t VALUES ('i1', wf.start_instance('00000000-0000-0000-0000-0000000029e1', 'O_MODEL', '00000000-0000-0000-0000-0000000029a1'));
INSERT INTO t SELECT 'st' || ist.seq, ist.instance_stage_id FROM wf.instance_stage ist WHERE ist.instance_id = (SELECT id FROM t WHERE k = 'i1');
GRANT SELECT ON t TO nexus_api;
-- the engine's step is simulated, as in 16: complete the previous stage and open this one
CREATE FUNCTION pg_temp.activate(p_seq int) RETURNS void LANGUAGE sql AS $$
  UPDATE wf.instance_stage SET status = 'completed', completed_at = now()
  WHERE instance_id = (SELECT id FROM t WHERE k = 'i1') AND seq = p_seq - 1 AND status IN ('active', 'claimed');
  UPDATE wf.instance_stage SET status = 'active', started_at = now() WHERE instance_stage_id = (SELECT id FROM t WHERE k = 'st' || p_seq);
  UPDATE wf.workflow_instance SET current_seq = p_seq WHERE instance_id = (SELECT id FROM t WHERE k = 'i1');
$$;
SELECT pg_temp.activate(2);

SET LOCAL ROLE nexus_api;
-- Refusals ---------------------------------------------------------------------------------------------------------
SELECT throws_ok($$SELECT wf.override_stage((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-0000000029a2', 'approve', 'too short')$$,
  'N1031', NULL, 'An override needs a reason of at least 10 characters');
SELECT throws_ok($$SELECT wf.override_stage((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-0000000029a5', 'approve', 'Approver on leave, urgent fix')$$,
  'N1031', NULL, 'An APPROVER who is not an ADMIN cannot override');
SELECT throws_ok($$SELECT wf.override_stage((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-0000000029a4', 'approve', 'Approver on leave, urgent fix')$$,
  'N1031', NULL, 'An ADMIN of another hierarchy cannot override');
SELECT throws_ok($$SELECT wf.override_stage((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-0000000029a1', 'approve', 'Approver on leave, urgent fix')$$,
  'N1031', NULL, 'An ADMIN cannot override a stage of their own request');
SELECT throws_ok($$SELECT wf.override_stage((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-0000000029a7', 'approve', 'Approver on leave, urgent fix')$$,
  'N1031', NULL, 'An AI agent cannot override');
SELECT throws_ok($$SELECT wf.override_stage((SELECT id FROM t WHERE k = 'st1'), '00000000-0000-0000-0000-0000000029a2', 'approve', 'Approver on leave, urgent fix')$$,
  'N1031', NULL, 'A stage that is not open (the submit stage) cannot be overridden');
SELECT throws_ok($$SELECT wf.override_stage((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-0000000029a2', 'push_back', 'Approver on leave, urgent fix')$$,
  '22023', NULL, 'An override is approve or reject');

-- An override, by an ADMIN who is in none of the stage's groups ----------------------------------------------------
SELECT is(wf.override_stage((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-0000000029a2', 'approve', '  Approvers away; quarter-end deadline  '),
  'approved', 'An ADMIN overrides an open stage in place of its group');
RESET ROLE;
SELECT results_eq($$SELECT decided_by, decision, override, comment FROM wf.stage_group_decision WHERE instance_stage_id = (SELECT id FROM t WHERE k = 'st2')$$,
  $$VALUES ('00000000-0000-0000-0000-0000000029a2'::uuid, 'approve'::text, true, 'Approvers away; quarter-end deadline'::text)$$,
  'One decision row per undecided group, marked as an override, with the reason');
SELECT results_eq($$SELECT actor_id, action::text, comment, payload ->> 'decision' FROM wf.instance_action
                    WHERE instance_stage_id = (SELECT id FROM t WHERE k = 'st2') AND action = 'override'$$,
  $$VALUES ('00000000-0000-0000-0000-0000000029a2'::uuid, 'override'::text, 'Approvers away; quarter-end deadline'::text, 'approve'::text)$$,
  'The history records the override and its reason');
SELECT ok(EXISTS (SELECT 1 FROM wf.event_outbox WHERE event_type = 'stage_decision_recorded' AND (payload ->> 'override')::boolean
                  AND payload ->> 'instance_stage_id' = (SELECT id FROM t WHERE k = 'st2')::text),
  'The worker is told, as for any decision');
SET LOCAL ROLE nexus_api;
SELECT throws_ok($$SELECT wf.override_stage((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-0000000029a3', 'approve', 'Second attempt at the same stage')$$,
  'N1031', NULL, 'A stage every group has decided cannot be overridden again');
RESET ROLE;

-- Separation of duties still binds the ADMIN; a different ADMIN may override the next stage --------------------------
SELECT pg_temp.activate(3);
SET LOCAL ROLE nexus_api;
SELECT throws_ok($$SELECT wf.override_stage((SELECT id FROM t WHERE k = 'st3'), '00000000-0000-0000-0000-0000000029a2', 'approve', 'Sign-off overdue, same admin')$$,
  'N1031', NULL, 'The ADMIN who approved the Review cannot override the Sign-off (separation of duties)');
SELECT is(wf.override_stage((SELECT id FROM t WHERE k = 'st3'), '00000000-0000-0000-0000-0000000029a3', 'reject', 'Duplicate of an earlier request'),
  'rejected', 'A second ADMIN can reject by override');
RESET ROLE;

-- Only override_stage may write an override row; ordinary rows keep their checks ------------------------------------
SELECT pg_temp.activate(4);
SELECT throws_ok($$INSERT INTO wf.stage_group_decision (instance_stage_id, group_id, decided_by, decision, override)
                   VALUES ((SELECT id FROM t WHERE k = 'st4'), '00000000-0000-0000-0000-0000000029f2', '00000000-0000-0000-0000-0000000029a3', 'approve', true)$$,
  'N1031', NULL, 'A row marked as an override, written any other way, is refused');
SELECT throws_ok($$INSERT INTO wf.stage_group_decision (instance_stage_id, group_id, decided_by, decision)
                   VALUES ((SELECT id FROM t WHERE k = 'st4'), '00000000-0000-0000-0000-0000000029f2', '00000000-0000-0000-0000-0000000029a3', 'approve')$$,
  'N1015', NULL, 'An ordinary decision still needs a member of the group');
SELECT ok(NOT has_function_privilege('nexus_wf', 'wf.override_stage(uuid, uuid, text, text)', 'EXECUTE')
          OR pg_get_userbyid((SELECT proowner FROM pg_proc WHERE proname = 'override_stage')) = 'nexus_wf',
  'override_stage runs as nexus_wf and is granted to the API only');

SELECT * FROM finish();
ROLLBACK;
