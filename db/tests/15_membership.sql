-- pgTAP: bitemporal group membership (D-33), one membership test (D-15), governed membership changes (CR-10) and
-- the configuration audit (Phase 2 increment 2-2). Synthetic data only.
BEGIN;
SELECT plan(21);

INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-000000000fa1', 'm_admin1',  'Admin one',  'human'),
  ('00000000-0000-0000-0000-000000000fa2', 'm_admin2',  'Admin two',  'human'),
  ('00000000-0000-0000-0000-000000000fa3', 'm_user',    'User',       'human'),
  ('00000000-0000-0000-0000-000000000fa4', 'm_past',    'Past',       'human'),
  ('00000000-0000-0000-0000-000000000fa5', 'm_future',  'Future',     'human'),
  ('00000000-0000-0000-0000-000000000fa6', 'm_granter', 'Granter',    'human'),
  ('00000000-0000-0000-0000-000000000fa7', 'm_admin3',  'Admin three','human');
INSERT INTO mdm.user_role (user_id, role_code, granted_by, valid_period)
SELECT u::uuid, 'WORKFLOW_ADMIN', '00000000-0000-0000-0000-000000000fa6', daterange(current_date - 10, NULL)
FROM unnest(ARRAY['00000000-0000-0000-0000-000000000fa1', '00000000-0000-0000-0000-000000000fa2',
                  '00000000-0000-0000-0000-000000000fa7']) AS u;
INSERT INTO wf.user_group (group_id, group_code, name) VALUES ('00000000-0000-0000-0000-000000000fe1', 'M_APPROVERS', 'Approvers');
-- bootstrap rows by the owner: one past membership, one future one, admin2 in POLICY_APPROVERS
INSERT INTO wf.user_group_member (group_id, user_id, valid_period) VALUES
  ('00000000-0000-0000-0000-000000000fe1', '00000000-0000-0000-0000-000000000fa4', daterange('2020-01-01', '2025-01-01'));
INSERT INTO wf.user_group_member (group_id, user_id, valid_period)
SELECT group_id, '00000000-0000-0000-0000-000000000fa5', daterange(mdm.business_today() + 10, NULL)
FROM wf.user_group WHERE group_code = 'POLICY_APPROVERS';
INSERT INTO wf.user_group_member (group_id, user_id)
SELECT group_id, '00000000-0000-0000-0000-000000000fa2' FROM wf.user_group WHERE group_code = 'POLICY_APPROVERS';

-- History and the one membership test -----------------------------------------------------------------------------
SELECT ok(wf.is_member('00000000-0000-0000-0000-000000000fe1', '00000000-0000-0000-0000-000000000fa4', '2024-06-01'),
  'A past membership is reconstructable at a past date');
SELECT ok(NOT wf.is_member('00000000-0000-0000-0000-000000000fe1', '00000000-0000-0000-0000-000000000fa4', mdm.business_today()),
  '… and is not a membership today');
SELECT throws_ok($$UPDATE wf.user_group_member SET granted_by = '00000000-0000-0000-0000-000000000fa6'
                   WHERE user_id = '00000000-0000-0000-0000-000000000fa4'$$, 'N2010', NULL, 'Memberships are never edited');
SELECT throws_ok($$DELETE FROM wf.user_group_member WHERE user_id = '00000000-0000-0000-0000-000000000fa4'$$,
  'N2010', NULL, 'Memberships are never deleted');

-- D-15: a future member of POLICY_APPROVERS cannot engage a kill switch today
INSERT INTO wf.commit_policy (policy_id, policy_code, description, rationale, allowed_actions, owner_group_id, proposed_by)
VALUES ('00000000-0000-0000-0000-000000000fb1', 'M_POLICY', 'Adds', 'Test', '{add_node}',
        '00000000-0000-0000-0000-000000000fe1', '00000000-0000-0000-0000-000000000fa1');
SELECT wf.submit_commit_policy('00000000-0000-0000-0000-000000000fb1', '00000000-0000-0000-0000-000000000fa1');
SELECT wf.approve_commit_policy('00000000-0000-0000-0000-000000000fb1', '00000000-0000-0000-0000-000000000fa2', 'ok');
SELECT throws_ok($$SELECT wf.engage_kill_switch('M_POLICY', '00000000-0000-0000-0000-000000000fa5', 'too early')$$,
  'N1023', NULL, 'A member whose membership starts later cannot engage the kill switch (D-15)');

-- Direct writes are refused to application roles -------------------------------------------------------------------
SET LOCAL ROLE nexus_wf;
SELECT throws_ok($$INSERT INTO wf.user_group_member (group_id, user_id)
                   VALUES ('00000000-0000-0000-0000-000000000fe1', '00000000-0000-0000-0000-000000000fa3')$$,
  '42501', NULL, 'The workflow role cannot add members directly');
SELECT throws_ok($$INSERT INTO wf.config_audit (table_name, action) VALUES ('x', 'INSERT')$$,
  '42501', NULL, 'The workflow role cannot write audit rows');
RESET ROLE;

-- Governed changes, through the API's privileges ------------------------------------------------------------------
CREATE TEMP TABLE ids (k text PRIMARY KEY, id uuid);
GRANT ALL ON ids TO nexus_api;
SET LOCAL ROLE nexus_api;
SELECT throws_ok($$SELECT wf.propose_membership_change('00000000-0000-0000-0000-000000000fe1', '00000000-0000-0000-0000-000000000fa3',
                   'add', mdm.business_today(), 'needs it', '00000000-0000-0000-0000-000000000fa3')$$,
  'N1026', NULL, 'Only a workflow administrator proposes');
SELECT throws_ok($$SELECT wf.propose_membership_change('00000000-0000-0000-0000-000000000fe1', '00000000-0000-0000-0000-000000000fa3',
                   'add', mdm.business_today() - 1, 'yesterday', '00000000-0000-0000-0000-000000000fa1')$$,
  'N2233', NULL, 'A membership cannot start in the past');
INSERT INTO ids SELECT 'add', wf.propose_membership_change('00000000-0000-0000-0000-000000000fe1',
  '00000000-0000-0000-0000-000000000fa3', 'add', mdm.business_today(), 'new approver', '00000000-0000-0000-0000-000000000fa1');
SELECT ok(NOT wf.is_member('00000000-0000-0000-0000-000000000fe1', '00000000-0000-0000-0000-000000000fa3', mdm.business_today()),
  'A proposed membership has no effect until approved');
SELECT throws_ok($$SELECT wf.decide_membership_change((SELECT id FROM ids WHERE k = 'add'), '00000000-0000-0000-0000-000000000fa1', true)$$,
  'N1001', NULL, 'The proposer cannot approve their own change');
SELECT throws_ok($$SELECT wf.decide_membership_change((SELECT id FROM ids WHERE k = 'add'), '00000000-0000-0000-0000-000000000fa3', true)$$,
  'N1026', NULL, 'Only a workflow administrator approves');
SELECT lives_ok($$SELECT wf.decide_membership_change((SELECT id FROM ids WHERE k = 'add'), '00000000-0000-0000-0000-000000000fa2', true)$$,
  'A second administrator approves');
SELECT throws_ok($$SELECT wf.decide_membership_change((SELECT id FROM ids WHERE k = 'add'), '00000000-0000-0000-0000-000000000fa7', false)$$,
  'N2230', NULL, 'A decided change cannot be decided again');

INSERT INTO ids SELECT 'pa', wf.propose_membership_change((SELECT group_id FROM wf.user_group WHERE group_code = 'POLICY_APPROVERS'),
  '00000000-0000-0000-0000-000000000fa3', 'add', mdm.business_today(), 'policy approver', '00000000-0000-0000-0000-000000000fa1');
SELECT throws_ok($$SELECT wf.decide_membership_change((SELECT id FROM ids WHERE k = 'pa'), '00000000-0000-0000-0000-000000000fa7', true)$$,
  'N1020', NULL, 'A change to POLICY_APPROVERS needs an approver who is in it');

INSERT INTO ids SELECT 'end', wf.propose_membership_change('00000000-0000-0000-0000-000000000fe1',
  '00000000-0000-0000-0000-000000000fa3', 'end', mdm.business_today() + 30, 'leaves', '00000000-0000-0000-0000-000000000fa7');
SELECT lives_ok($$SELECT wf.decide_membership_change((SELECT id FROM ids WHERE k = 'end'), '00000000-0000-0000-0000-000000000fa2', true)$$,
  'Ending a membership is governed the same way');
RESET ROLE;

SELECT ok(wf.is_member('00000000-0000-0000-0000-000000000fe1', '00000000-0000-0000-0000-000000000fa3', mdm.business_today() + 29)
          AND NOT wf.is_member('00000000-0000-0000-0000-000000000fe1', '00000000-0000-0000-0000-000000000fa3', mdm.business_today() + 30),
  'The membership holds until the end date and not after');
SELECT is((SELECT count(*)::int FROM wf.user_group_member
           WHERE user_id = '00000000-0000-0000-0000-000000000fa3' AND NOT upper_inf(recorded_period)),
  1, 'The open-ended belief is kept as a closed row, not changed');
SELECT is((SELECT count(*)::int FROM wf.config_audit
           WHERE table_name = 'user_group_member' AND actor_id = '00000000-0000-0000-0000-000000000fa2'
             AND new_row ->> 'user_id' = '00000000-0000-0000-0000-000000000fa3'),
  3, 'Every membership row written is audited with the approver (add; close and re-state on end)');
SELECT throws_ok($$UPDATE wf.config_audit SET actor_id = NULL$$, 'N2011', NULL, 'The configuration audit is append-only');
SELECT throws_ok($$UPDATE wf.membership_change SET reason = 'changed' WHERE change_id = (SELECT id FROM ids WHERE k = 'add')$$,
  'N2230', NULL, 'A membership change cannot be edited');

SELECT * FROM finish();
ROLLBACK;
