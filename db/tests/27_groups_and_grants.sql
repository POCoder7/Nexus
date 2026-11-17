-- pgTAP: users, roles and groups (ADR-042 D1, D2, D5; Phase 5 LLD §19.9, increment 5-4a).
-- Effective grants = direct grants ∪ (group role × group scope); who may hold which role (holder kinds).
BEGIN;
SELECT plan(20);

-- ---------------------------------------------------------------- fixtures (synthetic)
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-0000000027a1', 'g27_granter', 'Granter',  'human'),
  ('00000000-0000-0000-0000-0000000027a2', 'g27_editor',  'Editor',   'human'),
  ('00000000-0000-0000-0000-0000000027a3', 'g27_leaver',  'Leaver',   'human'),
  ('00000000-0000-0000-0000-0000000027a4', 'g27_admin',   'Admin',    'human'),
  ('00000000-0000-0000-0000-0000000027a5', 'g27_svc',     'Service',  'service'),
  ('00000000-0000-0000-0000-0000000027a6', 'g27_ai',      'AI agent', 'ai_agent'),
  ('00000000-0000-0000-0000-0000000027a7', 'g27_direct',  'Direct',   'human');
INSERT INTO mdm.node (node_id, node_kind) VALUES
  ('00000000-0000-0000-0000-0000000027c1', 'structural'), ('00000000-0000-0000-0000-0000000027c2', 'structural');
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id) VALUES
  ('00000000-0000-0000-0000-0000000027d1', 'G27_ORG', 'Synthetic org',   '00000000-0000-0000-0000-0000000027c1'),
  ('00000000-0000-0000-0000-0000000027d2', 'G27_AM',  'Synthetic accts', '00000000-0000-0000-0000-0000000027c2');

INSERT INTO mdm.user_group (group_id, group_code, name, role_code) VALUES
  ('00000000-0000-0000-0000-0000000027e1', 'G27_EDITORS', 'Editors of both', 'EDITOR'),
  ('00000000-0000-0000-0000-0000000027e2', 'G27_ADMINS',  'Admins',          'ADMIN'),
  ('00000000-0000-0000-0000-0000000027e3', 'G27_FEED',    'Downstream',      'CONSUMER'),
  ('00000000-0000-0000-0000-0000000027e4', 'G27_NOTE',    'A list, no role', NULL);
INSERT INTO mdm.user_group_scope (group_id, hierarchy_id, valid_period) VALUES
  ('00000000-0000-0000-0000-0000000027e1', '00000000-0000-0000-0000-0000000027d1', daterange('2000-01-01', NULL)),
  ('00000000-0000-0000-0000-0000000027e1', '00000000-0000-0000-0000-0000000027d2', daterange(mdm.business_today() - 5, NULL)),
  ('00000000-0000-0000-0000-0000000027e2', NULL,                                    daterange('2000-01-01', NULL)),
  ('00000000-0000-0000-0000-0000000027e3', '00000000-0000-0000-0000-0000000027d1', daterange('2000-01-01', NULL));
INSERT INTO mdm.user_group_member (group_id, user_id, granted_by, valid_period) VALUES
  ('00000000-0000-0000-0000-0000000027e1', '00000000-0000-0000-0000-0000000027a2', '00000000-0000-0000-0000-0000000027a1',
   daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-0000000027e1', '00000000-0000-0000-0000-0000000027a3', '00000000-0000-0000-0000-0000000027a1',
   daterange('2020-01-01', mdm.business_today())),                                      -- left yesterday
  ('00000000-0000-0000-0000-0000000027e2', '00000000-0000-0000-0000-0000000027a4', '00000000-0000-0000-0000-0000000027a1',
   daterange('2020-01-01', NULL)),
  ('00000000-0000-0000-0000-0000000027e3', '00000000-0000-0000-0000-0000000027a5', '00000000-0000-0000-0000-0000000027a1',
   daterange('2020-01-01', NULL));
INSERT INTO mdm.user_role (user_id, role_code, hierarchy_id, granted_by, valid_period) VALUES
  ('00000000-0000-0000-0000-0000000027a7', 'APPROVER', '00000000-0000-0000-0000-0000000027d2',
   '00000000-0000-0000-0000-0000000027a1', daterange('2020-01-01', NULL));

-- ---------------------------------------------------------------- effective grants (D2)
SELECT set_eq(
  $$SELECT role_code, hierarchy_id, source_group_id FROM mdm.effective_grants('00000000-0000-0000-0000-0000000027a2', mdm.business_today())$$,
  $$VALUES ('EDITOR', '00000000-0000-0000-0000-0000000027d1'::uuid, '00000000-0000-0000-0000-0000000027e1'::uuid),
           ('EDITOR', '00000000-0000-0000-0000-0000000027d2'::uuid, '00000000-0000-0000-0000-0000000027e1'::uuid)$$,
  'A member gets the group''s role once per scope, naming the group');
SELECT is(
  (SELECT valid_period FROM mdm.effective_grants('00000000-0000-0000-0000-0000000027a2', mdm.business_today())
   WHERE hierarchy_id = '00000000-0000-0000-0000-0000000027d2'),
  daterange(mdm.business_today() - 5, NULL),
  'A group grant holds while both the membership and the scope hold');
SELECT is(
  (SELECT count(*)::int FROM mdm.effective_grants('00000000-0000-0000-0000-0000000027a2', mdm.business_today() - 10)),
  1, 'Before a scope starts, it gives nothing');
SELECT set_eq(
  $$SELECT role_code, hierarchy_id, source_group_id FROM mdm.effective_grants('00000000-0000-0000-0000-0000000027a7', mdm.business_today())$$,
  $$VALUES ('APPROVER', '00000000-0000-0000-0000-0000000027d2'::uuid, NULL::uuid)$$,
  'A direct grant still works, with no source group');
SELECT is(
  (SELECT count(*)::int FROM mdm.effective_grants('00000000-0000-0000-0000-0000000027a3', mdm.business_today())),
  0, 'A membership that ended yesterday gives nothing today');
SELECT is(
  (SELECT count(*)::int FROM mdm.effective_grants('00000000-0000-0000-0000-0000000027a3', '2024-06-01')),
  1, '… and is reconstructable at a past date');
SELECT ok(mdm.holds_role('00000000-0000-0000-0000-0000000027a4', 'ADMIN', mdm.business_today()),
  'An ADMIN group with an every-hierarchy scope makes its members administrators');
SELECT ok(mdm.is_version_admin('00000000-0000-0000-0000-0000000027a4') AND wf.is_workflow_admin('00000000-0000-0000-0000-0000000027a4'),
  'Version and workflow administration read the same grants (ADR-042 C-1)');
SELECT ok(NOT mdm.holds_role('00000000-0000-0000-0000-0000000027a2', 'EDITOR', mdm.business_today()),
  'holds_role means every hierarchy: a hierarchy-scoped grant does not count');

UPDATE mdm.user_group SET is_active = false WHERE group_id = '00000000-0000-0000-0000-0000000027e2';
SELECT ok(NOT mdm.holds_role('00000000-0000-0000-0000-0000000027a4', 'ADMIN', mdm.business_today()),
  'An inactive group grants nothing');
UPDATE mdm.user_group SET is_active = true WHERE group_id = '00000000-0000-0000-0000-0000000027e2';
UPDATE mdm.app_user SET is_active = false WHERE user_id = '00000000-0000-0000-0000-0000000027a4';
SELECT ok(NOT mdm.holds_role('00000000-0000-0000-0000-0000000027a4', 'ADMIN', mdm.business_today()),
  'An inactive user holds no role');
UPDATE mdm.app_user SET is_active = true WHERE user_id = '00000000-0000-0000-0000-0000000027a4';

-- ---------------------------------------------------------------- holder kinds (D5)
SELECT throws_ok(
  $$INSERT INTO mdm.user_role (user_id, role_code, hierarchy_id, granted_by, valid_period)
    VALUES ('00000000-0000-0000-0000-0000000027a7', 'CONSUMER', '00000000-0000-0000-0000-0000000027d1',
            '00000000-0000-0000-0000-0000000027a1', daterange(current_date, NULL))$$,
  'N1032', NULL, 'A person cannot hold CONSUMER');
SELECT throws_ok(
  $$INSERT INTO mdm.user_role (user_id, role_code, hierarchy_id, granted_by, valid_period)
    VALUES ('00000000-0000-0000-0000-0000000027a5', 'EDITOR', '00000000-0000-0000-0000-0000000027d1',
            '00000000-0000-0000-0000-0000000027a1', daterange(current_date, NULL))$$,
  'N1032', NULL, 'A service account cannot hold EDITOR');
SELECT throws_ok(
  $$INSERT INTO mdm.user_group_member (group_id, user_id, granted_by)
    VALUES ('00000000-0000-0000-0000-0000000027e1', '00000000-0000-0000-0000-0000000027a5', '00000000-0000-0000-0000-0000000027a1')$$,
  'N1032', NULL, 'A service account cannot join an EDITOR group');
SELECT throws_ok(
  $$INSERT INTO mdm.user_group_member (group_id, user_id, granted_by)
    VALUES ('00000000-0000-0000-0000-0000000027e1', '00000000-0000-0000-0000-0000000027a6', '00000000-0000-0000-0000-0000000027a1')$$,
  'N1009', NULL, 'An AI agent cannot join a group with a role');
SELECT lives_ok(
  $$INSERT INTO mdm.user_group_member (group_id, user_id, granted_by)
    VALUES ('00000000-0000-0000-0000-0000000027e4', '00000000-0000-0000-0000-0000000027a6', '00000000-0000-0000-0000-0000000027a1')$$,
  'A group without a role grants nothing, so an AI agent may be listed in it');
SELECT throws_ok(
  $$UPDATE mdm.user_group SET role_code = 'EDITOR' WHERE group_id = '00000000-0000-0000-0000-0000000027e4'$$,
  'N1009', NULL, 'A group cannot be given a role its members may not hold');
SELECT throws_ok(
  $$UPDATE mdm.user_group SET role_code = 'CONSUMER' WHERE group_id = '00000000-0000-0000-0000-0000000027e1'$$,
  'N1032', NULL, 'A group of people cannot be made a CONSUMER group');
SELECT throws_ok(
  $$INSERT INTO mdm.user_role (user_id, role_code, granted_by, valid_period)
    VALUES ('00000000-0000-0000-0000-0000000027a7', 'STEWARD', '00000000-0000-0000-0000-0000000027a1', daterange(current_date, NULL))$$,
  '23503', NULL, 'A retired role name is not a role');

INSERT INTO mdm.version (version_id, version_name, business_as_of)
VALUES ('00000000-0000-0000-0000-0000000027b1', 'G27_VERSION', current_date);
SELECT throws_ok(
  $$INSERT INTO mdm.change_request (version_id, title, requester_id, requester_kind, effective_from)
    VALUES ('00000000-0000-0000-0000-0000000027b1', 'A feed asks', '00000000-0000-0000-0000-0000000027a5', 'service', current_date)$$,
  'N1005', NULL, 'A service account cannot raise a change request');

SELECT * FROM finish();
ROLLBACK;
