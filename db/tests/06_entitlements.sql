-- pgTAP: role grants (ADR-022) and the single business-time-zone setting (ADR-018, CR-01).
BEGIN;
SELECT plan(11);

SELECT has_table('mdm', 'role', 'Roles are data');
SELECT has_table('mdm', 'user_role', 'Grants are data');
SELECT is((SELECT count(*)::int FROM mdm.role), 6, 'Six Phase 1 roles are seeded');
SELECT is((SELECT setting_value FROM mdm.system_setting WHERE setting_key = 'business_time_zone'),
          'America/New_York', 'The business time zone is recorded once, in the database (CR-01)');

-- ---------------------------------------------------------------- fixtures (synthetic)
INSERT INTO mdm.app_user (user_id, login, display_name, kind) VALUES
  ('00000000-0000-0000-0000-0000000006a1', 'g_admin',   'Admin',    'human'),
  ('00000000-0000-0000-0000-0000000006a2', 'g_steward', 'Steward',  'human'),
  ('00000000-0000-0000-0000-0000000006a3', 'g_ai',      'AI agent', 'ai_agent');
INSERT INTO mdm.node (node_id, node_kind) VALUES ('00000000-0000-0000-0000-0000000006c1', 'structural');
INSERT INTO mdm.hierarchy (hierarchy_id, hierarchy_code, hierarchy_name, top_node_id)
VALUES ('00000000-0000-0000-0000-0000000006d1', 'G_H1', 'Grant hierarchy', '00000000-0000-0000-0000-0000000006c1');

SELECT lives_ok(
  $$INSERT INTO mdm.user_role (user_id, role_code, hierarchy_id, granted_by, valid_period)
    VALUES ('00000000-0000-0000-0000-0000000006a2', 'STEWARD', '00000000-0000-0000-0000-0000000006d1',
            '00000000-0000-0000-0000-0000000006a1', daterange(current_date, NULL))$$,
  'An admin can grant a scoped role to a steward');

SELECT throws_ok(
  $$INSERT INTO mdm.user_role (user_id, role_code, granted_by, valid_period)
    VALUES ('00000000-0000-0000-0000-0000000006a1', 'SYSTEM_ADMIN', '00000000-0000-0000-0000-0000000006a1', daterange(current_date, NULL))$$,
  '23514', NULL, 'Nobody can grant a role to themselves');

SELECT throws_ok(
  $$INSERT INTO mdm.user_role (user_id, role_code, granted_by, valid_period)
    VALUES ('00000000-0000-0000-0000-0000000006a3', 'APPROVER', '00000000-0000-0000-0000-0000000006a1', daterange(current_date, NULL))$$,
  'N1009', NULL, 'Only human users hold roles');

SELECT throws_ok(
  $$INSERT INTO mdm.user_role (user_id, role_code, top_node_id, granted_by, valid_period)
    VALUES ('00000000-0000-0000-0000-0000000006a2', 'VIEWER', '00000000-0000-0000-0000-0000000006c1',
            '00000000-0000-0000-0000-0000000006a1', daterange(current_date, NULL))$$,
  '23514', NULL, 'A sub-tree scope needs its hierarchy');

SELECT throws_ok(
  $$INSERT INTO mdm.user_role (user_id, role_code, hierarchy_id, granted_by, valid_period)
    VALUES ('00000000-0000-0000-0000-0000000006a2', 'STEWARD', '00000000-0000-0000-0000-0000000006d1',
            '00000000-0000-0000-0000-0000000006a1', daterange(current_date, NULL))$$,
  '23P01', NULL, 'The same grant cannot overlap itself');

SELECT throws_ok(
  $$UPDATE mdm.user_role SET role_code = 'APPROVER' WHERE user_id = '00000000-0000-0000-0000-0000000006a2'$$,
  'N2010', NULL, 'Grants are bitemporal: no edits in place');

SET LOCAL ROLE nexus_api;
SELECT throws_ok(
  $$INSERT INTO mdm.user_role (user_id, role_code, granted_by, valid_period)
    VALUES ('00000000-0000-0000-0000-0000000006a2', 'SYSTEM_ADMIN', '00000000-0000-0000-0000-0000000006a1', daterange(current_date, NULL))$$,
  '42501', NULL, 'The API login cannot grant roles (Phase 1: migration or SQL by an administrator only)');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
