-- pgTAP: group membership (Phase 2 D-15; groups in mdm since ADR-042, Phase 5 increment 5-4a).
-- Memberships are bitemporal facts in mdm.user_group_member: never edited or deleted, reconstructable at any past date,
-- and written by no application role directly. Governed membership changes (propose, decide by a second ADMIN) are
-- change actions since ADR-042 D3 and are tested with them (5-4b).
BEGIN;
SELECT plan(11);

INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-000000000fa1', 'm_admin1',  'Admin one',  'human'),
  ('00000000-0000-0000-0000-000000000fa2', 'm_admin2',  'Admin two',  'human'),
  ('00000000-0000-0000-0000-000000000fa3', 'm_user',    'User',       'human'),
  ('00000000-0000-0000-0000-000000000fa4', 'm_past',    'Past',       'human'),
  ('00000000-0000-0000-0000-000000000fa5', 'm_future',  'Future',     'human'),
  ('00000000-0000-0000-0000-000000000fa6', 'm_granter', 'Granter',    'human');
INSERT INTO mdm.user_role (user_id, role_code, granted_by, valid_period)
SELECT u::uuid, 'ADMIN', '00000000-0000-0000-0000-000000000fa6', daterange(current_date - 10, NULL)
FROM unnest(ARRAY['00000000-0000-0000-0000-000000000fa1', '00000000-0000-0000-0000-000000000fa2']) AS u;
INSERT INTO mdm.user_group (group_id, group_code, name) VALUES ('00000000-0000-0000-0000-000000000fe1', 'M_APPROVERS', 'Approvers');
-- bootstrap rows by the owner: one past membership, one future one, admin2 in POLICY_APPROVERS
INSERT INTO mdm.user_group_member (group_id, user_id, valid_period) VALUES
  ('00000000-0000-0000-0000-000000000fe1', '00000000-0000-0000-0000-000000000fa4', daterange('2020-01-01', '2025-01-01'));
INSERT INTO mdm.user_group_member (group_id, user_id, valid_period)
SELECT group_id, '00000000-0000-0000-0000-000000000fa5', daterange(mdm.business_today() + 10, NULL)
FROM mdm.user_group WHERE group_code = 'POLICY_APPROVERS';
INSERT INTO mdm.user_group_member (group_id, user_id)
SELECT group_id, '00000000-0000-0000-0000-000000000fa2' FROM mdm.user_group WHERE group_code = 'POLICY_APPROVERS';

-- History -------------------------------------------------------------------------------------------------------------
SELECT ok(mdm.is_member('00000000-0000-0000-0000-000000000fe1', '00000000-0000-0000-0000-000000000fa4', '2024-06-01'),
  'A past membership is reconstructable at a past date');
SELECT ok(NOT mdm.is_member('00000000-0000-0000-0000-000000000fe1', '00000000-0000-0000-0000-000000000fa4', mdm.business_today()),
  '… and is not a membership today');
SELECT ok(wf.is_member('00000000-0000-0000-0000-000000000fe1', '00000000-0000-0000-0000-000000000fa4', '2024-06-01'),
  'The workflow layer reads the same membership (wf.is_member reads mdm)');
SELECT throws_ok($$UPDATE mdm.user_group_member SET granted_by = '00000000-0000-0000-0000-000000000fa6'
                   WHERE user_id = '00000000-0000-0000-0000-000000000fa4'$$, 'N2010', NULL, 'Memberships are never edited');
SELECT throws_ok($$DELETE FROM mdm.user_group_member WHERE user_id = '00000000-0000-0000-0000-000000000fa4'$$,
  'N2010', NULL, 'Memberships are never deleted');
SELECT throws_ok($$INSERT INTO mdm.user_group_member (group_id, user_id, granted_by)
                   VALUES ('00000000-0000-0000-0000-000000000fe1', '00000000-0000-0000-0000-000000000fa3',
                           '00000000-0000-0000-0000-000000000fa3')$$,
  '23514', NULL, 'Nobody adds themselves to a group');

-- D-15: a future member of POLICY_APPROVERS cannot engage a kill switch today
INSERT INTO wf.commit_policy (policy_id, policy_code, description, rationale, allowed_actions, owner_group_id, proposed_by)
VALUES ('00000000-0000-0000-0000-000000000fb1', 'M_POLICY', 'Adds', 'Test', '{add_node}',
        '00000000-0000-0000-0000-000000000fe1', '00000000-0000-0000-0000-000000000fa1');
SELECT wf.submit_commit_policy('00000000-0000-0000-0000-000000000fb1', '00000000-0000-0000-0000-000000000fa1');
SELECT wf.approve_commit_policy('00000000-0000-0000-0000-000000000fb1', '00000000-0000-0000-0000-000000000fa2', 'ok');
SELECT throws_ok($$SELECT wf.engage_kill_switch('M_POLICY', '00000000-0000-0000-0000-000000000fa5', 'too early')$$,
  'N1023', NULL, 'A member whose membership starts later cannot engage the kill switch (D-15)');

-- Direct writes are refused to application roles (layer rule: wf never writes mdm; the API writes groups only
-- through governed change requests, 5-4b) ---------------------------------------------------------------------------
SET LOCAL ROLE nexus_wf;
SELECT throws_ok($$INSERT INTO mdm.user_group_member (group_id, user_id)
                   VALUES ('00000000-0000-0000-0000-000000000fe1', '00000000-0000-0000-0000-000000000fa3')$$,
  '42501', NULL, 'The workflow role cannot add members');
SELECT throws_ok($$INSERT INTO wf.config_audit (table_name, action) VALUES ('x', 'INSERT')$$,
  '42501', NULL, 'The workflow role cannot write audit rows');
RESET ROLE;
SET LOCAL ROLE nexus_api;
SELECT throws_ok($$INSERT INTO mdm.user_group (group_code, name) VALUES ('M_SNEAKY', 'Sneaky')$$,
  '42501', NULL, 'The API login cannot create groups directly');
RESET ROLE;

SELECT throws_ok($$UPDATE wf.config_audit SET actor_id = NULL$$, 'N2011', NULL, 'The configuration audit is append-only');

SELECT * FROM finish();
ROLLBACK;
