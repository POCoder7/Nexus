-- pgTAP: claims (D-12), close rules (D-13), wf.record_stage_decision, separation of duties and human-only decisions
-- (Phase 2 increment 2-3). Calls go through the API's privileges. Synthetic data only.
BEGIN;
SELECT plan(24);

-- Fixture: model Submit → Approve (SoD) → Approve (SoD) → Commit -------------------------------------------------
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-000000001001', 's_steward',   'Steward',    'human'),
  ('00000000-0000-0000-0000-000000001002', 's_approver1', 'Approver 1', 'human'),
  ('00000000-0000-0000-0000-000000001003', 's_approver2', 'Approver 2', 'human'),
  ('00000000-0000-0000-0000-000000001004', 's_committer', 'Committer',  'human'),
  ('00000000-0000-0000-0000-000000001005', 's_ai',        'AI',         'ai_agent'),
  ('00000000-0000-0000-0000-000000001006', 's_outsider',  'Outsider',   'human');
INSERT INTO mdm.version (version_id, version_name, business_as_of)
VALUES ('00000000-0000-0000-0000-000000001101', 'S_VERSION', current_date);
INSERT INTO mdm.change_request (change_request_id, version_id, title, requester_id, requester_kind) VALUES
  ('00000000-0000-0000-0000-000000001201', '00000000-0000-0000-0000-000000001101', 'S one', '00000000-0000-0000-0000-000000001001', 'human'),
  ('00000000-0000-0000-0000-000000001202', '00000000-0000-0000-0000-000000001101', 'S two', '00000000-0000-0000-0000-000000001001', 'human');
INSERT INTO wf.user_group (group_id, group_code, name) VALUES
  ('00000000-0000-0000-0000-000000001301', 'S_APPROVERS', 'Approvers'),
  ('00000000-0000-0000-0000-000000001302', 'S_COMMITTERS', 'Committers');
INSERT INTO wf.user_group_member (group_id, user_id) VALUES
  ('00000000-0000-0000-0000-000000001301', '00000000-0000-0000-0000-000000001001'),   -- the requester is an approver too
  ('00000000-0000-0000-0000-000000001301', '00000000-0000-0000-0000-000000001002'),
  ('00000000-0000-0000-0000-000000001301', '00000000-0000-0000-0000-000000001003'),
  ('00000000-0000-0000-0000-000000001301', '00000000-0000-0000-0000-000000001005'),   -- an AI in the group still cannot decide
  ('00000000-0000-0000-0000-000000001302', '00000000-0000-0000-0000-000000001004');
INSERT INTO wf.workflow_task (task_id, task_code, label, allowed_actions)
VALUES ('00000000-0000-0000-0000-000000001401', 'S_TASK', 'Task', '{add_node}');
INSERT INTO wf.workflow_model (model_id, model_code, label) VALUES ('00000000-0000-0000-0000-000000001501', 'S_MODEL', 'Model');
INSERT INTO wf.workflow_stage (stage_id, model_id, seq, stage_type, label, task_id, separation_of_duties) VALUES
  ('00000000-0000-0000-0000-000000001601', '00000000-0000-0000-0000-000000001501', 1, 'submit',  'Submit',   NULL, false),
  ('00000000-0000-0000-0000-000000001602', '00000000-0000-0000-0000-000000001501', 2, 'approve', 'Review',   '00000000-0000-0000-0000-000000001401', true),
  ('00000000-0000-0000-0000-000000001603', '00000000-0000-0000-0000-000000001501', 3, 'approve', 'Sign-off', '00000000-0000-0000-0000-000000001401', true),
  ('00000000-0000-0000-0000-000000001604', '00000000-0000-0000-0000-000000001501', 4, 'commit',  'Commit',   NULL, false);
INSERT INTO wf.submit_task VALUES ('00000000-0000-0000-0000-000000001501', '00000000-0000-0000-0000-000000001401');
INSERT INTO wf.stage_group (stage_id, group_id) VALUES
  ('00000000-0000-0000-0000-000000001602', '00000000-0000-0000-0000-000000001301'),
  ('00000000-0000-0000-0000-000000001603', '00000000-0000-0000-0000-000000001301'),
  ('00000000-0000-0000-0000-000000001604', '00000000-0000-0000-0000-000000001302');
UPDATE wf.workflow_model SET status = 'active' WHERE model_id = '00000000-0000-0000-0000-000000001501';

CREATE TEMP TABLE t (k text PRIMARY KEY, id uuid);
INSERT INTO t VALUES ('i1', wf.start_instance('00000000-0000-0000-0000-000000001201', 'S_MODEL', '00000000-0000-0000-0000-000000001001')),
                     ('i2', wf.start_instance('00000000-0000-0000-0000-000000001202', 'S_MODEL', '00000000-0000-0000-0000-000000001001'));
INSERT INTO t SELECT 'st' || ist.seq, ist.instance_stage_id FROM wf.instance_stage ist WHERE ist.instance_id = (SELECT id FROM t WHERE k = 'i1');
GRANT SELECT ON t TO nexus_api;
-- the engine's step (2-7) is simulated: the first approval stage becomes active
CREATE FUNCTION pg_temp.activate(p_seq int) RETURNS void LANGUAGE sql AS $$
  UPDATE wf.instance_stage SET status = 'completed', completed_at = now()
  WHERE instance_id = (SELECT id FROM t WHERE k = 'i1') AND seq = p_seq - 1 AND status IN ('active', 'claimed');
  UPDATE wf.instance_stage SET status = 'active', started_at = now() WHERE instance_stage_id = (SELECT id FROM t WHERE k = 'st' || p_seq);
  UPDATE wf.workflow_instance SET current_seq = p_seq WHERE instance_id = (SELECT id FROM t WHERE k = 'i1');
$$;
SELECT pg_temp.activate(2);

SET LOCAL ROLE nexus_api;
-- Claims (D-12) -------------------------------------------------------------------------------------------------
SELECT throws_ok($$SELECT wf.claim_stage((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-000000001005')$$,
  'N1010', NULL, 'An AI cannot claim a stage');
SELECT throws_ok($$SELECT wf.claim_stage((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-000000001006')$$,
  'N1010', NULL, 'Someone outside the stage''s groups cannot claim it');
SELECT throws_ok($$SELECT wf.claim_stage((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-000000001001')$$,
  'N1010', NULL, 'The requester cannot claim the approval of their own request');
SELECT lives_ok($$SELECT wf.claim_stage((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-000000001002')$$,
  'An approver can claim the stage');
SELECT throws_ok($$SELECT wf.claim_stage((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-000000001003')$$,
  'N1010', NULL, 'A claimed stage cannot be taken over');
SELECT throws_ok($$SELECT wf.record_stage_decision((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-000000001003', 'approve', NULL)$$,
  'N1016', NULL, 'Nobody else can decide a stage while it is claimed');
SELECT throws_ok($$SELECT wf.unclaim_stage((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-000000001003')$$,
  'N1010', NULL, 'Only the claimant or a workflow administrator releases a claim');

-- Decisions -------------------------------------------------------------------------------------------------------
SELECT throws_ok($$SELECT wf.record_stage_decision((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-000000001005', 'approve', NULL)$$,
  'N1002', NULL, 'An AI cannot decide a stage');
SELECT throws_ok($$SELECT wf.record_stage_decision((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-000000001002', 'maybe', NULL)$$,
  '22023', NULL, 'A decision is approve or reject');
SELECT is(wf.record_stage_decision((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-000000001002', 'approve', 'fine'),
  'approved', 'The claimant approves; the stage outcome is returned');
SELECT is(wf.record_stage_decision((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-000000001002', 'approve', 'again'),
  'approved', 'Repeating the same decision is harmless');
SELECT throws_ok($$SELECT wf.record_stage_decision((SELECT id FROM t WHERE k = 'st2'), '00000000-0000-0000-0000-000000001002', 'reject', NULL)$$,
  'N2201', NULL, 'A different decision on the same stage is refused');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM wf.stage_group_decision WHERE instance_stage_id = (SELECT id FROM t WHERE k = 'st2')),
  1, 'One decision is stored');
SELECT is((SELECT payload ->> 'outcome' FROM wf.event_outbox WHERE event_type = 'stage_decision_recorded'
           AND payload ->> 'instance_stage_id' = (SELECT id FROM t WHERE k = 'st2')::text ORDER BY event_id DESC LIMIT 1),
  'approved', 'Each decision puts an event in the outbox for the engine');

-- Separation of duties on the next approval stage ----------------------------------------------------------------
SELECT pg_temp.activate(3);
SET LOCAL ROLE nexus_api;
SELECT throws_ok($$SELECT wf.record_stage_decision((SELECT id FROM t WHERE k = 'st3'), '00000000-0000-0000-0000-000000001002', 'approve', NULL)$$,
  'N1016', NULL, 'Separation of duties: the approver of the review cannot sign off');
SELECT throws_ok($$SELECT wf.record_stage_decision((SELECT id FROM t WHERE k = 'st3'), '00000000-0000-0000-0000-000000001001', 'approve', NULL)$$,
  'N1016', NULL, 'The requester cannot approve their own request');
SELECT is(wf.record_stage_decision((SELECT id FROM t WHERE k = 'st3'), '00000000-0000-0000-0000-000000001003', 'approve', NULL),
  'approved', 'A second approver signs off');
RESET ROLE;

-- Reject (D-13) on the Commit stage --------------------------------------------------------------------------------
SELECT pg_temp.activate(4);
SET LOCAL ROLE nexus_api;
SELECT throws_ok($$SELECT wf.close_instance((SELECT id FROM t WHERE k = 'i1'), 'rejected', '00000000-0000-0000-0000-000000001004')$$,
  'N1011', NULL, 'A request cannot be closed as rejected without a rejecting decision');
SELECT is(wf.record_stage_decision((SELECT id FROM t WHERE k = 'st4'), '00000000-0000-0000-0000-000000001004', 'reject', 'wrong parent'),
  'rejected', 'The committer rejects');
SELECT throws_ok($$SELECT wf.close_instance((SELECT id FROM t WHERE k = 'i1'), 'rejected', '00000000-0000-0000-0000-000000001003')$$,
  'N1011', NULL, 'Only the person who rejected can close it as rejected');
SELECT lives_ok($$SELECT wf.close_instance((SELECT id FROM t WHERE k = 'i1'), 'rejected', '00000000-0000-0000-0000-000000001004', 'wrong parent')$$,
  'The rejecter closes the request');

-- Withdraw (D-13) --------------------------------------------------------------------------------------------------
SELECT throws_ok($$SELECT wf.close_instance((SELECT id FROM t WHERE k = 'i2'), 'withdrawn', '00000000-0000-0000-0000-000000001005')$$,
  'N1012', NULL, 'An AI cannot withdraw someone''s request');
SELECT lives_ok($$SELECT wf.close_instance((SELECT id FROM t WHERE k = 'i2'), 'withdrawn', '00000000-0000-0000-0000-000000001001')$$,
  'The requester withdraws');
RESET ROLE;

SELECT is((SELECT string_agg(cr.status::text || '/' || coalesce(cr.decided_by::text, '-'), ',' ORDER BY cr.title)
           FROM mdm.change_request cr WHERE cr.title IN ('S one', 'S two')),
  'rejected/00000000-0000-0000-0000-000000001004,withdrawn/-', 'The bridge carries both outcomes to the change requests, with the rejecter as decider');

SELECT * FROM finish();
ROLLBACK;
